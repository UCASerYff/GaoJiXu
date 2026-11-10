import Foundation
import SwiftUI
import UserNotifications
import WidgetKit

@MainActor final class MonthlyFinanceStore: ObservableObject {
  static let shared = MonthlyFinanceStore()
  @Published private(set) var state: MonthlyFinanceState?
  @Published var problem: String?
  @Published private(set) var unavailable = "正在读取固定支出与权益…"
  private var observations: [NSObjectProtocol] = []
  private var wake: NSObjectProtocol?
  private var reminderTask: Task<Void, Never>?
  static let changed = Notification.Name("gaojixu.integratedMonthly.changed")
  private init() {
    let center = NotificationCenter.default
    for name in [
      NSApplication.didBecomeActiveNotification, .NSCalendarDayChanged, .NSSystemTimeZoneDidChange,
    ] {
      observations.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          Task { @MainActor in self?.reload() }
        })
    }
    wake = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in Task { @MainActor in self?.reload() } }
    DistributedNotificationCenter.default().addObserver(
      forName: Self.changed, object: nil, queue: .main
    ) { [weak self] n in
      if (n.object as? String) != "SavingsMonthlyHost" { Task { @MainActor in self?.reload() } }
    }
  }
  func reload() {
    do {
      state = try MonthlyFinanceDatabase(directory: MonthlyFinanceDatabase.location()).read()
      scheduleReminders()
    } catch {
      state = nil
      unavailable = "固定支出与权益资料未就绪。请先完成迁移，或检查现用资料。\n" + error.localizedDescription
    }
  }
  @discardableResult func update(_ body: (inout MonthlyFinanceState) throws -> Void) -> Bool {
    do {
      let db = try MonthlyFinanceDatabase(
        directory: MonthlyFinanceDatabase.location(), readOnly: false)
      state = try db.transaction(body)
      problem = nil
      NotificationCenter.default.post(name: Self.changed, object: nil)
      DistributedNotificationCenter.default().postNotificationName(
        Self.changed, object: "SavingsMonthlyHost", userInfo: nil, deliverImmediately: true)
      // The receiving widget kinds may each have multiple sizes/instances.
      for kind in ["GaoJiXuFixedExpense", "GaoJiXuMonthlyBenefits"] {
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
      }
      scheduleReminders()
      return true
    } catch {
      problem = error.localizedDescription
      reload()
      return false
    }
  }
  func initializeEmpty() {
    do {
      let home = FileManager.default.homeDirectoryForCurrentUser
      let lib = home.appendingPathComponent("Library", isDirectory: true)
      let domains = ["com.gaoseries.GaoYueGong", "com.gaoseries.GaoYueGong.Monthly"]
      guard domains.allSatisfy({ UserDefaults.standard.persistentDomain(forName: $0) == nil })
      else { throw MonthlyFinanceError("存在原月供设置，请先迁移。") }
      let paths =
        [
          "Group Containers/5G96498KGJ.com.gaoseries.GaoYueGong/Monthly",
          "Application Support/GaoSeries/Monthly", "Application Support/GaoSeriesRestore/Monthly",
          "Application Support/GaoSeries/Savings/auto-ledger-tasks.json",
          "Application Support/GaoSeries/Savings/monthly-account-bindings.json",
        ] + domains.map { "Preferences/" + $0 + ".plist" }
      try MonthlyFinanceMigration.initializeNew(
        directory: MonthlyFinanceDatabase.location(),
        legacyEvidence: paths.map { lib.appendingPathComponent($0) })
      problem = nil
      reload()
    } catch { problem = error.localizedDescription }
  }
  func enableReminders() async -> Bool {
    do {
      let ok = try await UNUserNotificationCenter.current().requestAuthorization(options: [
        .alert, .sound,
      ])
      guard ok else {
        problem = "未获系统通知权限；可在系统设置中开启。"
        return false
      }
      problem = nil
      return true
    } catch {
      problem = error.localizedDescription
      return false
    }
  }
  private func scheduleReminders() {
    guard let snapshot = state else { return }
    let prior = reminderTask
    prior?.cancel()
    reminderTask = Task {
      if let prior { await prior.value }
      guard !Task.isCancelled else { return }
      await MonthlyFinanceReminder.schedule(snapshot)
    }
  }
}

private enum MonthlyFinanceReminder {
  static let prefix = "gaojixu.finance.monthly."
  struct Item {
    let date: Date
    let id: String
    let text: String
  }
  static func schedule(_ s: MonthlyFinanceState) async {
    let center = UNUserNotificationCenter.current()
    let permissions = await center.notificationSettings()
    let current = await center.pendingNotificationRequests().filter {
      $0.identifier.hasPrefix(prefix)
    }
    guard !Task.isCancelled else { return }
    guard
      s.preferences.notifications
        && [.authorized, .provisional].contains(permissions.authorizationStatus)
    else {
      center.removePendingNotificationRequests(withIdentifiers: current.map(\.identifier))
      return
    }
    let c = MonthlyFinanceEngine.calendar(s)
    let now = Date()
    guard let limit = c.date(byAdding: .day, value: 90, to: now) else { return }
    var items: [Item] = []
    for sub in s.subscriptions where !sub.archived && sub.renewing {
      var bills = MonthlyFinanceEngine.bills(sub, state: s, from: now, through: limit)
      if bills.isEmpty, let b = MonthlyFinanceEngine.next(sub, s, now: now) { bills = [b] }
      for bill in bills where !MonthlyFinanceEngine.covered(bill, s) {
        for advance in Set(
          [sub.reminderDays ?? s.preferences.reminderDays] + (sub.autoRenew ? [0] : []))
        {
          if let day = c.date(byAdding: .day, value: -advance, to: bill.date),
            let at = c.date(
              bySettingHour: s.preferences.reminderHour, minute: 0, second: 0, of: day), at > now
          {
            items.append(
              .init(
                date: at, id: prefix + "bill|\(bill.id)|\(advance)",
                text: s.preferences.privacy
                  ? "有固定支出待核对。" : "\(sub.name) · \(bill.currency) \(bill.price)"))
          }
        }
      }
      if !sub.trialResolved, let end = sub.cancelDeadline ?? sub.trialEnd,
        end.addingTimeInterval(-86400) > now
      {
        items.append(
          .init(
            date: end.addingTimeInterval(-86400), id: prefix + "trial|\(sub.id)",
            text: s.preferences.privacy ? "试用即将到期。" : "\(sub.name) 的试用即将到期，请在平台核对。"))
      }
    }
    for e in s.events where e.doneAt == nil && e.deadline > now {
      items.append(
        .init(
          date: e.deadline, id: prefix + "event|\(e.id)",
          text: s.preferences.privacy ? "有到期事项待处理。" : e.name))
    }
    let unique = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      .values.sorted { ($0.date, $0.id) < ($1.date, $1.id) }.prefix(60)
    let desired = Set(unique.map(\.id))
    let stale = current.map(\.identifier).filter { !desired.contains($0) }
    guard !Task.isCancelled else { return }
    center.removePendingNotificationRequests(withIdentifiers: stale)
    for i in unique {
      guard !Task.isCancelled else { return }
      let content = UNMutableNotificationContent()
      content.title = "搞积蓄 · 固定支出与事项"
      content.body = i.text
      content.sound = .default
      content.userInfo = ["module": "monthly"]
      var comps = c.dateComponents([.year, .month, .day, .hour, .minute, .second], from: i.date)
      comps.timeZone = c.timeZone
      do {
        try await center.add(
          .init(
            identifier: i.id, content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
      } catch {
        await MainActor.run {
          MonthlyFinanceStore.shared.problem = "提醒未能全部排程：" + error.localizedDescription
        }
        return
      }
    }
  }
}
