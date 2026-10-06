import Foundation

/// 账本域：账户、流水、预算与周期自动记账。
/// 财务口径约定：内部一律用 Decimal 累加（模型层存储即 Decimal），
/// 公开方法保持返回 Double——只在边界处经 MoneyValue.double 转换。
extension SavingsStore {
    // MARK: - Accounting

    func account(_ id: String?) -> LedgerAccount? {
        guard let id else { return nil }
        return accounts.first { $0.id == id }
    }

    func savingsRecord(forLedgerEntryID id: String) -> SavingsRecord? {
        records.first { $0.ledgerEntryID == id }
    }

    var defaultLedgerAccountID: String {
        if let id = lastLedgerAccountID, activeAccounts.contains(where: { $0.id == id }) { return id }
        return ledgerEntries.filter { entry in activeAccounts.contains { $0.id == entry.accountID } }
            .max(by: { $0.createdAt < $1.createdAt })?.accountID ?? activeAccounts.first?.id ?? ""
    }

    var activeAccounts: [LedgerAccount] { accounts.filter { !$0.isArchived }.sorted { $0.createdAt < $1.createdAt } }

    func netWorthAccounts(currency: SavingsCurrency) -> [LedgerAccount] {
        let candidates = activeAccounts.filter { $0.currency == currency && $0.includeInNetWorth }
        // 先一次性算好各账户净资产贡献，避免排序闭包内重复 O(流水) 的 accountBalance（原 O(n²)）。
        var contributions: [String: Double] = [:]
        contributions.reserveCapacity(candidates.count)
        for account in candidates { contributions[account.id] = netWorthContribution(for: account) }
        return candidates.sorted {
            let left = contributions[$0.id] ?? 0, right = contributions[$1.id] ?? 0
            if left != right { return left > right }
            return $0.createdAt < $1.createdAt
        }
    }

    func netWorthContribution(for account: LedgerAccount) -> Double {
        account.type.isLiability ? -accountBalance(account) : accountBalance(account)
    }

    /// 旧账户的期初余额仅作兼容基线；新的余额修改都写成可追溯流水。
    func accountBalanceValue(_ account: LedgerAccount) -> Decimal {
        ledgerEntries.reduce(MoneyValue.normalize(account.openingBalance)) { partial, entry in
            if account.type.isLiability {
                if entry.accountID == account.id {
                    switch entry.kind {
                    case .expense: return partial + entry.amountValue
                    case .income, .transfer: return partial - entry.amountValue
                    }
                }
                if entry.kind == .transfer, entry.targetAccountID == account.id { return partial - (entry.targetAmountValue ?? entry.amountValue) }
                return partial
            }
            if entry.accountID == account.id {
                switch entry.kind {
                case .expense, .transfer: return partial - entry.amountValue
                case .income: return partial + entry.amountValue
                }
            }
            if entry.kind == .transfer, entry.targetAccountID == account.id { return partial + (entry.targetAmountValue ?? entry.amountValue) }
            return partial
        }
    }

    func accountBalance(_ account: LedgerAccount) -> Double {
        MoneyValue.double(accountBalanceValue(account))
    }

    /// 净资产（内部口径）：Decimal 累加。
    func netWorthValue(currency: SavingsCurrency) -> Decimal {
        accounts.filter { $0.currency == currency && $0.includeInNetWorth && !$0.isArchived }
            .reduce(Decimal(0)) { $0 + ($1.type.isLiability ? -accountBalanceValue($1) : accountBalanceValue($1)) }
    }

    func netWorth(currency: SavingsCurrency) -> Double {
        MoneyValue.double(netWorthValue(currency: currency))
    }

    /// 月度收入（内部口径）。
    func monthIncomeValue(currency: SavingsCurrency, date: Date = Date()) -> Decimal {
        entries(inMonthOf: date).filter { $0.kind == .income && !$0.isBalanceAdjustment && account($0.accountID)?.currency == currency }.reduce(Decimal(0)) { $0 + $1.amountValue }
    }

    func monthIncome(currency: SavingsCurrency, date: Date = Date()) -> Double {
        MoneyValue.double(monthIncomeValue(currency: currency, date: date))
    }

    /// 月度支出（内部口径）。
    func monthExpenseValue(currency: SavingsCurrency, date: Date = Date()) -> Decimal {
        entries(inMonthOf: date).filter { $0.kind == .expense && !$0.isBalanceAdjustment && account($0.accountID)?.currency == currency }.reduce(Decimal(0)) { $0 + $1.amountValue }
    }

    func monthExpense(currency: SavingsCurrency, date: Date = Date()) -> Double {
        MoneyValue.double(monthExpenseValue(currency: currency, date: date))
    }

    /// 分类支出（内部口径）。
    func expenseValue(categoryID: String, monthKey: String, currency: SavingsCurrency) -> Decimal {
        ledgerEntries.filter {
            $0.kind == .expense && $0.categoryID == categoryID && SavingsFormatters.monthKey($0.date) == monthKey && account($0.accountID)?.currency == currency
        }.reduce(Decimal(0)) { $0 + $1.amountValue }
    }

    func expense(categoryID: String, monthKey: String, currency: SavingsCurrency) -> Double {
        MoneyValue.double(expenseValue(categoryID: categoryID, monthKey: monthKey, currency: currency))
    }

    func budget(for categoryID: String, monthKey: String, currency: SavingsCurrency) -> BudgetPlan? {
        budgets.first { $0.categoryID == categoryID && $0.monthKey == monthKey && $0.currency == currency }
    }

    /// 预算总额（内部口径）。
    func totalBudgetValue(monthKey: String, currency: SavingsCurrency) -> Decimal {
        budgets.filter { $0.monthKey == monthKey && $0.currency == currency }.reduce(Decimal(0)) { $0 + $1.amountValue }
    }

    func totalBudget(monthKey: String, currency: SavingsCurrency) -> Double {
        MoneyValue.double(totalBudgetValue(monthKey: monthKey, currency: currency))
    }

    /// 预算已执行（内部口径）。
    func totalBudgetSpentValue(monthKey: String, currency: SavingsCurrency) -> Decimal {
        ledgerEntries.filter { $0.kind == .expense && !$0.isBalanceAdjustment && SavingsFormatters.monthKey($0.date) == monthKey && account($0.accountID)?.currency == currency }.reduce(Decimal(0)) { $0 + $1.amountValue }
    }

    func totalBudgetSpent(monthKey: String, currency: SavingsCurrency) -> Double {
        MoneyValue.double(totalBudgetSpentValue(monthKey: monthKey, currency: currency))
    }

    func monthlyCashFlow(currency: SavingsCurrency, count: Int = 6) -> [(Date, Double, Double)] {
        monthStarts(count: count).map { ($0, monthIncome(currency: currency, date: $0), monthExpense(currency: currency, date: $0)) }
    }

    func dailyFinanceSummary(currency: SavingsCurrency, month: Date = Date()) -> [GaoJiXuWidgetSnapshot.Day] {
        let calendar = Calendar.autoupdatingCurrent
        let components = calendar.dateComponents([.year, .month], from: month)
        guard let monthStart = calendar.date(from: components), let dayRange = calendar.range(of: .day, in: .month, for: monthStart) else { return [] }
        // 单次遍历按日分组（原先对当月每天各 filter 一遍全部流水/记录，30×O(n)）。
        let accountCurrencies = Dictionary(accounts.map { ($0.id, $0.currency) }, uniquingKeysWith: { first, _ in first })
        let goalCurrencies = Dictionary(goals.map { ($0.id, $0.currency) }, uniquingKeysWith: { first, _ in first })
        var expenseByDay: [Int: Decimal] = [:], incomeByDay: [Int: Decimal] = [:], savingByDay: [Int: Decimal] = [:]
        for entry in ledgerEntries where entry.kind != .transfer && !entry.isBalanceAdjustment {
            guard accountCurrencies[entry.accountID] == currency,
                  calendar.isDate(entry.date, equalTo: monthStart, toGranularity: .month) else { continue }
            let day = calendar.component(.day, from: entry.date)
            if entry.kind == .expense { expenseByDay[day, default: 0] += entry.amountValue }
            else { incomeByDay[day, default: 0] += entry.amountValue }
        }
        for record in records {
            guard goalCurrencies[record.goalID] == currency,
                  calendar.isDate(record.date, equalTo: monthStart, toGranularity: .month) else { continue }
            let day = calendar.component(.day, from: record.date)
            savingByDay[day, default: 0] += record.kind == .deposit ? record.amountValue : -record.amountValue
        }
        return dayRange.map { day in
            let date = calendar.date(byAdding: .day, value: day - 1, to: monthStart) ?? monthStart
            return .init(date: date, day: day,
                         expense: MoneyValue.double(expenseByDay[day] ?? 0),
                         income: MoneyValue.double(incomeByDay[day] ?? 0),
                         saving: MoneyValue.double(savingByDay[day] ?? 0))
        }
    }

    func categoryExpenses(currency: SavingsCurrency, monthKey: String) -> [(LedgerCategoryDefinition, Double)] {
        SavingsCatalog.ledgerCategories.filter { $0.kind == .expense }.compactMap { category in
            let value = expense(categoryID: category.id, monthKey: monthKey, currency: currency)
            return value > 0 ? (category, value) : nil
        }.sorted { $0.1 > $1.1 }
    }

    func saveAccount(existingID: String?, name: String, type: LedgerAccountType, currency: SavingsCurrency, balance: Double, includeInNetWorth: Bool, colorKey: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { notice = "请填写账户名称。"; return }
        guard balance.isFinite && balance >= 0 else { notice = "账户余额必须是有效的非负数字。"; return }
        let target = MoneyValue.normalize(balance)
        let accountID: String
        if let existingID, let index = accounts.firstIndex(where: { $0.id == existingID }) {
            accounts[index].name = cleanName; accounts[index].type = type; accounts[index].currency = currency
            accounts[index].symbol = type.symbol
            accounts[index].includeInNetWorth = includeInNetWorth; accounts[index].colorKey = colorKey
            accountID = existingID
        } else {
            accountID = UUID().uuidString
            accounts.append(.init(id: accountID, name: cleanName, type: type, currency: currency,
                                  openingBalance: 0, symbol: type.symbol, colorKey: colorKey,
                                  includeInNetWorth: includeInNetWorth, isArchived: false, createdAt: Date()))
        }
        if let account = account(accountID) {
            let previous = accountBalanceValue(account)
            let change = target - previous
            if change != 0 {
                let raisesBalance = change > 0
                let kind: LedgerEntryKind = (raisesBalance != type.isLiability) ? .income : .expense
                let note = "账户余额调整：\(SavingsFormatters.money(MoneyValue.double(previous), currency: currency)) → \(SavingsFormatters.money(MoneyValue.double(target), currency: currency))"
                ledgerEntries.insert(.init(id: UUID().uuidString, kind: kind, accountID: accountID,
                                           targetAccountID: nil, amount: MoneyValue.double(abs(change)),
                                           targetAmount: nil, categoryID: LedgerEntry.balanceAdjustmentCategoryID,
                                           date: Date(), note: note, createdAt: Date()), at: 0)
                ledgerEntries.sort { $0.date > $1.date }
                notice = "账户余额已更新，并在记账中生成一笔余额调整记录。"
            }
        }
        financesDirty = true
        save()
    }

    func deleteAccount(_ account: LedgerAccount) {
        if ledgerEntries.contains(where: { $0.accountID == account.id || $0.targetAccountID == account.id }) {
            guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
            accounts[index].isArchived = true; notice = "有流水的账户已归档，以保留账本完整性。"
        } else { accounts.removeAll { $0.id == account.id } }
        financesDirty = true
        save()
    }

    func saveLedgerEntry(existingID: String?, kind: LedgerEntryKind, accountID: String, targetAccountID: String?, amount: Double, targetAmount: Double?, categoryID: String, date: Date, note: String) {
        if let existingID, ledgerEntries.first(where: { $0.id == existingID })?.isBalanceAdjustment == true {
            notice = "余额调整记录请在资产账户中通过再次修改余额更正。"
            return
        }
        if let existingID, savingsRecord(forLedgerEntryID: existingID) != nil {
            notice = "积蓄计划生成的转账请在“积蓄记录”中编辑。"
            return
        }
        guard amount.isFinite, amount > 0 else { notice = "金额必须大于 0。"; return }
        guard let source = account(accountID), !source.isArchived else { notice = "请选择有效账户。"; return }
        var cleanTarget: String?, cleanTargetAmount: Double?
        if kind == .transfer {
            guard let targetAccountID, let target = account(targetAccountID), target.id != source.id, !target.isArchived else { notice = "请选择不同的转入账户。"; return }
            cleanTarget = target.id
            if target.currency == source.currency { cleanTargetAmount = amount }
            else {
                guard let targetAmount, targetAmount.isFinite, targetAmount > 0 else { notice = "跨币种转账需要填写实际转入金额。"; return }
                cleanTargetAmount = targetAmount
            }
        }
        let category = kind == .transfer ? "account-transfer" : categoryID
        if let existingID, let index = ledgerEntries.firstIndex(where: { $0.id == existingID }) {
            ledgerEntries[index].kind = kind; ledgerEntries[index].accountID = accountID
            ledgerEntries[index].targetAccountID = cleanTarget; ledgerEntries[index].amount = amount
            ledgerEntries[index].targetAmount = cleanTargetAmount; ledgerEntries[index].categoryID = category
            ledgerEntries[index].date = date; ledgerEntries[index].note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            ledgerEntries.insert(.init(id: UUID().uuidString, kind: kind, accountID: accountID, targetAccountID: cleanTarget,
                                       amount: amount, targetAmount: cleanTargetAmount, categoryID: category, date: date,
                                       note: note.trimmingCharacters(in: .whitespacesAndNewlines), createdAt: Date()), at: 0)
        }
        lastLedgerAccountID = accountID
        ledgerEntries.sort { $0.date > $1.date }
        financesDirty = true
        save()
    }

    func deleteLedgerEntry(_ entry: LedgerEntry) {
        guard !entry.isBalanceAdjustment else { notice = "余额调整记录请在资产账户中通过再次修改余额更正。"; return }
        guard savingsRecord(forLedgerEntryID: entry.id) == nil else {
            notice = "这笔转账由积蓄计划管理，请在“积蓄记录”中删除。"
            return
        }
        ledgerEntries.removeAll { $0.id == entry.id }; notice = "这笔账已删除。日常记账不结算游戏货币。"
        financesDirty = true
        save()
    }

    func saveBudget(monthKey: String, categoryID: String, currency: SavingsCurrency, amount: Double) {
        let key = "\(monthKey)-\(currency.rawValue)-\(categoryID)"
        if amount <= 0 { budgets.removeAll { $0.id == key } }
        else if let index = budgets.firstIndex(where: { $0.id == key }) { budgets[index].amount = amount }
        else { budgets.append(.init(id: key, monthKey: monthKey, categoryID: categoryID, currency: currency, amount: amount)) }
        financesDirty = true
        save()
    }

    // MARK: - Recurring rules（周期自动记账）

    /// 校验并保存周期规则（按 id 新建或覆盖）。只支持收入与支出。
    func saveRecurringRule(_ rule: RecurringRule) {
        guard rule.kind != .transfer else { notice = "周期记账只支持收入或支出。"; return }
        guard rule.amount > 0 else { notice = "金额必须大于 0。"; return }
        guard let source = account(rule.accountID), !source.isArchived else { notice = "请选择有效账户。"; return }
        if let index = recurringRules.firstIndex(where: { $0.id == rule.id }) { recurringRules[index] = rule }
        else { recurringRules.append(rule) }
        financesDirty = true
        save()
    }

    func deleteRecurringRule(_ rule: RecurringRule) {
        recurringRules.removeAll { $0.id == rule.id }
        financesDirty = true
        save()
    }

    func toggleRecurringRule(_ rule: RecurringRule) {
        guard let index = recurringRules.firstIndex(where: { $0.id == rule.id }) else { return }
        recurringRules[index].isEnabled.toggle()
        financesDirty = true
        save()
    }

    /// 到期物化：对每条启用规则，为 nextDueDate <= asOf 的每一期生成一条普通流水
    /// （标记 recurringRuleID；流水不发放游戏资源），并推进 nextDueDate。
    /// 幂等：到期日随生成推进，重复调用不会重复生成。
    /// 单条规则单次最多生成 366 期，防止异常日期数据导致死循环。
    /// 返回本次生成的流水条数。
    @discardableResult
    func materializeRecurringTransactions(asOf date: Date = Date()) -> Int {
        let calendar = Calendar.current
        var generated = 0
        for index in recurringRules.indices where recurringRules[index].isEnabled {
            var rule = recurringRules[index]
            // 锚定日号：月/年推进始终相对规则当前到期日的日号，小月夹到月末后下一期恢复原日号
            // （1月31日 → 2月28/29日 → 3月31日）。
            let anchorDay = calendar.component(.day, from: rule.nextDueDate)
            var iterations = 0
            while rule.nextDueDate <= date && iterations < 366 {
                let entry = LedgerEntry(id: UUID().uuidString, kind: rule.kind, accountID: rule.accountID, targetAccountID: nil,
                                        amount: MoneyValue.double(rule.amount), targetAmount: nil, categoryID: rule.categoryID,
                                        date: rule.nextDueDate, note: rule.note, createdAt: Date(), recurringRuleID: rule.id)
                ledgerEntries.insert(entry, at: 0)
                rule.nextDueDate = Self.advanced(rule.nextDueDate, frequency: rule.frequency, anchorDay: anchorDay)
                iterations += 1
                generated += 1
            }
            if iterations > 0 { recurringRules[index] = rule }
        }
        if generated > 0 {
            ledgerEntries.sort { $0.date > $1.date }
            financesDirty = true
            save()
        }
        return generated
    }

    /// 周期推进：日/周直接按日历加；月/年保持锚定日号，小月夹到月末。
    static func advanced(_ date: Date, frequency: RecurringFrequency, anchorDay: Int) -> Date {
        let calendar = Calendar.current
        switch frequency {
        case .daily:
            return calendar.date(byAdding: .day, value: 1, to: date) ?? date
        case .weekly:
            return calendar.date(byAdding: .day, value: 7, to: date) ?? date
        case .monthly:
            return addingMonthsPreservingDay(1, anchorDay: anchorDay, to: date)
        case .yearly:
            return addingMonthsPreservingDay(12, anchorDay: anchorDay, to: date)
        }
    }

    /// 在 date 的年月基础上加 months 个月，日号取 min(anchorDay, 目标月天数)，保留时分秒。
    static func addingMonthsPreservingDay(_ months: Int, anchorDay: Int, to date: Date) -> Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .hour, .minute, .second, .nanosecond], from: date)
        guard let year = components.year, let month = components.month else { return date }
        let monthIndex = year * 12 + (month - 1) + months
        let targetYear = monthIndex / 12, targetMonth = monthIndex % 12 + 1
        var firstComponents = DateComponents()
        firstComponents.year = targetYear; firstComponents.month = targetMonth; firstComponents.day = 1
        guard let firstOfMonth = calendar.date(from: firstComponents),
              let dayRange = calendar.range(of: .day, in: .month, for: firstOfMonth) else { return date }
        var target = DateComponents()
        target.year = targetYear; target.month = targetMonth; target.day = min(anchorDay, dayRange.count)
        target.hour = components.hour; target.minute = components.minute
        target.second = components.second; target.nanosecond = components.nanosecond
        return calendar.date(from: target) ?? date
    }

    // MARK: - 联动①：月供扣款自动记账（gaojixu.autoLedgerEntry）

    /// 自动记账结果（回执给主 app 的任务表，只有 recorded/duplicate 会让任务标 done）。
    enum AutoLedgerOutcome: String {
        case recorded   // 流水已落盘
        case duplicate  // 已存在同 id 流水（视为完成，幂等）
        case invalid    // 数据无效（金额非法/空 id），不自动重试
        case noAccount  // 无匹配币种账户：任务保持待处理，界面显示等用户选账户
    }

    /// 静默写入一条支出流水：不弹 sheet、不发 notice、不打扰。
    /// 名称固定为「月供·<订阅名>」，分类用现有「订阅服务」(subscription)；
    /// 防重：流水 id 固定为 auto-monthly|<paymentID>，已存在则返回 duplicate。
    /// P0-2：只写入与扣款币种一致的账户（或用户显式选择的 accountOverride）；
    /// 没有匹配账户时不再落到不同币种的默认账户——返回 noAccount 并回执主 app 保留待处理项。
    @discardableResult
    func recordAutoLedgerEntry(paymentID: String, title: String, amount: Double, currency: String, date: Date,
                               accountOverride: String? = nil) -> AutoLedgerOutcome {
        let entryID = "auto-monthly|\(paymentID)"
        func report(_ outcome: AutoLedgerOutcome, reason: String? = nil) -> AutoLedgerOutcome {
            var info: [AnyHashable: Any] = ["paymentID": paymentID, "outcome": outcome.rawValue]
            if let reason { info["reason"] = reason }
            NotificationCenter.default.post(name: Notification.Name("gaojixu.autoLedgerResult"), object: nil, userInfo: info)
            return outcome
        }
        guard !loadFailed else { return report(.noAccount, reason: "积蓄资料库处于只读保护") }
        guard !paymentID.isEmpty, amount.isFinite, amount > 0 else { return report(.invalid, reason: "金额或单号无效") }
        let existing = ledgerEntries.first { $0.id == entryID }
        let bindingKey = "gqns.monthly.account." + String(paymentID.split(separator: "|").first ?? "")
        let selected = accountOverride ?? monthlyAccountBinding(bindingKey)
        guard let accountID = selected,
              activeAccounts.contains(where: { $0.id == accountID && $0.currency.rawValue == currency }) else {
            return report(.noAccount, reason: "请为这份订阅绑定同币种扣款账户")
        }
        let before = ledgerEntries
        ledgerEntries.removeAll { $0.id == entryID }
        ledgerEntries.insert(.init(id: entryID, kind: .expense, accountID: accountID, targetAccountID: nil,
                                   amount: amount, targetAmount: nil, categoryID: "subscription", date: date,
                                   note: "月供·\(title)", createdAt: existing?.createdAt ?? Date()), at: 0)
        ledgerEntries.sort { $0.date > $1.date }
        financesDirty = true
        save()
        guard flushSave() else {
            ledgerEntries = before
            return report(.noAccount, reason: "保存未完成，将保留待处理状态并重试")
        }
        if accountOverride != nil {
            do { try bindMonthlyAccount(accountID,key:bindingKey) } catch { return report(.noAccount,reason:"流水已保存，账户绑定保存失败，请重试") }
        }
        return report(existing == nil ? .recorded : .duplicate)
    }

    // MARK: - Calendar helpers

    func entries(inMonthOf date: Date) -> [LedgerEntry] { ledgerEntries.filter { SavingsFormatters.monthKey($0.date) == SavingsFormatters.monthKey(date) } }
    func monthStarts(count: Int) -> [Date] {
        let calendar = Calendar.current, current = calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date()
        return (0..<count).reversed().compactMap { calendar.date(byAdding: .month, value: -$0, to: current) }
    }
}
