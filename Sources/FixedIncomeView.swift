import SwiftUI

struct FixedIncomeView: View {
    @EnvironmentObject private var store: SavingsStore
    @State private var monthDate = Date()
    @State private var sheet: Sheet?
    @State private var errorMessage: String?

    private struct Sheet: Identifiable {
        enum Content { case new, edit(FixedIncomePlan), confirm(FixedIncomePlan, String) }
        let id = UUID()
        let content: Content
    }
    private var month: String { FixedIncomePeriod.key(monthDate) }
    private var receipts: [FixedIncomeReceipt] { store.fixedIncomeReceipts.filter { $0.month == month }.sorted { $0.confirmedAt > $1.confirmedAt } }
    private var pending: [FixedIncomePlan] {
        let confirmed = Set(receipts.map(\.planID))
        return store.fixedIncomePlans.filter { $0.predicted(on: month) && !confirmed.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("固定收入").font(.title.weight(.semibold))
                        Text("按月查看预计收入。实际收到后，请选择收款账户并确认到账。").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { sheet = .init(content: .new) } label: { Label("新建收入计划", systemImage: "plus") }
                        .buttonStyle(.borderedProminent).disabled(store.loadFailed)
                }
                HStack {
                    Button { step(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("上个月")
                    Text(month).font(.headline.monospacedDigit()).frame(width: 86)
                    Button { step(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("下个月")
                    Button("本月") { monthDate = Date() }
                }
                HStack(alignment: .top, spacing: 16) {
                    summary("待确认的预计收入", values: pending.map { ($0.currency, $0.amount) }, empty: "没有待确认收入")
                    summary("本月归属的已确认收入", values: receipts.map { ($0.currency, $0.amount) }, empty: "尚未确认到账")
                }
                if store.recurringRules.contains(where: { $0.isEnabled && $0.kind == .income }) {
                    Label("账本中另有自动入账的周期收入规则。请勿为同一笔收入重复设置。", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("收入计划").font(.headline)
                    if store.fixedIncomePlans.isEmpty {
                        Text("还没有收入计划。可添加工资、补贴或其他按月收到的款项。").foregroundStyle(.secondary)
                    }
                    ForEach(store.fixedIncomePlans) { plan in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(plan.name).font(.headline)
                                Text("每月 \(plan.dayOfMonth) 日 · \(plan.startMonth) 起 · \(SavingsCatalog.ledgerCategory(plan.category.rawValue)?.name ?? "收入")")
                                    .font(.caption).foregroundStyle(.secondary)
                                if plan.predicted(on: month), !receipts.contains(where: { $0.planID == plan.id }),
                                   let date = FixedIncomePeriod.scheduledDate(month: month, day: plan.dayOfMonth) {
                                    Text("该月预计 \(date.formatted(date: .numeric, time: .omitted)) 到账").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(fixedIncomeMoney(plan.amount, plan.currency)).font(.callout.monospacedDigit())
                            if receipts.contains(where: { $0.planID == plan.id }) {
                                Label("该月已确认", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                            } else if !plan.isEnabled { Text("已停用").foregroundStyle(.secondary) }
                            else if month < plan.startMonth { Text("尚未开始").foregroundStyle(.secondary) }
                            else if month > FixedIncomePeriod.key(Date()) { Text("预计收入").foregroundStyle(.secondary) }
                            else { Button("确认到账…") { sheet = .init(content: .confirm(plan, month)) }.disabled(store.loadFailed) }
                            Menu {
                                Button("编辑计划") { sheet = .init(content: .edit(plan)) }
                                Button(plan.isEnabled ? "停用计划" : "启用计划") {
                                    do { try store.setFixedIncomeEnabled(!plan.isEnabled, for: plan) }
                                    catch { errorMessage = error.localizedDescription }
                                }
                            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize().disabled(store.loadFailed)
                        }
                        Divider()
                    }
                }.padding(16).savingsPanel()
                VStack(alignment: .leading, spacing: 12) {
                    Text("该月确认记录").font(.headline)
                    if receipts.isEmpty { Text("暂无记录").foregroundStyle(.secondary) }
                    ForEach(receipts) { receipt in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack { Text(receipt.name).font(.callout.weight(.medium)); Spacer(); Text(fixedIncomeMoney(receipt.amount, receipt.currency)).monospacedDigit() }
                            Text("到账 \(receipt.receivedOn.formatted(date: .numeric, time: .omitted)) · \(receipt.accountName) · \(ledgerStatus(receipt))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.padding(16).savingsPanel()
            }.padding(24)
        }
        .sheet(item: $sheet) { session in
            Group {
                switch session.content {
                case .new: FixedIncomePlanEditor(original: nil)
                case .edit(let original): FixedIncomePlanEditor(original: original)
                case .confirm(let plan, let month): FixedIncomeConfirmationView(plan: plan, month: month)
                }
            }.id(session.id).environmentObject(store)
        }
        .alert("计划未能更新", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func step(_ value: Int) {
        if let next = FixedIncomePeriod.calendar().date(byAdding: .month, value: value, to: monthDate) { monthDate = next }
    }
    private func summary(_ title: String, values: [(SavingsCurrency, Decimal)], empty: String) -> some View {
        let totals = values.reduce(into: [SavingsCurrency:Decimal]()) { $0[$1.0, default: 0] += $1.1 }
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if totals.isEmpty { Text(empty).foregroundStyle(.secondary) }
            ForEach(SavingsCurrency.allCases.filter { totals[$0] != nil }) { currency in
                Text(fixedIncomeMoney(totals[currency] ?? 0, currency)).font(.title3.monospacedDigit())
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).savingsPanel()
    }
    private func ledgerStatus(_ receipt: FixedIncomeReceipt) -> String {
        guard let entry = store.ledgerEntries.first(where: { $0.id == receipt.id }) else { return "原流水已删除，保留确认记录" }
        return entry.kind == .income && entry.amountValue == receipt.amount && entry.accountID == receipt.accountID && entry.date == receipt.receivedOn && entry.categoryID == receipt.category.rawValue ? "已入账" : "原流水已调整"
    }
}

private func fixedIncomeMoney(_ amount: Decimal, _ currency: SavingsCurrency) -> String {
    "\(currency.rawValue) \(SavingsFormatters.money(MoneyValue.double(amount), currency: currency))"
}

private struct FixedIncomePlanEditor: View {
    @EnvironmentObject private var store: SavingsStore
    @Environment(\.dismiss) private var dismiss
    let original: FixedIncomePlan?
    @State private var name: String
    @State private var amount: String
    @State private var currency: SavingsCurrency
    @State private var category: FixedIncomeCategory
    @State private var day: Int
    @State private var firstDate = Date()
    @State private var errorMessage: String?

    init(original: FixedIncomePlan?) {
        self.original = original
        _name = State(initialValue: original?.name ?? "")
        _amount = State(initialValue: original.map { NSDecimalNumber(decimal: $0.amount).stringValue } ?? "")
        _currency = State(initialValue: original?.currency ?? .CNY)
        _category = State(initialValue: original?.category ?? .other)
        _day = State(initialValue: original?.dayOfMonth ?? 1)
    }

    var body: some View {
        WorkbenchEditorScaffold(
            title: original == nil ? "新建固定收入计划" : "编辑固定收入计划",
            subtitle: "先写预计，实际到账后再确认入账。"
        ) {
            WorkbenchFormSection("收入信息") {
                TextField("收入名称", text: $name).textFieldStyle(.roundedBorder)
                Picker("分类", selection: $category) {
                    ForEach(FixedIncomeCategory.allCases, id: \.self) { value in Text(SavingsCatalog.ledgerCategory(value.rawValue)?.name ?? "收入").tag(value) }
                }
                Picker("币种", selection: $currency) { ForEach(SavingsCurrency.allCases) { Text($0.displayName).tag($0) } }
                TextField("每月金额", text: $amount).textFieldStyle(.roundedBorder)
                    .font(.title3.monospacedDigit())
            }
            WorkbenchFormSection("到账安排") {
                Stepper("预计每月 \(day) 日到账", value: $day, in: 1...31)
                if day >= 29 { Text("短月按该月最后一天预计。").font(.caption).foregroundStyle(.secondary) }
                if let original { LabeledContent("起始月份", value: original.startMonth) }
                else { DatePicker("起始月份（取所选年月）", selection: $firstDate, in: (FixedIncomePeriod.calendar().dateInterval(of: .month, for: Date())?.start ?? Date())..., displayedComponents: .date) }
                Text("保存计划不会增加账户余额；已确认月份保留当时的金额和账户。").font(.caption).foregroundStyle(.secondary)
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        } actions: {
            Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("保存计划") { save() }.buttonStyle(.borderedProminent).tint(SavingsTheme.accent).keyboardShortcut(.defaultAction).disabled(store.loadFailed)
        }
        .frame(width: 570, height: 600)
    }
    private func save() {
        guard let parsed = FixedIncomePlan.parseAmount(amount, currency: currency) else {
            errorMessage = "请输入正数金额，\(currency.rawValue) 最多支持 \(currency.fractionDigits) 位小数。"; return
        }
        let plan = FixedIncomePlan(id: original?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), amount: parsed,
            currency: currency, category: category, dayOfMonth: day, startMonth: original?.startMonth ?? FixedIncomePeriod.key(firstDate), isEnabled: original?.isEnabled ?? true)
        do { try store.saveFixedIncomePlan(plan, replacing: original); dismiss() }
        catch { errorMessage = error.localizedDescription }
    }
}

private struct FixedIncomeConfirmationView: View {
    @EnvironmentObject private var store: SavingsStore
    @Environment(\.dismiss) private var dismiss
    let plan: FixedIncomePlan
    let month: String
    @State private var accountID = "" // Deliberately no inferred/default account for an actual receipt.
    @State private var receivedOn = Date()
    @State private var received = false
    @State private var errorMessage: String?

    var body: some View {
        let accounts = store.activeAccounts.filter { $0.currency == plan.currency }
        WorkbenchEditorScaffold(title: "确认固定收入到账", subtitle: "只有真实收到的款项才进入账本。") {
            WorkbenchFormSection("到账信息") {
                LabeledContent("收入名称", value: plan.name)
                LabeledContent("所属月份", value: month)
                LabeledContent("到账金额", value: fixedIncomeMoney(plan.amount, plan.currency))
                    .font(.title3.weight(.semibold).monospacedDigit())
            }
            WorkbenchFormSection("收款账户与日期") {
                Picker("实际收款账户", selection: $accountID) {
                    Text("请选择账户").tag("")
                    ForEach(accounts) { account in Text(account.name).tag(account.id) }
                }
                if accounts.isEmpty { Text("没有可用的 \(plan.currency.rawValue) 账户。请先在资产账户中添加或启用收款账户。").font(.caption).foregroundStyle(.secondary) }
                DatePicker("实际到账日期", selection: $receivedOn, in: ...Date(), displayedComponents: .date)
                Toggle("我已核对账户，确认这笔收入实际到账", isOn: $received)
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        } actions: {
            Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("确认并记入账本") {
                do { _ = try store.confirmFixedIncome(plan: plan, month: month, accountID: accountID, receivedOn: receivedOn, receivedIsConfirmed: received); dismiss() }
                catch { errorMessage = error.localizedDescription }
            }.buttonStyle(.borderedProminent).tint(SavingsTheme.accent).disabled(!received || !accounts.contains(where: { $0.id == accountID }) || store.loadFailed)
        }
        .frame(width: 570, height: 570)
    }
}
