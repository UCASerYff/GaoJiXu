import Foundation

extension SavingsStore {
    /// Plan and receipt share the business library's atomic replacement, never a second acknowledgement file.
    func saveFixedIncomePlan(_ plan: FixedIncomePlan, replacing previous: FixedIncomePlan? = nil) throws {
        guard !loadFailed, hasLoadedValidLibrary else { throw FixedIncomeError.protected }
        guard plan.isValid else { throw FixedIncomeError.invalidPlan }
        if let previous {
            guard previous.id == plan.id, previous.startMonth == plan.startMonth,
                  let index = fixedIncomePlans.firstIndex(where: { $0.id == plan.id }),
                  fixedIncomePlans[index] == previous, fixedIncomePlans.filter({ $0.id == plan.id }).count == 1 else { throw FixedIncomeError.stalePlan }
            fixedIncomePlans[index] = plan
        } else {
            guard !fixedIncomePlans.contains(where: { $0.id == plan.id }), !fixedIncomeReceipts.contains(where: { $0.planID == plan.id }) else { throw FixedIncomeError.conflict }
            guard plan.startMonth >= FixedIncomePeriod.key(snapshotNow(), zone: snapshotCalendar().timeZone) else { throw FixedIncomeError.startInPast }
            fixedIncomePlans.append(plan)
        }
        // Synchronous plan-only persistence; no rewards, defaults, ledger edits, or financial dirty flag.
        saveIsDirty = true
        guard flushSave() else {
            if let index = fixedIncomePlans.firstIndex(of: plan) {
                if let previous { fixedIncomePlans[index] = previous }
                else { fixedIncomePlans.remove(at: index) }
            }
            throw FixedIncomeError.persistence
        }
    }

    func setFixedIncomeEnabled(_ enabled: Bool, for plan: FixedIncomePlan) throws {
        var changed = plan; changed.isEnabled = enabled
        try saveFixedIncomePlan(changed, replacing: plan)
    }

    func fixedIncomeReceipt(planID: UUID, month: String) -> FixedIncomeReceipt? {
        fixedIncomeReceipts.first { $0.planID == planID && $0.month == month }
    }

    /// Only called by explicit receipt confirmation; no timer, launch, due date or projection invokes it.
    @discardableResult
    func confirmFixedIncome(plan: FixedIncomePlan, month: String, accountID: String, receivedOn: Date,
                            receivedIsConfirmed: Bool) throws -> FixedIncomeResult {
        guard !loadFailed, hasLoadedValidLibrary else { throw FixedIncomeError.protected }
        guard receivedIsConfirmed else { throw FixedIncomeError.notConfirmed }
        guard FixedIncomePeriod.components(month) != nil else { throw FixedIncomeError.invalidMonth }
        let now = snapshotNow(), zone = snapshotCalendar().timeZone
        guard month >= plan.startMonth, month <= FixedIncomePeriod.key(now, zone: zone) else { throw FixedIncomeError.outsidePeriod }
        let receipts = fixedIncomeReceipts.filter { $0.planID == plan.id && $0.month == month }
        guard receipts.count <= 1 else { throw FixedIncomeError.conflict }
        // A previously confirmed month stays closed, even if the plan, account or original ledger row was subsequently changed.
        if !receipts.isEmpty { return .alreadyConfirmed }
        guard plan.isValid, fixedIncomePlans.filter({ $0.id == plan.id }) == [plan] else { throw FixedIncomeError.stalePlan }
        guard plan.isEnabled else { throw FixedIncomeError.disabled }
        guard !accountID.isEmpty, let account = activeAccounts.first(where: { $0.id == accountID && $0.currency == plan.currency }) else { throw FixedIncomeError.account }
        let cal = FixedIncomePeriod.calendar(zone)
        guard receivedOn.timeIntervalSinceReferenceDate.isFinite,
              FixedIncomePeriod.key(receivedOn, zone: zone) >= plan.startMonth,
              cal.startOfDay(for: receivedOn) <= cal.startOfDay(for: now) else { throw FixedIncomeError.invalidDate }
        let entryID = plan.ledgerID(month: month)
        guard !ledgerEntries.contains(where: { $0.id == entryID }) else { throw FixedIncomeError.conflict }
        let receipt = FixedIncomeReceipt(planID: plan.id, month: month, name: plan.name, amount: plan.amount,
            currency: plan.currency, category: plan.category, accountID: accountID, accountName: account.name,
            receivedOn: receivedOn, confirmedAt: now)
        let entry = LedgerEntry(id: entryID, kind: .income, accountID: accountID, targetAccountID: nil,
            amount: MoneyValue.double(plan.amount), targetAmount: nil, categoryID: plan.category.rawValue,
            date: receivedOn, note: "固定收入·\(plan.name)（\(month)）", createdAt: now)
        let oldFinanceDirty = financesDirty
        fixedIncomeReceipts.append(receipt)
        let index = ledgerEntries.firstIndex { $0.date <= receivedOn } ?? ledgerEntries.endIndex
        ledgerEntries.insert(entry, at: index)
        financesDirty = true; saveIsDirty = true
        guard flushSave() else {
            fixedIncomeReceipts.removeAll { $0.id == entryID }; ledgerEntries.removeAll { $0.id == entryID }
            financesDirty = oldFinanceDirty
            throw FixedIncomeError.persistence
        }
        return .posted
    }
}
