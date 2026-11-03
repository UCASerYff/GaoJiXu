import Foundation

// Compile with the same model/store inputs and -D UNIT_TEST as StoreWidgetSnapshotRegression.
// No app UI, real data path, WidgetCenter reload or system preferences are used.
func tS(_ zh: String, _ en: String) -> String { zh }

@main private struct FixedIncomeRegression {
    struct Failure: Error { let reason: String }
    static func check(_ ok: Bool, _ reason: String) throws { if !ok { throw Failure(reason: reason) } }
    static func rejected(_ error: FixedIncomeError, _ f: () throws -> Void) throws {
        do { try f(); throw Failure(reason: "expected rejection: \(error)") }
        catch let actual as FixedIncomeError { try check(actual == error, "got \(actual) instead of \(error)") }
    }

    @MainActor static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("savings-fixed-income-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root); unsetenv("GAOJIXU_DATA_DIR") }
        setenv("GAOJIXU_DATA_DIR", root.path, 1)
        let zone = TimeZone(identifier: "Asia/Shanghai")!, calendar = FixedIncomePeriod.calendar(zone)
        let date: (Int,Int,Int) -> Date = { y,m,d in calendar.date(from: DateComponents(year:y,month:m,day:d,hour:12))! }
        var now = date(2028,2,28)
        func makeStore() -> SavingsStore { SavingsStore(widgetCurrencyCode:"CNY", now:{now}, calendar:{calendar}, snapshotReloader:{}) }
        let store = makeStore(), filename = root.appendingPathComponent("library.json")
        func disk() throws -> SavingsLibrary { try JSONDecoder().decode(SavingsLibrary.self, from:Data(contentsOf:filename)) }
        let original = try disk(), originalFin = try store.financialFingerprint(), originalAdventure = try store.encoder.encode(store.adventure)
        try check((original.fixedIncomePlans ?? []).isEmpty && (original.fixedIncomeReceipts ?? []).isEmpty,"default plans/receipts must be empty")
        guard let account = store.activeAccounts.first(where:{$0.currency == .CNY && !$0.type.isLiability}) else { throw Failure(reason:"no starter account") }
        let expectedAmount = Decimal(12_345) / 100
        let plan = FixedIncomePlan(id:UUID(),name:"Fixture",amount:expectedAmount,currency:.CNY,category:.other,dayOfMonth:31,startMonth:"2028-02",isEnabled:true)
        try check(calendar.component(.day,from:FixedIncomePeriod.scheduledDate(month:"2028-02",day:31,zone:zone)!) == 29,"leap-year month end")
        try check(calendar.component(.day,from:FixedIncomePeriod.scheduledDate(month:"2027-02",day:31,zone:zone)!) == 28,"non-leap month end")
        try check(FixedIncomePeriod.components("2028-2")==nil && FixedIncomePeriod.components("2028-00")==nil && FixedIncomePeriod.components("2028-13")==nil,"non-canonical month")
        try check(FixedIncomePlan.parseAmount("12oops",currency:.CNY)==nil && FixedIncomePlan.parseAmount("1.234",currency:.CNY)==nil && FixedIncomePlan.parseAmount("1.2",currency:.JPY)==nil,"invalid amount must not be rounded or partially parsed")
        let old = FixedIncomePlan(id:UUID(),name:"Old",amount:1,currency:.CNY,category:.other,dayOfMonth:1,startMonth:"2028-01",isEnabled:true)
        try rejected(.startInPast) { try store.saveFixedIncomePlan(old) }
        try store.saveFixedIncomePlan(plan)
        try check(try store.financialFingerprint() == originalFin && store.ledgerEntries.count == (original.ledgerEntries ?? []).count,"saving a plan posted income")
        now = date(2028,4,12)
        let reopened = makeStore()
        try check(reopened.fixedIncomePlans == [plan] && reopened.fixedIncomeReceipts.isEmpty && reopened.ledgerEntries == store.ledgerEntries,"reopen after missed months backfilled income")
        func confirm(_ p:FixedIncomePlan,_ month:String,_ id:String,_ day:Date,_ consent:Bool=true) throws -> FixedIncomeResult {
            try reopened.confirmFixedIncome(plan:p,month:month,accountID:id,receivedOn:day,receivedIsConfirmed:consent)
        }
        try rejected(.notConfirmed) { _ = try confirm(plan,"2028-04",account.id,now,false) }
        try rejected(.invalidMonth) { _ = try confirm(plan,"2028-4",account.id,now) }
        try rejected(.outsidePeriod) { _ = try confirm(plan,"2028-01",account.id,now) }
        try rejected(.outsidePeriod) { _ = try confirm(plan,"2028-05",account.id,now) }
        try rejected(.invalidDate) { _ = try confirm(plan,"2028-04",account.id,date(2028,4,13)) }
        try rejected(.account) { _ = try confirm(plan,"2028-04","",now) }
        let other = LedgerAccount(id:"usd-fixture",name:"FX",type:.bank,currency:.USD,openingBalance:0,symbol:"banknote",colorKey:"blue",includeInNetWorth:true,isArchived:false,createdAt:now)
        var archived = account; archived.id="archived-fixture"; archived.isArchived=true
        reopened.accounts += [other,archived]
        for invalid in [other.id,archived.id] {try rejected(.account){ _ = try confirm(plan,"2028-04",invalid,now) }}
        reopened.accounts.removeAll{$0.id==other.id || $0.id==archived.id}
        try reopened.setFixedIncomeEnabled(false,for:plan)
        let paused = reopened.fixedIncomePlans[0]
        try rejected(.disabled){ _ = try confirm(paused,"2028-04",account.id,now) }
        try rejected(.stalePlan){ _ = try confirm(plan,"2028-04",account.id,now) }
        try reopened.setFixedIncomeEnabled(true,for:paused)
        let before = reopened.accountBalanceValue(account)
        try check(try confirm(plan,"2028-04",account.id,now) == .posted,"explicit confirmation was not recorded")
        let e = reopened.ledgerEntries.first{$0.id==plan.ledgerID(month:"2028-04")}
        let persisted = try disk()
        try check(e?.amountValue==expectedAmount && e?.kind == .income && e?.categoryID=="other-income" && reopened.accountBalanceValue(account)==before+expectedAmount,"wrong ledger semantics")
        try check(persisted.fixedIncomeReceipts?.count==1 && persisted.ledgerEntries?.filter{$0.id==e?.id}.count==1,"receipt and stable row were not saved together")
        try check(try confirm(plan,"2028-04",account.id,now) == .alreadyConfirmed,"double confirmation")
        var edited=plan; edited.name="Changed";edited.amount=200
        try reopened.saveFixedIncomePlan(edited,replacing:plan)
        try check(reopened.fixedIncomeReceipts[0].amount==expectedAmount && reopened.fixedIncomeReceipts[0].name=="Fixture","historical receipt rewritten by plan edit")
        reopened.deleteLedgerEntry(e!); try check(reopened.flushSave(),"fixture delete failed")
        let afterDelete=makeStore()
        try check(try afterDelete.confirmFixedIncome(plan:edited,month:"2028-04",accountID:account.id,receivedOn:now,receivedIsConfirmed:true) == .alreadyConfirmed,"deleted row replayed after reload")
        try check(!afterDelete.ledgerEntries.contains{$0.id==e?.id},"deleted row recreated")
        // Force a real filesystem error: leave original isolated files untouched in the temporary sibling until restored.
        let blocked=root.appendingPathComponent("blocked");try Data().write(to:blocked)
        setenv("GAOJIXU_DATA_DIR",blocked.path,1)
        try rejected(.persistence){_ = try afterDelete.confirmFixedIncome(plan:edited,month:"2028-03",accountID:account.id,receivedOn:now,receivedIsConfirmed:true)}
        try check(afterDelete.fixedIncomeReceipts.count==1 && !afterDelete.ledgerEntries.contains{$0.id==plan.ledgerID(month:"2028-03")},"failed write left a phantom income")
        setenv("GAOJIXU_DATA_DIR",root.path,1)
        try check(try afterDelete.encoder.encode(afterDelete.adventure)==originalAdventure,"fixed income altered game progress")
        afterDelete.setLoadFailed(true)
        try rejected(.protected){try afterDelete.setFixedIncomeEnabled(false,for:edited)}
        print("PASS: fixed-income plans, currency and date checks, atomic explicit income, durable monthly idempotency, and failed-write rollback")
    }
}
