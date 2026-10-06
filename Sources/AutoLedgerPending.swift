import Foundation
import SwiftUI

/// P0-2：搞积蓄界面读取主 app 持久化的月供自动记账任务表
///（~/Library/Application Support/GaoSeries/Savings/auto-ledger-tasks.json，与主 app 同格式同进程）。
/// 无匹配币种账户的扣款不再静默丢弃：在总览顶部显示待处理项，用户选账户后入账并标 done。
struct PendingAutoLedgerTask: Codable, Identifiable {
    var id: String
    var title: String
    var amount: Double
    var currency: String
    var date: Date
    var state: String   // pending / done / failed
    var attempts: Int
    var lastError: String?
}

enum PendingAutoLedger {
    static var fileURL: URL {
        // 与主 app AutoLedgerTasks 同一文件；测试可用同一环境变量隔离。
        if let override = ProcessInfo.processInfo.environment["GQNS_AUTOLEDGER_TASKS_FILE"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GaoSeries/Savings/auto-ledger-tasks.json")
    }

    static func pendingTasks() -> [PendingAutoLedgerTask] {
        allTasks().filter { $0.state == "pending" }
    }

    /// 对账表用：全部任务（含 done/failed/ignored），按扣款日期倒序。
    static func allTasks() -> [PendingAutoLedgerTask] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let tasks = (try? decoder.decode([PendingAutoLedgerTask].self, from: data)) ?? []
        return tasks.sorted { $0.date > $1.date }
    }

    static func markDone(_ id: String) { updateState(id, to: "done", clearError: true) }
    static func markIgnored(_ id: String) { updateState(id, to: "ignored", clearError: false) }
    static func markPending(_ id: String) { updateState(id, to: "pending", clearError: true) }

    private static func updateState(_ id: String, to state: String, clearError: Bool) {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard var tasks = try? decoder.decode([PendingAutoLedgerTask].self, from: data),
              let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].state = state
        if clearError { tasks[index].lastError = nil }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let out = try? encoder.encode(tasks) else { return }
        try? out.write(to: fileURL, options: .atomic)
    }
}

/// 总览顶部的待处理自动记账横幅：每条月供扣款一行，账户选择器 + 入账按钮。
struct PendingAutoLedgerBanner: View {
    @EnvironmentObject private var store: SavingsStore
    @State private var tasks: [PendingAutoLedgerTask] = PendingAutoLedger.pendingTasks()
    @State private var chosenAccount: [String: String] = [:]  // taskID -> accountID

    var body: some View {
        // 容器恒存在（空态是 0 高度的空 VStack）——onAppear 挂在空 Group/条件分支上永远不触发。
        VStack(alignment: .leading, spacing: 10) {
            if !tasks.isEmpty {
                bannerContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { refresh() }
        // 自动流程入账/回执后刷新列表（本模块前台时立刻消失或出现）。
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("gaojixu.autoLedgerResult"))) { _ in refresh() }
    }

    private var bannerContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(tS("有 \(tasks.count) 笔月供扣款待记账", "\(tasks.count) monthly bill(s) to record"), systemImage: "tray.and.arrow.down.fill")
                .font(.headline)
            Text(tS("请确认这份订阅的真实扣款账户；绑定后，今后已确认的支付会自动同步到该账户。", "No account matches the bill currency — pick one per bill (never auto-recorded into another currency)."))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(tasks) { task in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tS("月供·", "Monthly·") + task.title).font(.callout.weight(.medium))
                        Text("\(task.currency) \(task.amount, specifier: "%.2f") · \(task.date.formatted(date: .numeric, time: .omitted))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("入账账户", selection: Binding(
                        get: { chosenAccount[task.id] ?? "" },
                        set: { chosenAccount[task.id] = $0 }
                    )) {
                        Text(tS("选择账户", "Choose account")).tag("")
                        ForEach(store.activeAccounts.filter { $0.currency.rawValue == task.currency }) { account in
                            Text("\(account.name)（\(account.currency.rawValue)）").tag(account.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    Button(tS("记账", "Record")) { record(task) }
                        .disabled((chosenAccount[task.id] ?? "").isEmpty)
                        .controlSize(.small)
                    // 3.36：用户可主动忽略（进对账表「已忽略」，可撤销），不再只能挂着。
                    Button(tS("忽略", "Ignore")) {
                        PendingAutoLedger.markIgnored(task.id)
                        refresh()
                    }
                    .controlSize(.small).buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(SavingsTheme.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(SavingsTheme.orange.opacity(0.4), lineWidth: 1)
        }
    }

    func refresh() {
        tasks = PendingAutoLedger.pendingTasks()
    }

    private func record(_ task: PendingAutoLedgerTask) {
        guard let accountID = chosenAccount[task.id], !accountID.isEmpty else { return }
        let outcome = store.recordAutoLedgerEntry(paymentID: task.id, title: task.title, amount: task.amount,
                                                  currency: task.currency, date: task.date, accountOverride: accountID)
        // recorded/duplicate 的回执会让主 app 标 done；这里同步更新本地文件让横幅立即消失。
        if outcome == .recorded || outcome == .duplicate {
            PendingAutoLedger.markDone(task.id)
        }
        refresh()
    }
}

/// 3.36：「月供 ↔ 记账」核对表——每笔月供扣款一行：已入账（含落入账户/时间）/
/// 待处理（上方横幅选账户）/ 失败（原因）/ 已忽略（可撤销）。数据源是主 app 的持久化任务表，
/// 入账落点与时间在搞积蓄流水里按固定 id（auto-monthly|<paymentID>）回查。
struct AutoLedgerReconciliationCard: View {
    @EnvironmentObject private var store: SavingsStore
    @State private var tasks: [PendingAutoLedgerTask] = PendingAutoLedger.allTasks()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !tasks.isEmpty {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("gaojixu.autoLedgerResult"))) { _ in refresh() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(tS("月供 ↔ 记账核对", "Bills ↔ Ledger"), systemImage: "checklist")
                .font(.headline)
            ForEach(tasks.prefix(10)) { task in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tS("月供·", "Monthly·") + task.title).font(.callout.weight(.medium))
                        Text(taskSubtitle(task))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    statusView(task)
                }
            }
            if tasks.count > 10 {
                Text(tS("另有 \(tasks.count - 10) 条更早记录", "\(tasks.count - 10) older entries")).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func statusView(_ task: PendingAutoLedgerTask) -> some View {
        switch task.state {
        case "done":
            // 回查流水拿落入账户与入账时间。
            let entry = store.ledgerEntries.first { $0.id == "auto-monthly|\(task.id)" }
            VStack(alignment: .trailing, spacing: 2) {
                Label(tS("已入账", "Recorded"), systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium)).foregroundStyle(SavingsTheme.green)
                if let entry {
                    Text("\(store.account(entry.accountID)?.name ?? tS("账户已删", "deleted")) · \(entry.createdAt.formatted(date: .numeric, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        case "failed":
            Label(tS("失败：", "Failed: ") + (task.lastError ?? tS("未知原因", "unknown")), systemImage: "xmark.circle")
                .font(.caption).foregroundStyle(SavingsTheme.red).lineLimit(2)
        case "ignored":
            HStack(spacing: 8) {
                Text(tS("已忽略", "Ignored")).font(.caption).foregroundStyle(.secondary)
                Button(tS("撤销", "Undo")) {
                    PendingAutoLedger.markPending(task.id)
                    refresh()
                }
                .controlSize(.small).buttonStyle(.borderless)
            }
        default:
            Label(tS("待处理 · 上方选择账户", "Pending · choose account above"), systemImage: "tray.and.arrow.down")
                .font(.caption).foregroundStyle(SavingsTheme.orange)
        }
    }

    private func taskSubtitle(_ task: PendingAutoLedgerTask) -> String {
        let amount = String(format: "%@ %.2f", task.currency, task.amount)
        let date = task.date.formatted(date: .numeric, time: .omitted)
        return amount + " · " + tS("扣款 ", "billed ") + date
    }

    private func refresh() {
        tasks = PendingAutoLedger.allTasks()
    }
}
