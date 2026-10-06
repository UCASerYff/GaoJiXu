import AppKit
import Foundation
import SwiftUI

struct FinancialOverviewView: View {
    @EnvironmentObject private var store: SavingsStore
    @EnvironmentObject private var settings: SavingsSettings
    @Binding var selection: SavingsSection
    @State private var currency: SavingsCurrency = .CNY

    private var monthKey: String { SavingsFormatters.monthKey(Date()) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // P0-2：月供自动记账待处理项（无匹配币种账户时在此由用户选账户入账）。
                PendingAutoLedgerBanner()
                // 3.36：月供 ↔ 记账核对表（已入账/待处理/失败/已忽略可撤销）。
                AutoLedgerReconciliationCard()
                HStack {
                    Picker("统计币种", selection: $currency) {
                        ForEach(SavingsCurrency.allCases) { value in Text(value.displayName).tag(value) }
                    }
                    .frame(width: 220)
                    Spacer()
                    Text("不同币种不按未知汇率合并，保证统计真实。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14)], spacing: 14) {
                    SavingsStatTile(value: SavingsFormatters.money(store.netWorth(currency: currency), currency: currency), label: "净资产", symbol: "building.columns.fill", color: SavingsTheme.blue)
                    SavingsStatTile(value: SavingsFormatters.money(store.monthIncome(currency: currency), currency: currency), label: "本月收入", symbol: "arrow.down.left.circle.fill", color: SavingsTheme.green)
                    SavingsStatTile(value: SavingsFormatters.money(store.monthExpense(currency: currency), currency: currency), label: "本月支出", symbol: "arrow.up.right.circle.fill", color: SavingsTheme.red)
                    SavingsStatTile(value: SavingsFormatters.money(store.total(currency: currency), currency: currency), label: "已分配积蓄", symbol: "target", color: SavingsTheme.purple)
                }

                HStack(alignment: .top, spacing: 16) {
                    overviewPanel(title: tS("账户速览", "Accounts"), symbol: "wallet.pass.fill", action: { selection = .accounts }) {
                        let netWorth = store.netWorth(currency: currency)
                        let accounts = store.netWorthAccounts(currency: currency)
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("净资产").font(.caption).foregroundStyle(.secondary)
                                Text(SavingsFormatters.money(netWorth, currency: currency))
                                    .font(.title3.weight(.semibold)).monospacedDigit()
                            }
                            Spacer()
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .font(.title2).foregroundStyle(SavingsTheme.blue)
                                .padding(10).background(SavingsTheme.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                        }
                        Divider()
                        if accounts.isEmpty { SavingsEmptyState(title: "还没有计入净资产的账户", symbol: "wallet.pass") }
                        else {
                            ForEach(accounts.prefix(4)) { account in
                                HStack {
                                    Image(systemName: account.symbol).foregroundStyle(SavingsTheme.goalColor(account.colorKey)).frame(width: 24)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(account.name).font(.callout.weight(.medium))
                                        Text(account.type.title).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(SavingsFormatters.money(store.netWorthContribution(for: account), currency: account.currency))
                                        .font(.callout.monospacedDigit())
                                }
                                .padding(.vertical, 4)
                            }
                            if accounts.count > 4 {
                                Text("按净资产贡献排序 · 共 \(accounts.count) 个账户")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }

                    overviewPanel(title: tS("本月预算", "Budget"), symbol: "gauge.with.dots.needle.67percent", action: { selection = .budgets }) {
                        let planned = store.totalBudget(monthKey: monthKey, currency: currency)
                        let spent = store.totalBudgetSpent(monthKey: monthKey, currency: currency)
                        // 3.37③：预算为 0/未设置时明说「尚未设置预算」，不显示零分母「已用 X / ¥0.00」与无意义进度条。
                        if planned > 0 {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack { Text(tS("已用", "Spent")); Spacer(); Text("\(SavingsFormatters.money(spent, currency: currency)) / \(SavingsFormatters.money(planned, currency: currency))").monospacedDigit() }
                                ProgressView(value: min(1, spent / planned)).tint(spent > planned ? SavingsTheme.red : SavingsTheme.green)
                                Text(spent <= planned ? tS("预算仍在计划内", "On track") : tS("已超出预算，建议复盘分类", "Over budget — review categories"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(tS("尚未设置预算", "No budget set")).font(.callout.weight(.medium))
                                Text(tS("设置分类预算，掌握每月可花空间", "Set category budgets to track monthly room"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                HStack(alignment: .top, spacing: 16) {
                    overviewPanel(title: "最近流水", symbol: "list.bullet.rectangle", action: { selection = .ledger }) {
                        if store.ledgerEntries.isEmpty { SavingsEmptyState(title: "还没有流水", symbol: "square.and.pencil") }
                        else { ForEach(store.ledgerEntries.prefix(5)) { LedgerCompactRow(entry: $0) } }
                    }
                    overviewPanel(title: "当前目标", symbol: "target", action: { selection = .goals }) {
                        if let goal = store.activeGoals.first {
                            VStack(alignment: .leading, spacing: 9) {
                                HStack { Image(systemName: goal.symbol).foregroundStyle(SavingsTheme.goalColor(goal.colorKey)); Text(goal.title).font(.headline); Spacer(); Text("\(Int(store.progress(for: goal) * 100))%").monospacedDigit() }
                                ProgressView(value: store.progress(for: goal)).tint(SavingsTheme.goalColor(goal.colorKey))
                                Text("\(SavingsFormatters.money(store.balance(for: goal), currency: goal.currency)) / \(SavingsFormatters.money(goal.targetAmount, currency: goal.currency))")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("积蓄记录会同步生成账户转账，不会重复计入日常收支。")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        } else { SavingsEmptyState(title: "还没有进行中的目标", symbol: "target") }
                    }
                }

                AdventureMiniCard { selection = .adventure }

                // 3.37③：整月日历挪到首屏末尾且默认折叠（记住用户选择）。
                CollapsibleCalendarCard(currency: currency)
            }
            .padding(.horizontal, 24).padding(.bottom, 28)
        }
        .onAppear { currency = settings.defaultCurrency }
    }

    private struct CollapsibleCalendarCard: View {
        let currency: SavingsCurrency
        @AppStorage("gqns.savings.calendarExpanded") private var expanded = false
        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    HStack {
                        Label(tS("本月每日收支与积蓄", "Daily income & expenses"), systemImage: "calendar")
                            .font(.headline)
                        Spacer()
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded {
                    MonthlyFinanceCalendarCard(currency: currency, showsHeader: false)
                }
            }
            .padding(16)
            .savingsPanel()
        }
    }

    private func overviewPanel<Content: View>(title: String, symbol: String, action: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: symbol).font(.headline)
                Spacer()
                Button("查看") { action() }.buttonStyle(.plain).foregroundStyle(SavingsTheme.blue)
            }
            Divider()
            content()
            Spacer(minLength: 0)
        }
        .padding(16).frame(maxWidth: .infinity, minHeight: 190, alignment: .top).savingsPanel()
    }
}

private struct MonthlyFinanceCalendarCard: View {
    @EnvironmentObject private var store: SavingsStore
    let currency: SavingsCurrency
    /// 3.37③：外层折叠容器已带标题时传 false，避免双标题。
    var showsHeader: Bool = true
    private let calendar = Calendar.autoupdatingCurrent

    private var monthStart: Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date()
    }

    private var summaries: [GaoJiXuWidgetSnapshot.Day] {
        store.dailyFinanceSummary(currency: currency, month: monthStart)
    }

    private var leadingBlankCount: Int {
        guard let first = summaries.first else { return 0 }
        // Calendar weekday is Sunday=1; the grid starts on Sunday like the desktop widget.
        return calendar.component(.weekday, from: first.date) - 1
    }

    private var monthTotals: (expense: Double, income: Double, saving: Double) {
        summaries.reduce(into: (0, 0, 0)) { result, day in
            result.expense += day.expense
            result.income += day.income
            result.saving += day.saving
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsHeader {
                HStack(alignment: .firstTextBaseline) {
                    Label(tS("本月每日收支与积蓄", "Daily income & expenses"), systemImage: "calendar")
                        .font(.headline)
                    Spacer()
                    Text(SavingsFormatters.month.string(from: monthStart))
                        .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                legend(tS("支出", "Exp"), value: monthTotals.expense, color: SavingsTheme.red, prefix: "−")
                legend(tS("收入", "Inc"), value: monthTotals.income, color: SavingsTheme.green, prefix: "+")
                legend(tS("积蓄", "Saved"), value: monthTotals.saving, color: SavingsTheme.orange, prefix: "～")
                Spacer()
                Text(currency.rawValue).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 7), spacing: 5) {
                ForEach(SavingsFormatters.weekdaySymbols, id: \.self) { weekday in
                    Text(weekday).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                ForEach(0..<leadingBlankCount, id: \.self) { _ in
                    Color.clear.frame(minHeight: 55)
                }
                ForEach(summaries) { day in
                    let isFuture = calendar.startOfDay(for: day.date) > calendar.startOfDay(for: Date())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(day.day)").font(.caption.weight(.semibold)).foregroundStyle(.primary)
                        Text(compactAmount(day.expense, prefix: "−")).foregroundStyle(SavingsTheme.red)
                        Text(compactAmount(day.income, prefix: "+")).foregroundStyle(SavingsTheme.green)
                        Text(compactAmount(day.saving, prefix: "～")).foregroundStyle(SavingsTheme.orange)
                    }
                    .font(.system(size: 9, design: .monospaced))
                    .frame(maxWidth: .infinity, minHeight: 55, alignment: .topLeading)
                    .padding(.horizontal, 5).padding(.vertical, 4)
                    .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 6))
                    .opacity(isFuture ? 0.3 : 1)
                    // 3.37④：日期单元格逐项可聚焦（日期 + 当天收支/积蓄），不再整月糊成一段文本。
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(dayAccessibilityLabel(day, isFuture: isFuture))
                }
            }
        }
        .padding(16)
        .savingsPanel()
    }

    private func dayAccessibilityLabel(_ day: GaoJiXuWidgetSnapshot.Day, isFuture: Bool) -> String {
        let dateText = day.date.formatted(date: .abbreviated, time: .omitted)
        if isFuture { return tS("\(dateText)，未来日期", "\(dateText), future") }
        var parts: [String] = [dateText]
        if day.expense > 0.004 { parts.append(tS("支出 \(SavingsFormatters.money(day.expense, currency: currency))", "spent \(SavingsFormatters.money(day.expense, currency: currency))")) }
        if day.income > 0.004 { parts.append(tS("收入 \(SavingsFormatters.money(day.income, currency: currency))", "income \(SavingsFormatters.money(day.income, currency: currency))")) }
        if day.saving > 0.004 { parts.append(tS("积蓄 \(SavingsFormatters.money(day.saving, currency: currency))", "saved \(SavingsFormatters.money(day.saving, currency: currency))")) }
        if parts.count == 1 { parts.append(tS("无记录", "no records")) }
        return parts.joined(separator: tS("，", ", "))
    }

    private func legend(_ title: String, value: Double, color: Color, prefix: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text("\(prefix)\(SavingsFormatters.money(value, currency: currency))").font(.caption.monospacedDigit())
        }
    }

    private func compactAmount(_ value: Double, prefix: String) -> String {
        guard abs(value) >= 0.005 else { return "·" }
        let number = abs(value) >= 100 ? "\(Int(abs(value).rounded()))" : String(format: "%.2f", abs(value))
        return "\(prefix)\(value < 0 ? "−" : "")\(number)"
    }
}

struct LedgerView: View {
    @EnvironmentObject private var store: SavingsStore
    @State private var filter: LedgerEntryKind?
    @SceneStorage("gqns.ledger.search") private var searchText = ""
    @SceneStorage("gqns.ledger.page") private var page=0
    @State private var editing: LedgerEntry?
    @State private var showingEditor = false
    @State private var showingRecurring = false

    private var entries: [LedgerEntry] {
        let kindFiltered = filter.map { kind in store.ledgerEntries.filter { $0.kind == kind && !$0.isBalanceAdjustment } } ?? store.ledgerEntries
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return kindFiltered }
        return kindFiltered.filter { matches($0, query: query) }
    }

    /// 当前筛选结果按「源账户币种」分组的收入/支出小计（转账不计入收支，各币种独立不合并）。
    private var currencySubtotals: [(currency: SavingsCurrency, income: Double, expense: Double)] {
        var income: [SavingsCurrency: Double] = [:]
        var expense: [SavingsCurrency: Double] = [:]
        for entry in entries where entry.kind != .transfer && !entry.isBalanceAdjustment {
            guard let currency = store.account(entry.accountID)?.currency else { continue }
            if entry.kind == .income { income[currency, default: 0] += entry.amount }
            else { expense[currency, default: 0] += entry.amount }
        }
        return SavingsCurrency.allCases.compactMap { currency in
            let incomeValue = income[currency] ?? 0, expenseValue = expense[currency] ?? 0
            guard incomeValue != 0 || expenseValue != 0 else { return nil }
            return (currency, incomeValue, expenseValue)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                searchField
                HStack {
                    Picker("类型", selection: $filter) {
                        Text("全部").tag(nil as LedgerEntryKind?)
                        ForEach(LedgerEntryKind.allCases) { Text($0.title).tag(Optional($0)) }
                    }.pickerStyle(.segmented).frame(maxWidth: 380)
                    Spacer()
                    Text("共 \(entries.count) 笔").font(.caption).foregroundStyle(.secondary)
                    Button { showingRecurring = true } label: { Label("周期记账", systemImage: "repeat") }
                    Button { editing = nil; showingEditor = true } label: { Label("记一笔账", systemImage: "plus") }.buttonStyle(.borderedProminent)
                }
                if !currencySubtotals.isEmpty { subtotalBar }
                GQHistoryPager(page:$page,count:entries.count)
            }.padding(.horizontal, 24).padding(.bottom, 12)

            if entries.isEmpty { emptyState }
            else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        LedgerTableHeader()
                        ForEach(Array(entries.dropFirst(page*100).prefix(100))) { entry in
                            LedgerTableRow(entry: entry) {
                                if entry.isBalanceAdjustment {
                                    store.notice = "余额调整记录请在资产账户中通过再次修改余额更正。"
                                } else if store.savingsRecord(forLedgerEntryID: entry.id) != nil {
                                    store.notice = "这笔转账由积蓄计划管理，请在“积蓄记录”中编辑。"
                                } else { editing = entry; showingEditor = true }
                            } delete: {
                                store.deleteLedgerEntry(entry)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
        }
        .onChange(of:searchText) { _,_ in page=0 }
        .onChange(of:filter) { _,_ in page=0 }
        .sheet(isPresented: $showingEditor) { LedgerEntryEditorView(existingEntry: editing) }
        .sheet(isPresented: $showingRecurring) { RecurringRulesView() }
    }

    /// 分币种小计条：展示当前筛选结果各币种的收入/支出合计，互不合并。
    private var subtotalBar: some View {
        HStack(spacing: 10) {
            ForEach(currencySubtotals, id: \.currency) { subtotal in
                HStack(spacing: 6) {
                    Text(subtotal.currency.rawValue)
                        .font(.caption2.weight(.bold).monospaced())
                        .foregroundStyle(.secondary)
                    Text("收入 \(SavingsFormatters.money(subtotal.income, currency: subtotal.currency))")
                        .foregroundStyle(SavingsTheme.green)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("支出 \(SavingsFormatters.money(subtotal.expense, currency: subtotal.currency))")
                        .foregroundStyle(SavingsTheme.red)
                }
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
            }
            Spacer()
            Text("各币种独立统计，不合并").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索备注、分类、账户或金额", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    }

    private var emptyState: some View {
        if store.ledgerEntries.isEmpty {
            return SavingsEmptyState(title: "还没有流水", symbol: "square.and.pencil", detail: "收入、支出和账户互转都会集中显示在这里。")
        }
        return SavingsEmptyState(title: "没有符合条件的流水", symbol: "magnifyingglass", detail: "换个关键词，或清除搜索与类型筛选试试。")
    }

    /// 搜索匹配：备注、分类名、源/目标账户名与金额字符串（格式化与原始两种写法）。
    private func matches(_ entry: LedgerEntry, query: String) -> Bool {
        let needle = query.lowercased()
        func hit(_ text: String?) -> Bool { text?.lowercased().contains(needle) ?? false }
        if hit(entry.note) { return true }
        if entry.isBalanceAdjustment && hit("余额调整") { return true }
        if hit(SavingsCatalog.ledgerCategory(entry.categoryID)?.name) { return true }
        let source = store.account(entry.accountID)
        if hit(source?.name) { return true }
        if hit(store.account(entry.targetAccountID)?.name) { return true }
        let currency = source?.currency ?? .CNY
        if hit(SavingsFormatters.money(entry.amount, currency: currency)) { return true }
        if hit(SavingsFormatters.money(entry.amount, currency: currency, signed: true)) { return true }
        return hit(String(format: "%.\(currency.fractionDigits)f", entry.amount))
    }
}

private struct SavingsEmptyState: View {
    let title: String
    let symbol: String
    var detail: String = ""
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }
}

struct LedgerCompactRow: View {
    @EnvironmentObject private var store: SavingsStore
    let entry: LedgerEntry

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: entry.isBalanceAdjustment ? "arrow.triangle.2.circlepath" : entry.kind.symbol).foregroundStyle(entry.isBalanceAdjustment ? SavingsTheme.blue : entry.kind == .income ? SavingsTheme.green : entry.kind == .expense ? SavingsTheme.red : SavingsTheme.blue).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.isBalanceAdjustment ? "余额调整" : SavingsCatalog.ledgerCategory(entry.categoryID)?.name ?? entry.kind.title).font(.callout)
                Text(transferRoute).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if let account = store.account(entry.accountID) {
                Text(SavingsFormatters.money(entry.isBalanceAdjustment && account.type.isLiability ? (entry.kind == .expense ? entry.amount : -entry.amount) : (entry.kind == .expense ? -entry.amount : entry.amount), currency: account.currency, signed: true)).font(.caption.monospacedDigit())
            }
        }.padding(.vertical, 3)
    }

    private var transferRoute: String {
        let source = store.account(entry.accountID)?.name ?? "已归档账户"
        guard entry.kind == .transfer, let target = store.account(entry.targetAccountID)?.name else { return source }
        return "\(source) → \(target)"
    }
}

private struct LedgerTableHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("日期").frame(width: 72, alignment: .leading)
            Text("类型").frame(width: 82, alignment: .leading)
            Text("账户 / 去向").frame(width: 220, alignment: .leading)
            Text("分类 / 备注")
            Spacer(minLength: 12)
            Text("金额").frame(width: 122, alignment: .trailing)
            Text("").frame(width: 26)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct LedgerTableRow: View {
    @EnvironmentObject private var store: SavingsStore
    let entry: LedgerEntry
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(SavingsFormatters.shortDay.string(from: entry.date))
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Label(entry.isBalanceAdjustment ? "调整" : entry.kind.title, systemImage: entry.isBalanceAdjustment ? "arrow.triangle.2.circlepath" : entry.kind.symbol)
                .font(.callout.weight(.medium))
                .foregroundStyle(kindColor)
                .frame(width: 82, alignment: .leading)
                .overlay(alignment: .trailing) {
                    if entry.recurringRuleID != nil {
                        Image(systemName: "repeat")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("由周期记账自动生成")
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(sourceName).font(.callout.weight(.medium)).lineLimit(1)
                if let target = store.account(entry.targetAccountID) {
                    Text("→ \(target.name)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: 220, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.isBalanceAdjustment ? "余额调整" : SavingsCatalog.ledgerCategory(entry.categoryID)?.name ?? entry.kind.title)
                    .font(.callout).lineLimit(1)
                if !entry.note.isEmpty { Text(entry.note).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 12)
            if let account = store.account(entry.accountID) {
                Text(SavingsFormatters.money(entry.isBalanceAdjustment && account.type.isLiability ? (entry.kind == .expense ? entry.amount : -entry.amount) : (entry.kind == .expense ? -entry.amount : entry.amount), currency: account.currency, signed: true))
                    .font(.callout.monospacedDigit().weight(.semibold)).foregroundStyle(kindColor)
                    .frame(width: 122, alignment: .trailing)
            } else {
                Text("—").frame(width: 122, alignment: .trailing).foregroundStyle(.secondary)
            }
            Menu {
                if entry.isBalanceAdjustment {
                    Button("通过资产账户调整") { store.notice = "余额调整记录请在资产账户中通过再次修改余额更正。" }
                } else if store.savingsRecord(forLedgerEntryID: entry.id) != nil {
                    Button("由积蓄计划管理") { store.notice = "请在“积蓄记录”中编辑或删除这笔转账。" }
                } else {
                    Button("编辑", action: edit)
                    Button("删除", role: .destructive, action: delete)
                }
            } label: { Image(systemName: "ellipsis").frame(width: 26, height: 26) }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(perform: edit)
        .contextMenu {
            if entry.isBalanceAdjustment {
                Button("通过资产账户调整") { store.notice = "余额调整记录请在资产账户中通过再次修改余额更正。" }
            } else if store.savingsRecord(forLedgerEntryID: entry.id) != nil {
                Button("由积蓄计划管理") { store.notice = "请在“积蓄记录”中编辑或删除这笔转账。" }
            } else {
                Button("编辑", action: edit)
                Button("删除", role: .destructive, action: delete)
            }
        }
        .overlay(alignment: .bottom) { Divider().opacity(0.55) }
    }

    private var sourceName: String { store.account(entry.accountID)?.name ?? "已归档账户" }
    private var kindColor: Color {
        if entry.isBalanceAdjustment { return SavingsTheme.blue }
        return switch entry.kind {
        case .income: SavingsTheme.green
        case .expense: SavingsTheme.red
        case .transfer: SavingsTheme.blue
        }
    }
}

struct LedgerEntryEditorView: View {
    @EnvironmentObject private var store: SavingsStore
    @Environment(\.dismiss) private var dismiss
    let existingEntry: LedgerEntry?
    @State private var kind: LedgerEntryKind
    @State private var accountID: String
    @State private var targetAccountID: String
    @State private var amountExpression: String
    @State private var targetAmount: Double
    @State private var categoryID: String
    @State private var date: Date
    @State private var note: String
    /// 每个类型最后选择的分类：切换类型时记住，切回时恢复（不再粗暴重置为第一个）。
    @State private var lastCategoryByKind: [LedgerEntryKind: String] = [:]

    init(existingEntry: LedgerEntry?) {
        self.existingEntry = existingEntry
        _kind = State(initialValue: existingEntry?.kind ?? .expense)
        _accountID = State(initialValue: existingEntry?.accountID ?? "")
        _targetAccountID = State(initialValue: existingEntry?.targetAccountID ?? "")
        _amountExpression = State(initialValue: existingEntry.map { String($0.amount) } ?? "")
        _targetAmount = State(initialValue: existingEntry?.targetAmount ?? 0)
        _categoryID = State(initialValue: existingEntry?.categoryID ?? "food")
        _date = State(initialValue: existingEntry?.date ?? Date())
        _note = State(initialValue: existingEntry?.note ?? "")
    }

    private var categories: [LedgerCategoryDefinition] { SavingsCatalog.ledgerCategories.filter { $0.kind == kind } }
    /// 分类网格按当前类型下的历史使用频次降序（频次相同保持目录原顺序）。
    private var sortedCategories: [LedgerCategoryDefinition] {
        var frequency: [String: Int] = [:]
        for entry in store.ledgerEntries where entry.kind == kind {
            frequency[entry.categoryID, default: 0] += 1
        }
        return categories.enumerated().sorted { lhs, rhs in
            let left = frequency[lhs.element.id] ?? 0, right = frequency[rhs.element.id] ?? 0
            return left != right ? left > right : lhs.offset < rhs.offset
        }.map(\.element)
    }
    private var source: LedgerAccount? { store.account(accountID) }
    private var target: LedgerAccount? { store.account(targetAccountID) }
    private var crossCurrency: Bool { source?.currency != target?.currency && source != nil && target != nil }
    private var sourceAmount: Double? { AmountCalculation.evaluate(amountExpression).flatMap { $0 > 0 ? $0 : nil } }
    /// 上次同币种对的隐含汇率（转入 ÷ 转出），用于跨币种转账占位提示。
    private var lastRateKey: String? {
        guard let source, let target else { return nil }
        return "savings.fxRate.\(source.currency.rawValue).\(target.currency.rawValue)"
    }
    private var lastRate: Double? {
        guard let lastRateKey else { return nil }
        let value = SavingsBundle.defaults.double(forKey: lastRateKey)
        return value > 0 ? value : nil
    }
    /// 同类型同分类最近 5 条不重复备注（流水已按日期倒序）。
    private var noteSuggestions: [String] {
        guard kind != .transfer, !categoryID.isEmpty else { return [] }
        var seen = Set<String>()
        var suggestions: [String] = []
        for entry in store.ledgerEntries where entry.kind == kind && entry.categoryID == categoryID && !entry.note.isEmpty {
            if seen.insert(entry.note).inserted {
                suggestions.append(entry.note)
                if suggestions.count == 5 { break }
            }
        }
        return suggestions
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(existingEntry == nil ? "记一笔账" : "编辑流水").font(.title2.weight(.semibold))
                Spacer()
                Button("取消") { dismiss() }
                if existingEntry == nil {
                    Button("保存并再记一笔") { saveAndContinue() }
                        .help("保存当前流水后清空金额与备注，保留类型、账户与分类，方便连续记账")
                }
                Button("保存") { if performSave() { dismiss() } }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }.padding(22)
            Divider()
            Form {
                Picker("类型", selection: $kind) { ForEach(LedgerEntryKind.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) } }.pickerStyle(.segmented)
                Picker(kind == .transfer ? "转出账户" : "账户", selection: $accountID) { ForEach(store.activeAccounts) { Text("\($0.name) · \($0.currency.rawValue)").tag($0.id) } }
                if kind == .transfer { Picker("转入账户", selection: $targetAccountID) { Text("请选择").tag(""); ForEach(store.activeAccounts.filter { $0.id != accountID }) { Text("\($0.name) · \($0.currency.rawValue)").tag($0.id) } } }
                AmountCalculatorView(expression: $amountExpression, currency: source?.currency.rawValue ?? "CNY")
                if kind == .transfer && crossCurrency {
                    TextField(target.map { "实际转入（\($0.currency.rawValue)）" } ?? "实际转入", value: $targetAmount, format: .number.precision(.fractionLength(0...2)))
                    impliedRateRow
                }
                if kind != .transfer { categoryGrid }
                dateRow
                HStack {
                    TextField("备注（可选）", text: $note)
                    if !noteSuggestions.isEmpty {
                        Menu {
                            ForEach(noteSuggestions, id: \.self) { suggestion in
                                Button(suggestion) { note = suggestion }
                            }
                        } label: { Image(systemName: "clock.arrow.circlepath") }
                        .menuStyle(.borderlessButton)
                        .frame(width: 28)
                        .help("同分类最近备注，点选填入")
                    }
                }
                Section { Text("日常记账只维护真实收支、账户余额和预算，不发放游戏货币；账户互转不会重复计入收支。") }.font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped).padding(18)
        }.frame(width: 580, height: 800)
        .onAppear {
            if accountID.isEmpty { accountID = store.defaultLedgerAccountID }
            if targetAccountID.isEmpty { targetAccountID = store.activeAccounts.first(where: { $0.id != accountID })?.id ?? "" }
            if categories.contains(where: { $0.id == categoryID }) == false { categoryID = categories.first?.id ?? "" }
            lastCategoryByKind[kind] = categoryID
        }
        .onChange(of: kind) { oldKind, newKind in
            lastCategoryByKind[oldKind] = categoryID
            let remembered = lastCategoryByKind[newKind]
            if let remembered, categories.contains(where: { $0.id == remembered }) { categoryID = remembered }
            else if !categories.contains(where: { $0.id == categoryID }) { categoryID = categories.first?.id ?? "" }
        }
    }

    /// 分类速选网格：图标 + 名称，按使用频次排序，点按即选并高亮。
    private var categoryGrid: some View {
        Section("分类") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: 8)], spacing: 8) {
                ForEach(sortedCategories) { category in
                    let selected = category.id == categoryID
                    Button {
                        categoryID = category.id
                        lastCategoryByKind[kind] = category.id
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: category.symbol)
                                .font(.system(size: 16, weight: .medium))
                            Text(category.name)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .background(
                            selected ? SavingsTheme.goalColor(category.colorKey) : Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// 日期行：DatePicker + 「昨天」「前天」快捷按钮。
    private var dateRow: some View {
        HStack {
            DatePicker("日期", selection: $date, displayedComponents: .date)
            Spacer()
            Button("昨天") { date = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? date }
                .controlSize(.small)
            Button("前天") { date = Calendar.current.date(byAdding: .day, value: -2, to: Date()) ?? date }
                .controlSize(.small)
        }
    }

    /// 跨币种转账：实时隐含汇率（转入 ÷ 转出，4 位小数）；未填转入金额时给出上次汇率占位提示。
    @ViewBuilder
    private var impliedRateRow: some View {
        if let source, let target {
            if let sourceAmount, targetAmount > 0 {
                let rate = targetAmount / sourceAmount
                Text("隐含汇率：1 \(source.currency.rawValue) ≈ \(String(format: "%.4f", rate)) \(target.currency.rawValue)")
                    .font(.caption).foregroundStyle(SavingsTheme.teal)
            } else if let lastRate {
                HStack(spacing: 8) {
                    Text("上次汇率：1 \(source.currency.rawValue) ≈ \(String(format: "%.4f", lastRate)) \(target.currency.rawValue)")
                        .font(.caption).foregroundStyle(.secondary)
                    if let sourceAmount {
                        Button("按此填入") { targetAmount = (sourceAmount * lastRate * 100).rounded() / 100 }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    /// 校验并写入流水；成功返回 true（「保存」与「保存并再记一笔」共用）。
    @discardableResult
    private func performSave() -> Bool {
        guard let amount = AmountCalculation.evaluate(amountExpression), amount > 0, !accountID.isEmpty else { store.notice = "请选择账户并填写有效金额。"; return false }
        if kind == .transfer {
            guard let target, target.id != accountID, !target.isArchived else { store.notice = "请选择不同的有效转入账户。"; return false }
            if crossCurrency && (!targetAmount.isFinite || targetAmount <= 0) { store.notice = "请填写实际转入金额。"; return false }
        }
        store.saveLedgerEntry(existingID: existingEntry?.id, kind: kind, accountID: accountID, targetAccountID: targetAccountID.isEmpty ? nil : targetAccountID, amount: amount, targetAmount: targetAmount > 0 ? targetAmount : nil, categoryID: categoryID, date: date, note: note)
        // 跨币种转账保存成功后记住本次隐含汇率，作为下次同币种对的占位提示。
        if kind == .transfer, crossCurrency, targetAmount > 0, let lastRateKey {
            SavingsBundle.defaults.set(targetAmount / amount, forKey: lastRateKey)
        }
        return true
    }

    /// 保存成功后清空金额与备注，保留类型/账户/分类/日期，焦点回金额框，不关闭编辑器。
    private func saveAndContinue() {
        guard performSave() else { return }
        amountExpression = ""
        targetAmount = 0
        note = ""
        focusAmountField()
    }

    /// AmountCalculatorView 的金额输入框未暴露 FocusState；这里用 AppKit 找到 sheet 中
    /// 第一个文本框（表单项按声明顺序排列，第一个是金额框）并激活，属于尽力而为的聚焦。
    private func focusAmountField() {
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow, let field = Self.firstTextField(in: window.contentView) else { return }
            window.makeFirstResponder(field)
        }
    }

    private static func firstTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        for subview in view.subviews {
            if let field = subview as? NSTextField { return field }
            if let found = firstTextField(in: subview) { return found }
        }
        return nil
    }
}

struct AccountsView: View {
    @EnvironmentObject private var store: SavingsStore
    @State private var editing: LedgerAccount?
    @State private var showingEditor = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("\(store.activeAccounts.count) 个使用中的账户").foregroundStyle(.secondary); Spacer(); Button { editing = nil; showingEditor = true } label: { Label("新建账户", systemImage: "plus") }.buttonStyle(.borderedProminent) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14)], spacing: 14) {
                    ForEach(store.activeAccounts) { account in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack { Image(systemName: account.symbol).font(.title2).foregroundStyle(SavingsTheme.goalColor(account.colorKey)); Text(account.name).font(.headline); Spacer(); Menu { Button("编辑") { editing = account; showingEditor = true }; Button("归档/删除", role: .destructive) { store.deleteAccount(account) } } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton) }
                            Text(SavingsFormatters.money(store.accountBalance(account), currency: account.currency)).font(.title2.weight(.semibold).monospacedDigit())
                            HStack { Text(account.type.title); Spacer(); Text(account.currency.displayName) }.font(.caption).foregroundStyle(.secondary)
                            if account.type.isLiability { Label("余额表示当前负债", systemImage: "info.circle").font(.caption2).foregroundStyle(.secondary) }
                        }.padding(16).savingsPanel()
                    }
                }
            }.padding(.horizontal, 24).padding(.bottom, 28)
        }.sheet(isPresented: $showingEditor) {
            AccountEditorView(existingAccount: editing)
                .id(editing?.id ?? "new-account")
        }
    }
}

private struct AccountEditorView: View {
    @EnvironmentObject private var store: SavingsStore
    @Environment(\.dismiss) private var dismiss
    let existingAccount: LedgerAccount?
    @State private var name: String
    @State private var type: LedgerAccountType
    @State private var currency: SavingsCurrency
    @State private var balance: Double
    @State private var includeInNetWorth: Bool
    @State private var colorKey: String
    private var colors = ["blue", "teal", "green", "orange", "purple", "red"]

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nameInvalid: Bool { trimmedName.isEmpty }
    private var balanceInvalid: Bool { !balance.isFinite || balance < 0 }
    private var canSave: Bool { !nameInvalid && !balanceInvalid }

    init(existingAccount: LedgerAccount?) {
        self.existingAccount = existingAccount
        _name = State(initialValue: existingAccount?.name ?? "")
        _type = State(initialValue: existingAccount?.type ?? .bank)
        _currency = State(initialValue: existingAccount?.currency ?? .CNY)
        _balance = State(initialValue: 0)
        _includeInNetWorth = State(initialValue: existingAccount?.includeInNetWorth ?? true)
        _colorKey = State(initialValue: existingAccount?.colorKey ?? "blue")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(existingAccount == nil ? "新建账户" : "编辑账户").font(.title2.weight(.semibold)); Spacer(); Button("取消") { dismiss() }; Button("保存") { store.saveAccount(existingID: existingAccount?.id, name: name, type: type, currency: currency, balance: balance, includeInNetWorth: includeInNetWorth, colorKey: colorKey); dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!canSave) }.padding(22)
            Divider()
            Form {
                TextField("账户名称", text: $name)
                if nameInvalid {
                    Text("请填写账户名称。").font(.caption).foregroundStyle(SavingsTheme.red)
                }
                Picker("账户类型", selection: $type) { ForEach(LedgerAccountType.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) } }
                Picker("币种", selection: $currency) { ForEach(SavingsCurrency.allCases) { Text($0.displayName).tag($0) } }
                TextField(type.isLiability ? "当前欠款" : "账户余额", value: $balance, format: .number.precision(.fractionLength(0...2)))
                if balanceInvalid {
                    Text("账户余额需要是不小于 0 的有效数字。").font(.caption).foregroundStyle(SavingsTheme.red)
                }
                Text("修改余额会在记账中生成“余额调整”记录，不计入收支统计。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("计入净资产", isOn: $includeInNetWorth)
                Picker("标记色", selection: $colorKey) { ForEach(colors, id: \.self) { Text($0.capitalized).foregroundStyle(SavingsTheme.goalColor($0)).tag($0) } }
            }.formStyle(.grouped).padding(18)
        }.frame(width: 500, height: 500)
            .onAppear { if let existingAccount { balance = store.accountBalance(existingAccount) } }
    }
}

struct BudgetsView: View {
    @EnvironmentObject private var store: SavingsStore
    @EnvironmentObject private var settings: SavingsSettings
    @State private var showingEditor = false
    private var currency: SavingsCurrency { settings.defaultCurrency }
    private var monthKey: String { SavingsFormatters.monthKey(Date()) }
    private var previousMonthKey: String { BudgetMonth.previous(monthKey) }
    private var categories: [LedgerCategoryDefinition] { SavingsCatalog.ledgerCategories.filter { $0.kind == .expense } }
    private var rollover: Bool { settings.budgetRolloverEnabled }

    /// 单分类的上月结余（上月预算 − 上月实际，可为负）。
    private func leftover(for categoryID: String) -> Double {
        let planned = store.budget(for: categoryID, monthKey: previousMonthKey, currency: currency)?.amount ?? 0
        let actual = store.expense(categoryID: categoryID, monthKey: previousMonthKey, currency: currency)
        return planned - actual
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("\(SavingsFormatters.month.string(from: Date())) · \(currency.displayName)").foregroundStyle(.secondary)
                    Spacer()
                    Toggle("滚存上月结余", isOn: Binding(
                        get: { settings.budgetRolloverEnabled },
                        set: { settings.budgetRolloverEnabled = $0 }
                    ))
                    .toggleStyle(.checkbox)
                    .help("开启后：可用额度 = 本月预算 + 上月结余（上月预算 − 上月实际，可为负）")
                    Button { showingEditor = true } label: { Label("编辑预算", systemImage: "slider.horizontal.3") }.buttonStyle(.borderedProminent)
                }
                let total = store.totalBudget(monthKey: monthKey, currency: currency), spent = store.totalBudgetSpent(monthKey: monthKey, currency: currency)
                let totalLeftover = rollover ? categories.reduce(0.0) { $0 + leftover(for: $1.id) } : 0
                let remaining = total - spent + totalLeftover
                let dailyAvailable = remaining / Double(BudgetMonth.remainingDaysInCurrentMonth())
                HStack(spacing: 14) {
                    SavingsStatTile(value: SavingsFormatters.money(total, currency: currency), label: "计划预算", symbol: "target", color: SavingsTheme.blue)
                    SavingsStatTile(value: SavingsFormatters.money(spent, currency: currency), label: "实际支出", symbol: "cart.fill", color: spent > total && total > 0 ? SavingsTheme.red : SavingsTheme.green)
                    SavingsStatTile(value: SavingsFormatters.money(remaining, currency: currency, signed: true), label: rollover ? "可用余额（含结转）" : "可用余额", symbol: "gauge.with.dots.needle.50percent", color: SavingsTheme.purple)
                    SavingsStatTile(value: SavingsFormatters.money(dailyAvailable, currency: currency, signed: true), label: "剩余日均可用", symbol: "calendar.day.timeline.left", color: SavingsTheme.teal)
                }
                VStack(spacing: 0) {
                    ForEach(categories) { category in
                        let planned = store.budget(for: category.id, monthKey: monthKey, currency: currency)?.amount ?? 0
                        let actual = store.expense(categoryID: category.id, monthKey: monthKey, currency: currency)
                        let carried = rollover ? leftover(for: category.id) : 0
                        let effective = planned + carried
                        HStack(spacing: 12) {
                            Image(systemName: category.symbol).foregroundStyle(SavingsTheme.goalColor(category.colorKey)).frame(width: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.name)
                                if rollover && (carried > 0.004 || carried < -0.004) {
                                    Text("含上月结转 \(SavingsFormatters.money(carried, currency: currency, signed: true))")
                                        .font(.caption2)
                                        .foregroundStyle(carried >= 0 ? SavingsTheme.teal : SavingsTheme.red)
                                }
                            }
                            .frame(width: 110, alignment: .leading)
                            ProgressView(value: effective > 0 ? min(1, actual / effective) : 0).tint(actual > effective && effective > 0 ? SavingsTheme.red : SavingsTheme.blue)
                            Text("\(SavingsFormatters.money(actual, currency: currency)) / \(SavingsFormatters.money(effective, currency: currency))").font(.caption.monospacedDigit()).frame(width: 170, alignment: .trailing)
                        }.padding(.vertical, 9)
                        if category.id != categories.last?.id { Divider() }
                    }
                }.padding(.horizontal, 14).savingsPanel()
            }.padding(.horizontal, 24).padding(.bottom, 28)
        }
        .sheet(isPresented: $showingEditor) { BudgetEditorView(monthKey: monthKey, currency: currency) }
        .onAppear {
            BudgetNotifier.requestAuthorizationIfNeeded()
            for category in categories {
                let planned = store.budget(for: category.id, monthKey: monthKey, currency: currency)?.amount ?? 0
                let effective = planned + (rollover ? leftover(for: category.id) : 0)
                guard effective > 0 else { continue }
                let actual = store.expense(categoryID: category.id, monthKey: monthKey, currency: currency)
                BudgetNotifier.notifyIfNeeded(monthKey: monthKey, currency: currency,
                                              categoryID: category.id, categoryName: category.name,
                                              ratio: actual / effective, planned: effective, actual: actual)
            }
        }
    }
}

private struct BudgetEditorView: View {
    @EnvironmentObject private var store: SavingsStore
    @Environment(\.dismiss) private var dismiss
    /// 初始月份（本月）；编辑器内可切到下月，保存到对应 monthKey。
    let initialMonthKey: String
    let currency: SavingsCurrency
    @State private var selectedMonthKey: String
    @State private var amounts: [String: Double] = [:]
    private var categories: [LedgerCategoryDefinition] { SavingsCatalog.ledgerCategories.filter { $0.kind == .expense } }

    init(monthKey: String, currency: SavingsCurrency) {
        self.initialMonthKey = monthKey
        self.currency = currency
        _selectedMonthKey = State(initialValue: monthKey)
    }

    private var nextMonthKey: String { BudgetMonth.next(initialMonthKey) }

    /// monthKey 形如 "yyyy-MM"，直接按年月推算上月，避免依赖 DateFormatter 往返。
    private var previousMonthKey: String { BudgetMonth.previous(selectedMonthKey) }

    private var hasPreviousBudgets: Bool {
        categories.contains { (store.budget(for: $0.id, monthKey: previousMonthKey, currency: currency)?.amount ?? 0) > 0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("编辑月度预算").font(.title2.weight(.semibold))
                    Text("\(selectedMonthKey) · \(currency.rawValue)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.padding(22)
            Divider()
            Form {
                Section {
                    Picker("编辑月份", selection: $selectedMonthKey) {
                        Text("本月（\(initialMonthKey)）").tag(initialMonthKey)
                        Text("下月（\(nextMonthKey)）").tag(nextMonthKey)
                    }
                    .pickerStyle(.segmented)
                    Button { copyFromPreviousMonth() } label: {
                        Label("复制上月预算（\(previousMonthKey)）", systemImage: "doc.on.doc")
                    }
                    .disabled(!hasPreviousBudgets)
                    Text("只填入所选月份尚未设置的分类，已填写的金额不会被覆盖；金额为 0 的分类不会写入预算。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(categories) { category in
                    HStack {
                        Label(category.name, systemImage: category.symbol).frame(width: 150, alignment: .leading)
                        TextField("0", value: Binding(get: { amounts[category.id] ?? 0 }, set: { amounts[category.id] = $0 }), format: .number.precision(.fractionLength(0...2))).multilineTextAlignment(.trailing)
                        Text(currency.symbol).foregroundStyle(.secondary)
                    }
                }
            }.formStyle(.grouped).padding(18)
        }.frame(width: 520, height: 700)
        .onAppear { loadAmounts() }
        .onChange(of: selectedMonthKey) { _, _ in loadAmounts() }
    }

    private func loadAmounts() {
        for category in categories {
            amounts[category.id] = store.budget(for: category.id, monthKey: selectedMonthKey, currency: currency)?.amount ?? 0
        }
    }

    /// 把上月各分类预算填入表单；已填写（>0）的分类不覆盖。
    private func copyFromPreviousMonth() {
        for category in categories where (amounts[category.id] ?? 0) <= 0 {
            if let last = store.budget(for: category.id, monthKey: previousMonthKey, currency: currency), last.amount > 0 {
                amounts[category.id] = last.amount
            }
        }
    }

    /// 跳过金额为 0 的分类，不再写入 0 元预算；已存在的记录在金额为 0 时清除（saveBudget 的 amount<=0 分支）。
    private func save() {
        for category in categories {
            let amount = amounts[category.id] ?? 0
            if amount > 0 {
                store.saveBudget(monthKey: selectedMonthKey, categoryID: category.id, currency: currency, amount: amount)
            } else if store.budget(for: category.id, monthKey: selectedMonthKey, currency: currency) != nil {
                store.saveBudget(monthKey: selectedMonthKey, categoryID: category.id, currency: currency, amount: 0)
            }
        }
        dismiss()
    }
}

struct ReportsView: View {
    @EnvironmentObject private var store: SavingsStore
    @EnvironmentObject private var settings: SavingsSettings
    @State private var currency: SavingsCurrency = .CNY
    private var flow: [(Date, Double, Double)] { store.monthlyCashFlow(currency: currency) }
    private var categories: [(LedgerCategoryDefinition, Double)] { store.categoryExpenses(currency: currency, monthKey: SavingsFormatters.monthKey(Date())) }
    /// 本月收入结构（视图层组合现有流水与分类目录，口径与 store.categoryExpenses 对称）。
    private var incomeCategories: [(LedgerCategoryDefinition, Double)] {
        let key = SavingsFormatters.monthKey(Date())
        var totals: [String: Double] = [:]
        for entry in store.ledgerEntries where entry.kind == .income && !entry.isBalanceAdjustment {
            guard SavingsFormatters.monthKey(entry.date) == key,
                  store.account(entry.accountID)?.currency == currency else { continue }
            totals[entry.categoryID, default: 0] += entry.amount
        }
        return SavingsCatalog.ledgerCategories.filter { $0.kind == .income }.compactMap { category in
            guard let value = totals[category.id], value > 0 else { return nil }
            return (category, value)
        }.sorted { $0.1 > $1.1 }
    }
    /// 近 6 个月支出 Top 5 分类逐月趋势（纯函数数据准备）。
    private var categoryTrend: (months: [String], series: [CategoryTrendSeries]) {
        ReportChartData.categoryExpenseTrend(entries: store.ledgerEntries, accounts: store.accounts, currency: currency)
    }

    private var netFlow: Double { flow.last.map { $0.1 - $0.2 } ?? 0 }
    private var previousNetFlow: Double { flow.dropLast().last.map { $0.1 - $0.2 } ?? 0 }
    /// 环比 = (本月净现金流 − 上月) / |上月|；上月为 0 时百分比无意义，返回 nil 不显示。
    private var monthOverMonth: Double? {
        guard previousNetFlow != 0 else { return nil }
        return (netFlow - previousNetFlow) / abs(previousNetFlow)
    }
    private var monthEntryCount: Int {
        let key = SavingsFormatters.monthKey(Date())
        return store.ledgerEntries.filter { SavingsFormatters.monthKey($0.date) == key }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Picker("统计币种", selection: $currency) {
                        ForEach(SavingsCurrency.allCases) { value in Text(value.displayName).tag(value) }
                    }
                    .frame(width: 220)
                    Spacer()
                    Text("不同币种不按未知汇率合并，保证统计真实。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 14) {
                    SavingsStatTile(value: SavingsFormatters.money(netFlow, currency: currency, signed: true), label: "本月净现金流", symbol: "arrow.up.arrow.down", color: SavingsTheme.blue)
                    monthOverMonthTile
                    SavingsStatTile(value: "\(monthEntryCount)", label: "本月流水", symbol: "list.number", color: SavingsTheme.purple)
                }
                CashFlowChartPanel(flow: flow, currency: currency)
                NetWorthTrendPanel(
                    points: ReportChartData.netWorthPoints(accounts: store.accounts, entries: store.ledgerEntries, currency: currency),
                    currency: currency
                )
                CategoryTrendPanel(months: categoryTrend.months, series: categoryTrend.series, currency: currency)
                HStack(alignment: .top, spacing: 16) {
                    structurePanel(title: "本月支出结构", symbol: "chart.pie.fill",
                                   categories: categories,
                                   emptyText: "记录支出后，这里会按分类展示结构。")
                    structurePanel(title: "本月收入结构", symbol: "chart.bar.fill",
                                   categories: incomeCategories,
                                   emptyText: "记录收入后，这里会按分类展示结构。")
                }
            }.padding(.horizontal, 24).padding(.bottom, 28)
        }
        .onAppear { currency = settings.defaultCurrency }
    }

    /// 收支结构面板：分类进度条 + 百分比金额，收支两款同款风格。
    private func structurePanel(title: String, symbol: String,
                                categories: [(LedgerCategoryDefinition, Double)],
                                emptyText: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.headline)
            if categories.isEmpty { Text("\(emptyText)\n").foregroundStyle(.secondary) }
            else {
                let total = categories.reduce(0) { $0 + $1.1 }
                ForEach(categories, id: \.0.id) { category, amount in
                    HStack { Label(category.name, systemImage: category.symbol).frame(width: 130, alignment: .leading); ProgressView(value: amount, total: max(1, total)).tint(SavingsTheme.goalColor(category.colorKey)); Text("\(Int(amount / max(1, total) * 100))% · \(SavingsFormatters.money(amount, currency: currency))").font(.caption.monospacedDigit()).frame(width: 160, alignment: .trailing) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .top)
        .savingsPanel()
    }

    private var monthOverMonthTile: some View {
        if let change = monthOverMonth {
            let color: Color = change > 0 ? SavingsTheme.green : change < 0 ? SavingsTheme.red : SavingsTheme.blue
            let symbol = change > 0 ? "arrow.up.right" : change < 0 ? "arrow.down.right" : "arrow.right"
            return SavingsStatTile(value: String(format: "%+.0f%%", change * 100), label: "较上月净现金流", symbol: symbol, color: color)
        }
        return SavingsStatTile(value: "—", label: "上月无基数，暂不环比", symbol: "calendar", color: .secondary)
    }
}
