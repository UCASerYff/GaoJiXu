import Foundation
import SwiftUI
import WidgetKit

private struct GaoJiXuEntry: TimelineEntry {
    let date: Date
    let snapshot: GaoJiXuWidgetSnapshot?
    let statusMessage: String?
}

private struct GaoJiXuProvider: TimelineProvider {
    let kind: String

    func placeholder(in context: Context) -> GaoJiXuEntry {
        .init(date: Date(), snapshot: .placeholder, statusMessage: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (GaoJiXuEntry) -> Void) {
        guard !context.isPreview else { completion(placeholder(in: context)); return }
        let now = Date()
        completion(entry(from: read(at: now, family: context.family), at: now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GaoJiXuEntry>) -> Void) {
        let now = Date()
        let calendar = Calendar.autoupdatingCurrent
        let result = read(at: now, family: context.family)
        var entries = [entry(from: result, at: now)]
        // 提前提供下一日的投影，主应用退出后也能跨月；不把投影时间当作资料更新时间。
        if result.snapshot != nil, let midnight = calendar.dateInterval(of: .day, for: now)?.end {
            entries.append(entry(from: result, at: midnight))
        }
        let next = SnapshotIO.nextRefresh(after: now, calendar: calendar)
        completion(Timeline(entries: entries, policy: .after(next)))
    }

    private func read(at date: Date, family: WidgetFamily) -> SnapshotReadResult {
        // appex 的 Application Support 属于其沙盒，不能当作主应用的本地备用路径。
        let result = SnapshotIO.read(candidates: [GaoJiXuWidgetSnapshot.fileURL].compactMap { $0 },
                                     cacheURL: GaoJiXuWidgetSnapshot.lastValidFileURL, at: date)
        SnapshotIO.recordRead(result, kind: kind, family: String(describing: family), at: date)
        return result
    }

    private func entry(from result: SnapshotReadResult, at date: Date) -> GaoJiXuEntry {
        let snapshot = result.snapshot?.projected(at: date, calendar: .autoupdatingCurrent)
        let message: String?
        if snapshot == nil {
            message = "暂时无法读取财务资料"
        } else if result.usedCache {
            message = "上次有效资料 · 打开应用重新同步"
        } else if !result.issues.isEmpty {
            message = "资料读取异常 · 打开应用检查"
        } else if snapshot?.schemaVersion == 1 {
            message = "旧版快照 · 打开应用更新"
        } else {
            message = nil
        }
        return .init(date: date, snapshot: snapshot, statusMessage: message)
    }
}

private extension GaoJiXuWidgetSnapshot {
    /// 演示值仅用于 WidgetKit 占位和组件预览，不作为真实读取失败时的替代内容。
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
                     days: days, netWorth: 12_480, accounts: [], budgetTotal: 2_000, budgetSpent: 865, schemaVersion: 1)
    }

    /// 快照币种的小数位（JPY/KRW 为 0，其余 2），与主应用 SavingsCurrency.fractionDigits 一致。
    /// currency 字段缺失时解码已默认 "CNY"。
    var fractionDigits: Int { (currency == "JPY" || currency == "KRW") ? 0 : 2 }

    var displayCalendar: Calendar {
        var calendar = Calendar.autoupdatingCurrent
        if let timeZone = TimeZone(identifier: timeZoneIdentifier) { calendar.timeZone = timeZone }
        return calendar
    }

    var freshnessText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        if let dataUpdatedAt { return "资料更新 \(formatter.string(from: dataUpdatedAt))" }
        let label = schemaVersion == 1 ? "旧版快照" : "快照生成"
        return "\(label) \(formatter.string(from: updatedAt))"
    }
}

private struct SnapshotFooter: View {
    let entry: GaoJiXuEntry
    let snapshot: GaoJiXuWidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(snapshot.freshnessText).foregroundStyle(.secondary)
            if let message = entry.statusMessage {
                Text(message).foregroundStyle(.orange)
            }
        }
        .font(.system(size: 8))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
}

private struct SnapshotUnavailableView: View {
    let title: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.headline)
            Spacer(minLength: 0)
            Text("暂时无法读取财务资料").font(.caption.weight(.medium))
            Text("打开搞积蓄完成同步后显示。")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private struct FinanceCalendarWidgetView: View {
    let entry: GaoJiXuEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                calendarContent(snapshot)
            } else {
                SnapshotUnavailableView(title: "每日收支与积蓄", symbol: "calendar")
            }
        }
        .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
    }

    private func calendarContent(_ snapshot: GaoJiXuWidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 6 : 3) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("每日收支与积蓄")
                        .font(family == .systemLarge ? .headline : .caption.weight(.semibold)).lineLimit(1)
                    Text(snapshot.monthTitle).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(snapshot.currency).font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            HStack(spacing: 7) {
                legend("支出", color: .red)
                if family == .systemLarge { legend("收入", color: .green) }
                legend("积蓄", color: .orange)
                Spacer()
            }.font(.system(size: 8))
            calendarGrid(snapshot)
            SnapshotFooter(entry: entry, snapshot: snapshot)
        }
    }

    private func calendarGrid(_ snapshot: GaoJiXuWidgetSnapshot) -> some View {
        let leading = snapshot.displayCalendar.component(.weekday, from: snapshot.days.first?.date ?? snapshot.monthStart) - 1
        let weeks = max(1, (leading + snapshot.days.count + 6) / 7)
        return GeometryReader { geometry in
            let cellHeight = max(1, (geometry.size.height - 10 - CGFloat(weeks) * 2) / CGFloat(weeks))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) { weekday in
                    Text(weekday).font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(height: 10)
                }
                ForEach(0..<leading, id: \.self) { _ in Color.clear.frame(height: cellHeight) }
                ForEach(snapshot.days) { day in
                    dayCell(day, snapshot: snapshot)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.horizontal, 1)
                        .frame(height: cellHeight)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 3))
                }
            }
        }
    }

    @ViewBuilder
    private func dayCell(_ day: GaoJiXuWidgetSnapshot.Day, snapshot: GaoJiXuWidgetSnapshot) -> some View {
        if family == .systemLarge {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(day.day)").font(.system(size: 9, weight: .semibold))
                Text(amount(day.expense, prefix: "−", snapshot: snapshot)).foregroundStyle(.red)
                Text(amount(day.income, prefix: "+", snapshot: snapshot)).foregroundStyle(.green)
                Text(amount(day.saving, prefix: "～", snapshot: snapshot)).foregroundStyle(.orange)
            }
            .font(.system(size: 8, design: .monospaced))
            .lineLimit(1).minimumScaleFactor(0.6)
        } else {
            // 中号将日期和支出放在同一行，六周月份也为真实资料时间保留空间。
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 1) {
                    Text("\(day.day)").fontWeight(.semibold)
                    Spacer(minLength: 0)
                    Text(amount(day.expense, prefix: "−", snapshot: snapshot)).foregroundStyle(.red)
                }
                Text(amount(day.saving, prefix: "～", snapshot: snapshot)).foregroundStyle(.orange)
            }
            .font(.system(size: 7, design: .monospaced))
            .lineLimit(1).minimumScaleFactor(0.6)
        }
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 2) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(title)
        }
    }

    private func amount(_ value: Double, prefix: String, snapshot: GaoJiXuWidgetSnapshot) -> String {
        guard abs(value) >= 0.005 else { return "·" }
        // 零小数位币种（JPY/KRW）一律取整；其余币种小额保留两位、大额取整。
        let text = (snapshot.fractionDigits == 0 || abs(value) >= 100) ? String(format: "%.0f", abs(value)) : String(format: "%.2f", abs(value))
        return "\(prefix)\(value < 0 ? "−" : "")\(text)"
    }
}

private struct NetWorthWidgetView: View {
    let entry: GaoJiXuEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                content(snapshot)
            } else {
                SnapshotUnavailableView(title: "净资产", symbol: "building.columns.fill")
            }
        }
        .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
    }

    private func content(_ snapshot: GaoJiXuWidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("净资产", systemImage: "building.columns.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text("\(snapshot.currencySymbol)\(amount(snapshot.netWorth, snapshot: snapshot))")
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
                        Text("\(snapshot.currencySymbol)\(amount(account.balance, snapshot: snapshot))").monospacedDigit()
                    }.font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            SnapshotFooter(entry: entry, snapshot: snapshot)
        }
    }

    private func amount(_ value: Double, snapshot: GaoJiXuWidgetSnapshot) -> String {
        if abs(value) >= 100_000 || snapshot.fractionDigits == 0 { return String(format: "%.0f", value) }
        return String(format: "%.2f", value)
    }
}

struct MonthlyFinanceCalendarWidget: Widget {
    let kind = "GaoJiXuMonthlyFinanceCalendar"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: GaoJiXuProvider(kind: kind)) { entry in
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
        StaticConfiguration(kind: kind, provider: GaoJiXuProvider(kind: kind)) { entry in
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
