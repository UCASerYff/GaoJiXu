import Foundation

struct ConfirmedMonthlyPayment: Codable {
    var id: String
    var title: String
    var amount: Double
    var currency: String
    var date: Date
}

extension SavingsStore {
    /// The authoritative input is the complete set of confirmed payments, never projected bills.
    func reconcileMonthly(_ payments: [ConfirmedMonthlyPayment], ignored: Set<String> = []) throws -> [String: String] {
        guard !loadFailed else { throw NSError(domain:"GQNS",code:1,userInfo:[NSLocalizedDescriptionKey:"积蓄资料库只读保护中"]) }
        let valid = Set(payments.map { "auto-monthly|" + $0.id })
        let removed = ledgerEntries.filter { $0.id.hasPrefix("auto-monthly|") && !valid.contains($0.id) }
        if !removed.isEmpty {
            // Preserve a recoverable financial snapshot before correcting old unconfirmed entries.
            try protectLedgerBeforeReconciliation()
            let before = ledgerEntries
            ledgerEntries.removeAll { $0.id.hasPrefix("auto-monthly|") && !valid.contains($0.id) }
            financesDirty = true; save()
            guard flushSave() else { ledgerEntries = before; throw NSError(domain:"GQNS",code:2,userInfo:[NSLocalizedDescriptionKey:"对账保存失败，待重试"]) }
            notice = "已撤销 \(removed.count) 笔未确认或已撤回的月供自动流水；原账本已备份。"
        }
        var results: [String:String] = [:]
        for p in payments where !ignored.contains(p.id) {
            let bindingKey="gqns.monthly.account." + String(p.id.split(separator:"|").first ?? "")
            if let existing = ledgerEntries.first(where: { $0.id == "auto-monthly|" + p.id }),
               monthlyAccountBinding(bindingKey)==existing.accountID,
               existing.amount == p.amount, existing.date == p.date, existing.note == "月供·" + p.title,
               accounts.contains(where: { $0.id == existing.accountID && $0.currency.rawValue == p.currency }) {
                results[p.id] = flushSave() ? "done" : "pending"
                continue
            }
            let result = recordAutoLedgerEntry(paymentID:p.id,title:p.title,amount:p.amount,currency:p.currency,date:p.date)
            results[p.id] = (result == .recorded || result == .duplicate) ? "done" : "pending"
        }
        return results
    }
}
