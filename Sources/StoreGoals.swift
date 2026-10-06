import Foundation

/// 攒钱目标与积蓄记录域。金额内部用 Decimal 累加，公开方法保持返回 Double。
extension SavingsStore {
    var activeGoals: [SavingsGoal] {
        goals.filter { $0.status == .active || $0.status == .paused }
            .sorted {
                if $0.status != $1.status { return $0.status == .active }
                return $0.deadline < $1.deadline
            }
    }

    var savingDayCount: Int {
        Set(records.filter { $0.kind == .deposit }.map { Calendar.current.startOfDay(for: $0.date) }).count
    }

    var currentSavingStreak: Int {
        let days = Set(records.filter { $0.kind == .deposit }.map { Calendar.current.startOfDay(for: $0.date) })
        guard !days.isEmpty else { return 0 }
        var cursor = Calendar.current.startOfDay(for: Date())
        if !days.contains(cursor), let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: cursor), days.contains(yesterday) { cursor = yesterday }
        var count = 0
        while days.contains(cursor) {
            count += 1
            guard let previous = Calendar.current.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    // MARK: - Savings goals

    /// 目标余额（内部口径）：初始金额 + 记录 Decimal 累加，下限 0。
    func balanceValue(for goal: SavingsGoal) -> Decimal {
        max(0, goal.startingAmountValue + records.filter { $0.goalID == goal.id }.reduce(Decimal(0)) { $0 + ($1.kind == .deposit ? $1.amountValue : -$1.amountValue) })
    }
    func balance(for goal: SavingsGoal) -> Double { MoneyValue.double(balanceValue(for: goal)) }
    func progress(for goal: SavingsGoal) -> Double { goal.targetAmount > 0 ? min(1, max(0, balance(for: goal) / goal.targetAmount)) : 0 }

    /// 币种总积蓄（内部口径）。
    func totalValue(currency: SavingsCurrency) -> Decimal {
        goals.filter { $0.currency == currency && $0.status != .archived }.reduce(Decimal(0)) { $0 + balanceValue(for: $1) }
    }
    func total(currency: SavingsCurrency) -> Double { MoneyValue.double(totalValue(currency: currency)) }

    /// 本月已分配（内部口径）。
    func depositedThisMonthValue(currency: SavingsCurrency) -> Decimal {
        records.filter { $0.kind == .deposit && goal(for: $0.goalID)?.currency == currency && Calendar.current.isDate($0.date, equalTo: Date(), toGranularity: .month) }.reduce(Decimal(0)) { $0 + $1.amountValue }
    }
    func depositedThisMonth(currency: SavingsCurrency) -> Double { MoneyValue.double(depositedThisMonthValue(currency: currency)) }

    /// 今日已分配（内部口径）。
    func depositedTodayValue(currency: SavingsCurrency) -> Decimal {
        records.filter { $0.kind == .deposit && goal(for: $0.goalID)?.currency == currency && Calendar.current.isDateInToday($0.date) }.reduce(Decimal(0)) { $0 + $1.amountValue }
    }
    func depositedToday(currency: SavingsCurrency) -> Double { MoneyValue.double(depositedTodayValue(currency: currency)) }

    func monthlyDeposits(currency: SavingsCurrency, count: Int = 6) -> [(Date, Double)] {
        monthStarts(count: count).map { month in
            (month, MoneyValue.double(records.filter { $0.kind == .deposit && goal(for: $0.goalID)?.currency == currency && SavingsFormatters.monthKey($0.date) == SavingsFormatters.monthKey(month) }.reduce(Decimal(0)) { $0 + $1.amountValue }))
        }
    }
    func goal(for id: String) -> SavingsGoal? { goals.first { $0.id == id } }

    /// v22→v23 迁移：为缺失币种的积蓄记录回填（优先目标币种，其次存钱罐/资金账户币种）。
    func backfilledRecordCurrency(for record: SavingsRecord) -> String {
        if let goal = goal(for: record.goalID) { return goal.currency.rawValue }
        if let account = account(record.savingsAccountID) { return account.currency.rawValue }
        if let account = account(record.fundingAccountID) { return account.currency.rawValue }
        return SavingsCurrency.CNY.rawValue
    }

    func saveGoal(existingID: String?, title: String, targetAmount: Double, startingAmount: Double, currency: SavingsCurrency, deadline: Date, symbol: String, colorKey: String, notes: String, savingsAccountID: String? = nil) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { notice = "请填写目标名称。"; return }
        guard targetAmount > 0 else { notice = "目标金额必须大于 0。"; return }
        guard startingAmount >= 0 else { notice = "初始金额不能小于 0。"; return }
        let cleanSavingsAccountID = savingsAccountID.flatMap { id -> String? in
            guard let account = account(id), !account.isArchived, account.currency == currency else { return nil }
            return account.id
        }
        if let existingID, let index = goals.firstIndex(where: { $0.id == existingID }) {
            goals[index].title = cleanTitle; goals[index].targetAmount = targetAmount; goals[index].startingAmount = startingAmount
            goals[index].currency = currency; goals[index].deadline = deadline; goals[index].symbol = symbol
            goals[index].colorKey = colorKey; goals[index].notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            goals[index].savingsAccountID = cleanSavingsAccountID; refreshCompletion(for: index)
        } else {
            let completed = startingAmount >= targetAmount
            goals.append(.init(id: UUID().uuidString, title: cleanTitle, targetAmount: targetAmount, startingAmount: startingAmount,
                               currency: currency, deadline: deadline, symbol: symbol, colorKey: colorKey,
                               notes: notes.trimmingCharacters(in: .whitespacesAndNewlines), status: completed ? .completed : .active,
                               createdAt: Date(), completedAt: completed ? Date() : nil, savingsAccountID: cleanSavingsAccountID))
        }
        financesDirty = true
        save()
    }

    func setGoalStatus(_ goal: SavingsGoal, status: GoalStatus) {
        guard let index = goals.firstIndex(where: { $0.id == goal.id }) else { return }
        goals[index].status = status; goals[index].completedAt = status == .completed ? (goals[index].completedAt ?? Date()) : nil
        financesDirty = true
        save()
    }

    func deleteGoal(_ goal: SavingsGoal) {
        if records.contains(where: { $0.goalID == goal.id }) {
            guard let index = goals.firstIndex(where: { $0.id == goal.id }) else { return }
            goals[index].status = .archived; notice = "已有记录的目标已归档，以保留历史数据。"
        } else { goals.removeAll { $0.id == goal.id } }
        financesDirty = true
        save()
    }

    @discardableResult
    func saveRecord(existingID: String?, goalID: String, kind: SavingsRecordKind, amount: Double, date: Date, category: SavingsCategory, note: String,
                    fundingAccountID: String? = nil, savingsAccountID: String? = nil) -> Bool {
        guard amount.isFinite, amount > 0 else { notice = "金额必须大于 0。"; return false }
        guard let goalIndex = goals.firstIndex(where: { $0.id == goalID }) else { notice = "请选择一个攒钱目标。"; return false }
        let goal = goals[goalIndex]
        guard let fundingAccountID, let funding = account(fundingAccountID), !funding.isArchived,
              let savingsAccountID, let savings = account(savingsAccountID), !savings.isArchived else {
            notice = "请选择资金账户和目标存钱罐账户。"; return false
        }
        guard funding.id != savings.id else { notice = "资金账户和存钱罐账户不能相同。"; return false }
        guard funding.currency == goal.currency, savings.currency == goal.currency else {
            notice = "两个账户必须与攒钱目标使用相同币种。"; return false
        }
        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        var recordID = existingID ?? UUID().uuidString
        var ledgerEntryID = UUID().uuidString
        if let existingID, let recordIndex = records.firstIndex(where: { $0.id == existingID }) {
            let old = records[recordIndex]
            let oldContribution = old.goalID == goalID ? (old.kind == .deposit ? old.amount : -old.amount) : 0
            if kind == .withdrawal && amount > max(0, balance(for: goals[goalIndex]) - oldContribution) { notice = "撤回金额不能超过该目标的可用分配。"; return false }
            ledgerEntryID = old.ledgerEntryID ?? ledgerEntryID
            recordID = old.id
            records[recordIndex].goalID = goalID; records[recordIndex].kind = kind; records[recordIndex].amount = amount
            records[recordIndex].date = date; records[recordIndex].category = category
            records[recordIndex].note = cleanNote; records[recordIndex].fundingAccountID = funding.id
            records[recordIndex].savingsAccountID = savings.id; records[recordIndex].ledgerEntryID = ledgerEntryID
            records[recordIndex].currency = goal.currency.rawValue
        } else {
            if kind == .withdrawal && amount > balance(for: goals[goalIndex]) { notice = "撤回金额不能超过该目标的可用分配。"; return false }
            records.insert(.init(id: recordID, goalID: goalID, kind: kind, amount: amount, date: date, category: category,
                                 note: cleanNote, gameRewardClaimed: kind == .deposit, createdAt: Date(),
                                 fundingAccountID: funding.id, savingsAccountID: savings.id, ledgerEntryID: ledgerEntryID,
                                 currency: goal.currency.rawValue), at: 0)
        }
        let sourceID = kind == .deposit ? funding.id : savings.id
        let targetID = kind == .deposit ? savings.id : funding.id
        let transferNote = cleanNote.isEmpty ? "\(goal.title) · \(category.title)" : "\(goal.title) · \(cleanNote)"
        let transfer = LedgerEntry(id: ledgerEntryID, kind: .transfer, accountID: sourceID, targetAccountID: targetID,
                                   amount: amount, targetAmount: amount, categoryID: "savings-goal-transfer", date: date,
                                   note: transferNote, createdAt: Date())
        if let entryIndex = ledgerEntries.firstIndex(where: { $0.id == ledgerEntryID }) { ledgerEntries[entryIndex] = transfer }
        else { ledgerEntries.insert(transfer, at: 0) }
        goals[goalIndex].savingsAccountID = savings.id
        records.sort { $0.date > $1.date }; ledgerEntries.sort { $0.date > $1.date }
        if existingID == nil, kind == .deposit {
            let previousStatus = goals[goalIndex].status; refreshCompletion(for: goalIndex)
            grantSavingsGrowth(amount: amount, goal: goals[goalIndex], goalCompleted: previousStatus != .completed && goals[goalIndex].status == .completed)
        } else {
            refreshAllGoalCompletion()
            if existingID == nil {
                addEvent(title: "调整目标分配", detail: "从“\(goals[goalIndex].title)”撤回 \(SavingsFormatters.money(amount, currency: goals[goalIndex].currency))。", symbol: "arrow.up.circle.fill")
            }
        }
        financesDirty = true
        save(); return true
    }

    func deleteRecord(_ record: SavingsRecord) {
        if let ledgerEntryID = record.ledgerEntryID { ledgerEntries.removeAll { $0.id == ledgerEntryID } }
        records.removeAll { $0.id == record.id }; refreshAllGoalCompletion()
        notice = record.gameRewardClaimed ? "记录已删除；已经获得的成长不会被扣除，也不会重复结算。" : "记录已删除。"
        financesDirty = true
        save()
    }

    // MARK: - Completion refresh

    private func refreshAllGoalCompletion() { for index in goals.indices { refreshCompletion(for: index) } }
    private func refreshCompletion(for index: Int) {
        guard goals.indices.contains(index), goals[index].status != .archived else { return }
        if balance(for: goals[index]) >= goals[index].targetAmount { goals[index].status = .completed; goals[index].completedAt = goals[index].completedAt ?? Date() }
        else if goals[index].status == .completed { goals[index].status = .active; goals[index].completedAt = nil }
    }

    // MARK: - Rewards

    private func grantSavingsGrowth(amount: Double, goal: SavingsGoal, goalCompleted: Bool) {
        let earnedTickets = max(0, Int(amount.rounded(.down)))
        adventure.tickets += earnedTickets
        if goalCompleted {
            adventure.tickets += 100
            addEvent(title: "目标达成", detail: "“\(goal.title)”已完成，额外获得 100 张星券。", symbol: "trophy.fill")
        }
        addEvent(
            title: "积蓄兑换星券",
            detail: "分配 \(SavingsFormatters.money(amount, currency: goal.currency))，按每 1 个货币单位 1 张的规则获得 \(earnedTickets) 张星券。",
            symbol: "ticket.fill"
        )
    }
}
