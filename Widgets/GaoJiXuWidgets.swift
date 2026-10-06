import Foundation
import SwiftUI
import WidgetKit

private struct GaoJiXuEntry: TimelineEntry {
    let date: Date
    let snapshot: GaoJiXuWidgetSnapshot?
}

private struct GaoJiXuProvider: TimelineProvider {
    func placeholder(in context: Context) -> GaoJiXuEntry {
        .init(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (GaoJiXuEntry) -> Void) {
        completion(.init(date: Date(), snapshot: read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GaoJiXuEntry>) -> Void) {
        let now = Date()
        let entry = GaoJiXuEntry(date: now, snapshot: read())
        // 财务变化时主应用已主动 reloadAllTimelines，轮询只做跨天兜底：3 小时一次。
        let next = Calendar.current.date(byAdding: .hour, value: 3, to: now) ?? now.addingTimeInterval(3 * 3600)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func read() -> GaoJiXuWidgetSnapshot? {
        let urls = [GaoJiXuWidgetSnapshot.fileURL, GaoJiXuWidgetSnapshot.fallbackFileURL].compactMap { $0 }
        for url in urls {
            if let data = try? Data(contentsOf: url), let snapshot = try? JSONDecoder().decode(GaoJiXuWidgetSnapshot.self, from: data) {
                return snapshot
            }
        }
        return nil
    }
}

private extension GaoJiXuWidgetSnapshot {
    static var placeholder: GaoJiXuWidgetSnapshot {
        let calendar = Calendar.current
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date()
        let days = (1...(calendar.range(of: .day, in: .month, for: start)?.count ?? 30)).map { day in
            Day(date: calendar.date(byAdding: .day, value: day - 1, to: start) ?? start, day: day,
                expense: day == 2 ? 68 : 0, income: day == 8 ? 3200 : 0, saving: day == 11 ? 500 : 0)
        }
        let monthFormatter = DateFormatter()
        monthFormatter.locale = Locale(identifier: "zh_CN")
        monthFormatter.dateFormat = "yyyy年M月"
        return .init(updatedAt: Date(), monthStart: start, monthTitle: monthFormatter.string(from: start), currencyCode: "CNY", currencySymbol: "¥",
                     days: days, netWorth: 12_480, accounts: [], budgetTotal: 2_000, budgetSpent: 865)
    }

    /// 快照币种的小数位（JPY/KRW 为 0，其余 2），与主应用 SavingsCurrency.fractionDigits 一致。
    /// currency 字段缺失时解码已默认 "CNY"。
    var fractionDigits: Int { (currency == "JPY" || currency == "KRW") ? 0 : 2 }
}

private struct FinanceCalendarWidgetView: View {
    let entry: GaoJiXuEntry
    @Environment(\.widgetFamily) private var family

    private var snapshot: GaoJiXuWidgetSnapshot { entry.snapshot ?? .placeholder }
    private var leadingBlankCount: Int {
        Calendar.current.component(.weekday, from: snapshot.days.first?.date ?? snapshot.monthStart) - 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 8 : 5) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("每日收支与积蓄").font(.headline).lineLimit(1)
                    Text(snapshot.monthTitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(snapshot.currency).font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            HStack(spacing: 7) {
                legend("支出", color: .red)
                // 中号每格只显示支出与积蓄两行，收入图例只在大号出现。
                if family == .systemLarge { legend("收入", color: .green) }
                legend("积蓄", color: .orange)
                Spacer()
            }.font(.system(size: 9))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) { weekday in
                    Text(weekday).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
                ForEach(0..<leadingBlankCount, id: \.self) { _ in Color.clear.frame(height: cellHeight) }
                ForEach(snapshot.days) { day in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(day.day)").font(.system(size: 9, weight: .semibold))
                        Text(amount(day.expense, prefix: "−")).foregroundStyle(.red)
                        if family == .systemLarge {
                            Text(amount(day.income, prefix: "+")).foregroundStyle(.green)
                        }
                        Text(amount(day.saving, prefix: "～")).foregroundStyle(.orange)
                    }
                    .font(.system(size: family == .systemLarge ? 8 : 7, design: .monospaced))
                    .frame(maxWidth: .infinity, minHeight: cellHeight, alignment: .topLeading)
                    .padding(.horizontal, 2).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 3))
                }
            }
            if entry.snapshot == nil {
                Text("打开搞积蓄后自动同步").font(.system(size: 8)).foregroundStyle(.secondary)
            }
        }
        .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
    }

    private var cellHeight: CGFloat { family == .systemLarge ? 34 : 27 }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 2) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(title)
        }
    }

    private func amount(_ value: Double, prefix: String) -> String {
        guard abs(value) >= 0.005 else { return "·" }
        // 零小数位币种（JPY/KRW）一律取整；其余币种小额保留两位、大额取整。
        let text = (snapshot.fractionDigits == 0 || abs(value) >= 100) ? "\(Int(abs(value).rounded()))" : String(format: "%.2f", abs(value))
        return "\(prefix)\(value < 0 ? "−" : "")\(text)"
    }
}

private struct NetWorthWidgetView: View {
    let entry: GaoJiXuEntry
    private var snapshot: GaoJiXuWidgetSnapshot { entry.snapshot ?? .placeholder }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("净资产", systemImage: "building.columns.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text("\(snapshot.currencySymbol)\(amount(snapshot.netWorth))")
                .font(.system(size: 27, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.55).lineLimit(1)
            Spacer(minLength: 0)
            if snapshot.accounts.isEmpty {
                Text("计入净资产的账户").font(.system(size: 9)).foregroundStyle(.secondary)
            } else {
                // 小号部件空间有限，最多显示净资产贡献前两名的账户。
                ForEach(snapshot.accounts.prefix(2)) { account in
                    HStack(spacing: 5) {
                        Image(systemName: account.symbol).font(.caption2)
                        Text(account.name).lineLimit(1)
                        Spacer()
                        Text("\(snapshot.currencySymbol)\(amount(account.balance))").monospacedDigit()
                    }.font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            Text(entry.snapshot == nil ? "打开应用同步" : "更新于 \(entry.date, style: .time)")
                .font(.system(size: 8)).foregroundStyle(.tertiary)
        }
        .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
    }

    private func amount(_ value: Double) -> String {
        if abs(value) >= 100_000 || snapshot.fractionDigits == 0 { return String(format: "%.0f", value) }
        return String(format: "%.2f", value)
    }
}

struct MonthlyFinanceCalendarWidget: Widget {
    let kind = "GaoJiXuMonthlyFinanceCalendar"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: GaoJiXuProvider()) { entry in
            FinanceCalendarWidgetView(entry: entry)
                .widgetURL(URL(string: "gaojixu://ledger"))
        }
        .configurationDisplayName("每日收支与积蓄")
        .description("按月查看每天的支出、收入和积蓄。")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct NetWorthWidget: Widget {
    let kind = "GaoJiXuNetWorth"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: GaoJiXuProvider()) { entry in
            NetWorthWidgetView(entry: entry)
                .widgetURL(URL(string: "gaojixu://overview"))
        }
        .configurationDisplayName("净资产")
        .description("快速查看计入净资产账户的总额。")
        .supportedFamilies([.systemSmall])
    }
}

@main
struct GaoJiXuWidgets: WidgetBundle {
    var body: some Widget {
        MonthlyFinanceCalendarWidget()
        NetWorthWidget()
    }
}
