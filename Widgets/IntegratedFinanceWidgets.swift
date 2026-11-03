import AppIntents
import Foundation
import SwiftUI
import WidgetKit

struct SavingsClaimBenefitIntent: AppIntent {
    static var title: LocalizedStringResource = "记录权益已领取"
    static var description = IntentDescription("仅记录本期领取，不执行服务平台领奖，不结算游戏奖励。")
    static var isDiscoverable = false
    @Parameter(title: "权益 ID") var benefitID: String
    @Parameter(title: "权益周期") var periodKey: String
    @Parameter(title: "业务时区") var timezone: String
    init() {}
    init(id: UUID, periodKey: String, timezone: String) { benefitID = id.uuidString; self.periodKey = periodKey; self.timezone = timezone }
    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: benefitID) else { throw MonthlyFinanceError("权益记录无效。") }
        let db = try MonthlyFinanceDatabase(directory: MonthlyFinanceDatabase.location(), readOnly: false)
        defer { WidgetCenter.shared.reloadTimelines(ofKind: "GaoJiXuMonthlyBenefits") }
        _ = try db.transaction { try MonthlyFinanceEngine.claimPresented(&$0, benefitID: id, expectedPeriodKey: periodKey, expectedTimezone: timezone) }
        DistributedNotificationCenter.default().postNotificationName(Notification.Name("gaojixu.integratedMonthly.changed"), object: "SavingsMonthlyWidget", userInfo: nil, deliverImmediately: true)
        return .result()
    }
}
private struct IntegratedFinanceEntry: TimelineEntry { let date: Date; let state: MonthlyFinanceState?; let failure: String? }
private struct IntegratedFinanceProvider: TimelineProvider {
    let kind: String
    func placeholder(in context: Context) -> IntegratedFinanceEntry { .init(date: Date(), state: nil, failure: "打开搞积蓄完成金融资料切换后显示。") }
    func getSnapshot(in context: Context, completion: @escaping (IntegratedFinanceEntry) -> Void) { completion(read(context.family, phase: "snapshot")) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<IntegratedFinanceEntry>) -> Void) {
        let value = read(context.family, phase: "timeline")
        let calendar = value.state.map(MonthlyFinanceEngine.calendar) ?? Calendar.autoupdatingCurrent
        let next = min(value.date.addingTimeInterval(value.state == nil ? 300 : 1800), calendar.dateInterval(of: .day, for: value.date)?.end ?? value.date.addingTimeInterval(1800))
        completion(Timeline(entries: [value], policy: .after(next)))
    }
    private func read(_ family: WidgetFamily, phase: String) -> IntegratedFinanceEntry {
        let now = Date()
        do {
            let dir = try MonthlyFinanceDatabase.location(), state = try MonthlyFinanceDatabase(directory: dir).read()
            struct Read: Codable { let kind: String; let family: String; let phase: String; let sourceUpdatedAt: Date; let readAt: Date; let readerVersion: String; let readerBuild: String }
            let record = Read(kind: kind, family: String(describing: family), phase: phase, sourceUpdatedAt: state.updatedAt, readAt: now,
                              readerVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                              readerBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")
            let diagnostics = dir.appendingPathComponent("WidgetDiagnostics", isDirectory: true)
            if let data = try? JSONEncoder().encode(record) {
                do { try FileManager.default.createDirectory(at: diagnostics, withIntermediateDirectories: true); try data.write(to: diagnostics.appendingPathComponent(kind + "-" + String(describing: family) + "-" + phase + ".json"), options: .atomic) } catch { /* Read failures never change the business database. */ }
            }
            return .init(date: now, state: state, failure: nil)
        } catch { return .init(date: now, state: nil, failure: "固定支出资料暂不可用，请打开搞积蓄检查迁移与备份。") }
    }
}
private struct IntegratedFinanceWidgetView: View {
    let entry: IntegratedFinanceEntry
    let benefits: Bool
    @Environment(\.widgetFamily) private var family
    private var limit: Int { family == .systemSmall ? 2 : 4 }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let state = entry.state {
                Group {
                    if benefits {
                        VStack(alignment: .leading, spacing: 7) {
                            title
                            benefitRows(state)
                        }
                    } else { expenseRows(state) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                Text(freshness(state)).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    title
                    Text(entry.failure ?? "资料暂不可用").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
        .widgetURL(URL(string: benefits ? "gaojixu://benefits" : "gaojixu://fixed-expenses"))
    }
    private var title: some View { Text(benefits ? "权益打卡" : "固定支出").font(.headline) }
    @ViewBuilder private func expenseRows(_ state: MonthlyFinanceState) -> some View {
        let pending = MonthlyFinanceEngine.pending(state, now: entry.date)
        let coming = MonthlyFinanceEngine.upcoming(state, now: entry.date, days: 30)
        let bills = (pending + coming).reduce(into: [String: MonthlyFinanceBill]()) { $0[$1.id] = $1 }.values.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
        ViewThatFits(in: .vertical) {
            if family != .systemSmall {
                expenseContent(state, bills: bills, visibleLimit: 4)
                expenseContent(state, bills: bills, visibleLimit: 3)
            }
            expenseContent(state, bills: bills, visibleLimit: 2)
            expenseContent(state, bills: bills, visibleLimit: 1)
            expenseContent(state, bills: bills, visibleLimit: 0)
        }
    }
    private func expenseContent(_ state: MonthlyFinanceState, bills: [MonthlyFinanceBill], visibleLimit: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            title
            if bills.isEmpty { Text("本期无待核实账期").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(bills.prefix(visibleLimit))) { bill in
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.preferences.privacy ? "固定支出待核实" : (state.subscriptions.first { $0.id == bill.subscriptionID }?.name ?? "固定支出")).font(.caption).lineLimit(1)
                    Text(MonthlyFinanceEngine.day(bill.date, state) + (state.preferences.privacy ? "" : " · " + bill.currency + " " + NSDecimalNumber(decimal: bill.price).stringValue)).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if bills.count > visibleLimit {
                Text(visibleLimit == 0 ? "共 \(bills.count) 项，打开查看" : "还有 \(bills.count - visibleLimit) 项，打开查看")
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
            if !bills.isEmpty { Text("预计账期，确认支付后才记账").font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
    @ViewBuilder private func benefitRows(_ state: MonthlyFinanceState) -> some View {
        let due = MonthlyFinanceEngine.dueBenefits(state, now: entry.date)
        let active = state.benefits.filter { MonthlyFinanceEngine.claimKey($0, state, on: entry.date) != nil }
        if due.isEmpty { Text(active.isEmpty ? "暂无可记录的权益" : "本期权益均已记录").font(.caption).foregroundStyle(.secondary) }
        ForEach(Array(due.prefix(limit))) { benefit in
            HStack {
                Text(state.preferences.privacy ? "本期权益" : benefit.name).font(.caption).lineLimit(1)
                Spacer(minLength: 3)
                Button(intent: SavingsClaimBenefitIntent(id: benefit.id, periodKey: MonthlyFinanceEngine.claimKey(benefit, state, on: entry.date) ?? "", timezone: state.preferences.timezone)) { Image(systemName: "checkmark.circle") }.buttonStyle(.plain)
            }
        }
    }
    private func freshness(_ state: MonthlyFinanceState) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.timeZone = MonthlyFinanceEngine.calendar(state).timeZone; f.dateFormat = "yyyy/MM/dd HH:mm"
        return "资料更新 " + f.string(from: state.updatedAt)
    }
}
struct SavingsFixedExpenseWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "GaoJiXuFixedExpense", provider: IntegratedFinanceProvider(kind: "GaoJiXuFixedExpense")) { IntegratedFinanceWidgetView(entry: $0, benefits: false) }
            .configurationDisplayName("固定支出").description("待核实账期与近期固定支出，预计费用不等于实际支付。").supportedFamilies([.systemSmall, .systemMedium])
    }
}
struct SavingsMonthlyBenefitsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "GaoJiXuMonthlyBenefits", provider: IntegratedFinanceProvider(kind: "GaoJiXuMonthlyBenefits")) { IntegratedFinanceWidgetView(entry: $0, benefits: true) }
            .configurationDisplayName("权益打卡").description("记录周期权益领取，不发放游戏奖励。").supportedFamilies([.systemSmall, .systemMedium])
    }
}
