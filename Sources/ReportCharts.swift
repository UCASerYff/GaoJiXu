import Charts
import SwiftUI

/// 「近 6 个月收支」双柱图数据点。
struct CashFlowBar: Identifiable, Hashable {
    let month: String
    let kind: String
    let value: Double
    var id: String { "\(month)-\(kind)" }
}

/// 「净资产趋势」数据点。
struct NetWorthPoint: Identifiable, Hashable {
    let month: String
    let value: Double
    var id: String { month }
}

/// 「分类支出趋势」单条系列：一个分类在近 6 个月各月的支出。
struct CategoryTrendSeries: Identifiable, Hashable {
    let category: LedgerCategoryDefinition
    let points: [NetWorthPoint]
    var id: String { category.id }
}

enum ReportChartData {
    static let incomeKind = "收入"
    static let expenseKind = "支出"

    private static let monthLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月"
        return formatter
    }()

    static func cashFlowBars(from flow: [(Date, Double, Double)]) -> [CashFlowBar] {
        flow.flatMap { month, income, expense in
            let label = monthLabelFormatter.string(from: month)
            return [CashFlowBar(month: label, kind: incomeKind, value: income),
                    CashFlowBar(month: label, kind: expenseKind, value: expense)]
        }
    }

    static func monthLabels(from flow: [(Date, Double, Double)]) -> [String] {
        flow.map { monthLabelFormatter.string(from: $0.0) }
    }

    /// 近 count 个月支出 Top N 分类的逐月趋势。纯函数：不依赖 SavingsStore，
    /// 账户币种过滤口径与 store 的 expense(categoryID:monthKey:currency:) 一致
    /// （按源账户币种、非转账、月键匹配）。
    static func categoryExpenseTrend(entries: [LedgerEntry], accounts: [LedgerAccount],
                                     currency: SavingsCurrency, count: Int = 6, top: Int = 5,
                                     from now: Date = Date()) -> (months: [String], series: [CategoryTrendSeries]) {
        let monthStarts = recentMonthStarts(count: count, from: now)
        let monthKeys = monthStarts.map { monthKeyFormatter.string(from: $0) }
        let months = monthStarts.map { monthLabelFormatter.string(from: $0) }
        let accountCurrencies = Dictionary(accounts.map { ($0.id, $0.currency) }, uniquingKeysWith: { first, _ in first })
        // 分类 × 月键 的支出聚合（单次遍历）。
        var totals: [String: Double] = [:]
        var byMonth: [String: [String: Double]] = [:]
        for entry in entries where entry.kind == .expense {
            guard accountCurrencies[entry.accountID] == currency else { continue }
            let key = monthKeyFormatter.string(from: entry.date)
            guard monthKeys.contains(key) else { continue }
            totals[entry.categoryID, default: 0] += entry.amount
            byMonth[entry.categoryID, default: [:]][key, default: 0] += entry.amount
        }
        let topCategories = SavingsCatalog.ledgerCategories
            .filter { $0.kind == .expense && (totals[$0.id] ?? 0) > 0 }
            .sorted { (totals[$0.id] ?? 0) > (totals[$1.id] ?? 0) }
            .prefix(top)
        let series = topCategories.map { category in
            CategoryTrendSeries(
                category: category,
                points: zip(monthKeys, months).map { key, label in
                    NetWorthPoint(month: label, value: byMonth[category.id]?[key] ?? 0)
                }
            )
        }
        return (months, Array(series))
    }

    /// 月份键格式化（yyyy-MM），与 SavingsFormatters.monthKey 同口径；此处独立持有以便纯函数复用。
    private static let monthKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    /// 最近 count 个月（含本月）的月初日期，口径与 SavingsStore.monthStarts 一致。
    static func recentMonthStarts(count: Int = 6, from now: Date = Date()) -> [Date] {
        let calendar = Calendar.current
        guard let current = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) else { return [] }
        return (0..<count).reversed().compactMap { calendar.date(byAdding: .month, value: -$0, to: current) }
    }

    /// 月末净资产：计入净资产的账户在「该月末之前」全部流水的余额之和，负债账户取负。
    /// 口径与 SavingsStore.netWorth / accountBalance 完全一致，仅增加日期截止；
    /// 账户间转账（含积蓄转账）在同币种净资产账户内部互相抵消，不影响净资产。
    static func netWorthPoints(accounts: [LedgerAccount], entries: [LedgerEntry], currency: SavingsCurrency, now: Date = Date()) -> [NetWorthPoint] {
        let months = recentMonthStarts(from: now)
        let calendar = Calendar.current
        let included = accounts.filter { $0.currency == currency && $0.includeInNetWorth && !$0.isArchived }
        let sortedEntries = entries.sorted { $0.date < $1.date }
        return months.map { month in
            let end = calendar.date(byAdding: .month, value: 1, to: month) ?? month
            let total = included.reduce(0.0) { sum, account in
                let balance = balance(of: account, entries: sortedEntries, before: end)
                return sum + (account.type.isLiability ? -balance : balance)
            }
            return NetWorthPoint(month: monthLabelFormatter.string(from: month), value: total)
        }
    }

    /// 期初余额 + 截止日期之前的流水累计；流水已按日期升序，越过截止即提前结束。
    private static func balance(of account: LedgerAccount, entries: [LedgerEntry], before end: Date) -> Double {
        var balance = account.openingBalance
        for entry in entries {
            guard entry.date < end else { break }
            balance += delta(of: entry, for: account)
        }
        return balance
    }

    /// 单条流水对账户余额的增减，规则与 SavingsStore.accountBalance 一致。
    private static func delta(of entry: LedgerEntry, for account: LedgerAccount) -> Double {
        if account.type.isLiability {
            if entry.accountID == account.id {
                switch entry.kind {
                case .expense: return entry.amount
                case .income, .transfer: return -entry.amount
                }
            }
            if entry.kind == .transfer, entry.targetAccountID == account.id { return -(entry.targetAmount ?? entry.amount) }
            return 0
        }
        if entry.accountID == account.id {
            switch entry.kind {
            case .expense, .transfer: return -entry.amount
            case .income: return entry.amount
            }
        }
        if entry.kind == .transfer, entry.targetAccountID == account.id { return entry.targetAmount ?? entry.amount }
        return 0
    }
}

enum ReportChartFormat {
    /// 坐标轴紧凑金额：1.2万 / 3,500 / 800；轴标签只取整，不表达到币种小数位。
    static func compactAxis(_ value: Double) -> String {
        let absValue = abs(value)
        if absValue >= 100_000_000 { return "\(trimmed(value / 100_000_000))亿" }
        if absValue >= 10_000 { return "\(trimmed(value / 10_000))万" }
        return "\(Int(value.rounded()))"
    }

    private static func trimmed(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? "\(Int(rounded))" : String(format: "%.1f", rounded)
    }
}

/// 近 6 个月收支双柱图：收入绿 / 支出红，带 Y 轴刻度网格与 X 轴月份标签。
/// 悬停某个月份时以虚线 RuleMark + 气泡显示当月收支数值。
struct CashFlowChart: View {
    let bars: [CashFlowBar]
    /// 有序月份标签（用于 hover 定位与选中查找）。
    let months: [String]
    let currency: SavingsCurrency
    @State private var selectedMonth: String?

    private var hasData: Bool { bars.contains { $0.value > 0 } }

    var body: some View {
        Chart {
            ForEach(bars) { bar in
                BarMark(
                    x: .value("月份", bar.month),
                    y: .value("金额", bar.value)
                )
                .foregroundStyle(by: .value("类型", bar.kind))
                .position(by: .value("类型", bar.kind))
                .cornerRadius(3)
            }
            if let selected = selection {
                RuleMark(x: .value("月份", selected.month))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, spacing: 4) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selected.month).font(.caption2.weight(.semibold))
                            Label(SavingsFormatters.money(selected.income, currency: currency), systemImage: "arrow.down.left")
                                .foregroundStyle(SavingsTheme.green)
                            Label(SavingsFormatters.money(selected.expense, currency: currency), systemImage: "arrow.up.right")
                                .foregroundStyle(SavingsTheme.red)
                        }
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                    }
            }
        }
        .chartForegroundStyleScale([
            ReportChartData.incomeKind: SavingsTheme.green,
            ReportChartData.expenseKind: SavingsTheme.red,
        ])
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: months) { _ in AxisValueLabel() }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(ReportChartFormat.compactAxis(number))
                    }
                }
            }
        }
        .frame(height: 200)
        .overlay {
            if !hasData {
                Text("记录收支后，这里会展示近 6 个月趋势。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            selectedMonth = month(at: location, proxy: proxy, geometry: geometry)
                        case .ended:
                            selectedMonth = nil
                        }
                    }
            }
        }
    }

    private var selection: (month: String, income: Double, expense: Double)? {
        guard let selectedMonth else { return nil }
        let income = bars.first { $0.month == selectedMonth && $0.kind == ReportChartData.incomeKind }?.value ?? 0
        let expense = bars.first { $0.month == selectedMonth && $0.kind == ReportChartData.expenseKind }?.value ?? 0
        return (selectedMonth, income, expense)
    }

    /// 类目轴 hover：绘图区宽度按月份均分条带，光标落在哪条带就选中哪个月。
    private func month(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> String? {
        guard !months.isEmpty else { return nil }
        guard let plotAnchor = proxy.plotFrame else { return nil }
        let plotFrame = geometry[plotAnchor]
        let x = location.x - plotFrame.origin.x
        guard x >= 0, x <= plotFrame.width else { return nil }
        let band = plotFrame.width / CGFloat(months.count)
        let index = min(months.count - 1, max(0, Int(x / band)))
        return months[index]
    }
}

/// 净资产趋势图：LineMark + AreaMark，展示最近 6 个月月末净资产。
struct NetWorthTrendChart: View {
    let points: [NetWorthPoint]
    let currency: SavingsCurrency

    private var hasData: Bool { points.contains { $0.value != 0 } }

    var body: some View {
        Chart {
            ForEach(points) { point in
                AreaMark(
                    x: .value("月份", point.month),
                    y: .value("净资产", point.value)
                )
                .foregroundStyle(LinearGradient(
                    colors: [SavingsTheme.blue.opacity(0.28), SavingsTheme.blue.opacity(0.03)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                LineMark(
                    x: .value("月份", point.month),
                    y: .value("净资产", point.value)
                )
                .foregroundStyle(SavingsTheme.blue)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .symbol(.circle)
                .symbolSize(24)
            }
        }
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: points.map(\.month)) { _ in AxisValueLabel() }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(ReportChartFormat.compactAxis(number))
                    }
                }
            }
        }
        .frame(height: 190)
        .overlay {
            if !hasData {
                Text("记账后，这里会展示最近 6 个月的月末净资产。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// 「近 6 个月收支」面板：标题 + 图例 + 双柱图，样式与 savingsPanel 面板一致。
struct CashFlowChartPanel: View {
    let flow: [(Date, Double, Double)]
    let currency: SavingsCurrency

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("近 6 个月收支").font(.headline)
                Spacer()
                HStack(spacing: 14) {
                    legend(ReportChartData.incomeKind, color: SavingsTheme.green)
                    legend(ReportChartData.expenseKind, color: SavingsTheme.red)
                }
                .font(.caption)
            }
            CashFlowChart(
                bars: ReportChartData.cashFlowBars(from: flow),
                months: ReportChartData.monthLabels(from: flow),
                currency: currency
            )
        }
        .padding(16)
        .savingsPanel()
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title)
        }
    }
}

/// 「净资产趋势」面板：标题 + 口径说明 + 折线面积图。
struct NetWorthTrendPanel: View {
    let points: [NetWorthPoint]
    let currency: SavingsCurrency

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("净资产趋势").font(.headline)
                Spacer()
                Text("月末口径 · \(currency.rawValue)").font(.caption).foregroundStyle(.secondary)
            }
            NetWorthTrendChart(points: points, currency: currency)
        }
        .padding(16)
        .savingsPanel()
    }
}

/// 近 6 个月支出 Top 分类逐月趋势图：多系列 LineMark，图例带分类色。
struct CategoryTrendChart: View {
    let months: [String]
    let series: [CategoryTrendSeries]

    private var hasData: Bool { series.contains { $0.points.contains { $0.value > 0 } } }

    var body: some View {
        Chart {
            ForEach(series) { item in
                ForEach(item.points) { point in
                    LineMark(
                        x: .value("月份", point.month),
                        y: .value("支出", point.value),
                        series: .value("分类", item.category.name)
                    )
                    .foregroundStyle(by: .value("分类", item.category.name))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .symbol(.circle)
                    .symbolSize(20)
                }
            }
        }
        .chartForegroundStyleScale(domain: series.map(\.category.name), range: series.map { SavingsTheme.goalColor($0.category.colorKey) })
        .chartXAxis {
            AxisMarks(values: months) { _ in AxisValueLabel() }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(ReportChartFormat.compactAxis(number))
                    }
                }
            }
        }
        .chartLegend(.visible)
        .frame(height: 200)
        .overlay {
            if !hasData {
                Text("记录支出后，这里会展示 Top 分类的逐月趋势。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// 「分类支出趋势」面板：标题 + Top 5 多系列折线图，样式与 savingsPanel 面板一致。
struct CategoryTrendPanel: View {
    let months: [String]
    let series: [CategoryTrendSeries]
    let currency: SavingsCurrency

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("分类支出趋势 · Top \(series.count)").font(.headline)
                Spacer()
                Text("近 6 个月 · \(currency.rawValue)").font(.caption).foregroundStyle(.secondary)
            }
            CategoryTrendChart(months: months, series: series)
        }
        .padding(16)
        .savingsPanel()
    }
}
