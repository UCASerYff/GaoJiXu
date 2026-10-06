import SwiftUI

/// 周期自动记账（V2.3）：规则列表管理 + 新建/编辑 sheet。
/// 数据接口全部走 SavingsStore 现有 recurringRules / saveRecurringRule /
/// deleteRecurringRule / toggleRecurringRule，视图层不持有额外状态。
struct RecurringRulesView: View {
    @EnvironmentObject private var store: SavingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: RecurringRule?
    @State private var showingEditor = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("周期记账").font(.title2.weight(.semibold))
                    Text("到期自动生成普通流水；回到 App 时会补记漏掉的周期。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { editing = nil; showingEditor = true } label: {
                    Label("新建规则", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(22)
            Divider()
            if store.recurringRules.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "repeat.circle").font(.system(size: 34)).foregroundStyle(SavingsTheme.blue)
                    Text("还没有周期记账规则").font(.headline)
                    Text("房租、工资、订阅等固定收支，设好一次，到期自动入账。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.recurringRules) { rule in
                        RecurringRuleRow(rule: rule) {
                            editing = rule
                            showingEditor = true
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 620, height: 520)
        .sheet(isPresented: $showingEditor) {
            RecurringRuleEditorView(existingRule: editing)
                .environmentObject(store)
        }
    }
}

private struct RecurringRuleRow: View {
    @EnvironmentObject private var store: SavingsStore
    let rule: RecurringRule
    let edit: () -> Void

    private var currency: SavingsCurrency {
        store.account(rule.accountID)?.currency ?? .CNY
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: rule.kind.symbol)
                .foregroundStyle(rule.kind == .income ? SavingsTheme.green : SavingsTheme.red)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(SavingsFormatters.money(rule.amount, currency: currency))
                        .font(.callout.weight(.semibold)).monospacedDigit()
                    Text(SavingsCatalog.ledgerCategory(rule.categoryID)?.name ?? rule.categoryID)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text("\(store.account(rule.accountID)?.name ?? "已归档账户") · \(rule.frequency.title)")
                    Text("·")
                    Text("下次 \(SavingsFormatters.shortDay.string(from: rule.nextDueDate))")
                    if !rule.note.isEmpty {
                        Text("·").foregroundStyle(.tertiary)
                        Text(rule.note).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { _ in store.toggleRecurringRule(rule) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            Menu {
                Button("编辑", action: edit)
                Button("删除", role: .destructive) { store.deleteRecurringRule(rule) }
            } label: { Image(systemName: "ellipsis").frame(width: 26, height: 26) }
            .menuStyle(.borderlessButton)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture(perform: edit)
    }
}

struct RecurringRuleEditorView: View {
    @EnvironmentObject private var store: SavingsStore
    @Environment(\.dismiss) private var dismiss
    let existingRule: RecurringRule?

    @State private var kind: LedgerEntryKind
    @State private var amountExpression: String
    @State private var accountID: String
    @State private var categoryID: String
    @State private var note: String
    @State private var frequency: RecurringFrequency
    @State private var firstDate: Date

    init(existingRule: RecurringRule?) {
        self.existingRule = existingRule
        _kind = State(initialValue: existingRule?.kind == .income ? .income : .expense)
        _amountExpression = State(initialValue: existingRule.map { String(MoneyValue.double($0.amount)) } ?? "")
        _accountID = State(initialValue: existingRule?.accountID ?? "")
        _categoryID = State(initialValue: existingRule?.categoryID ?? "food")
        _note = State(initialValue: existingRule?.note ?? "")
        _frequency = State(initialValue: existingRule?.frequency ?? .monthly)
        _firstDate = State(initialValue: existingRule?.nextDueDate ?? Date())
    }

    private var categories: [LedgerCategoryDefinition] {
        SavingsCatalog.ledgerCategories.filter { $0.kind == kind }
    }
    private var currencyCode: String {
        store.account(accountID)?.currency.rawValue ?? "CNY"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(existingRule == nil ? "新建周期规则" : "编辑周期规则").font(.title2.weight(.semibold))
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
            .padding(22)
            Divider()
            Form {
                Picker("类型", selection: $kind) {
                    Label("支出", systemImage: LedgerEntryKind.expense.symbol).tag(LedgerEntryKind.expense)
                    Label("收入", systemImage: LedgerEntryKind.income.symbol).tag(LedgerEntryKind.income)
                }
                .pickerStyle(.segmented)
                Picker("账户", selection: $accountID) {
                    ForEach(store.activeAccounts) { Text("\($0.name) · \($0.currency.rawValue)").tag($0.id) }
                }
                AmountCalculatorView(expression: $amountExpression, currency: currencyCode)
                Picker("分类", selection: $categoryID) {
                    ForEach(categories) { Label($0.name, systemImage: $0.symbol).tag($0.id) }
                }
                TextField("备注（可选）", text: $note)
                Picker("频率", selection: $frequency) {
                    ForEach(RecurringFrequency.allCases) { Text($0.title).tag($0) }
                }
                DatePicker("首次执行日期", selection: $firstDate, displayedComponents: .date)
                Section {
                    Text("保存后会立即补记已到期（含今天）的周期流水；之后的执行在启动或回到 App 时自动完成。")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .padding(18)
        }
        .frame(width: 560, height: 720)
        .onAppear {
            if accountID.isEmpty { accountID = store.defaultLedgerAccountID }
            if !categories.contains(where: { $0.id == categoryID }) { categoryID = categories.first?.id ?? "" }
        }
        .onChange(of: kind) { _, _ in
            if !categories.contains(where: { $0.id == categoryID }) { categoryID = categories.first?.id ?? "" }
        }
    }

    private func save() {
        guard let amount = AmountCalculation.evaluate(amountExpression), amount > 0 else {
            store.notice = "请填写有效金额。"
            return
        }
        guard !accountID.isEmpty else {
            store.notice = "请选择账户。"
            return
        }
        let rule = RecurringRule(
            id: existingRule?.id ?? UUID(),
            kind: kind,
            amount: Decimal(amount),
            accountID: accountID,
            categoryID: categoryID,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            frequency: frequency,
            nextDueDate: firstDate,
            isEnabled: existingRule?.isEnabled ?? true
        )
        store.saveRecurringRule(rule)
        // 立即补记到期流水（含今天到期的首期），幂等，不会重复生成。
        store.materializeRecurringTransactions()
        dismiss()
    }
}
