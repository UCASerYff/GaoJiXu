import Foundation

func tS(_ zh: String, _ en: String) -> String { zh }

@main struct StoreWidgetSnapshotRegression {
    struct Failure: Error { let message: String }
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(message: message) }
    }
    static func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    @MainActor final class Fixture {
        let root: URL
        let data: URL
        let shared: URL
        let mirror: URL
        var now = StoreWidgetSnapshotRegression.date("2026-10-14T12:00:00+08:00")
        var calendar = Calendar(identifier: .gregorian)
        var failedTargets: Set<URL> = []
        var sharedAvailable = true
        var reloads = 0
        var store: SavingsStore!
        init(currency: String = "CNY") throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("gaojixu-store-unit-" + UUID().uuidString)
            data = root.appendingPathComponent("business")
            shared = root.appendingPathComponent("group/gaojixu-widget.json")
            mirror = root.appendingPathComponent("mirror/gaojixu-widget.json")
            calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            setenv("GAOJIXU_DATA_DIR", data.path, 1)
            store = SavingsStore(widgetCurrencyCode: currency, now: { [unowned self] in self.now },
                                 calendar: { [unowned self] in self.calendar },
                                 snapshotTargets: { [unowned self] in [self.sharedAvailable ? self.shared : nil, self.mirror] },
                                 snapshotPublisher: { [unowned self] snapshot, urls in
                let result = SnapshotIO.publish(snapshot, to: urls.filter { !self.failedTargets.contains($0) })
                return .init(successfulURLs: result.successfulURLs,
                             failedURLs: result.failedURLs + urls.filter { self.failedTargets.contains($0) })
            }, snapshotReloader: { [unowned self] in self.reloads += 1 })
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
        func snapshot(_ url: URL? = nil) throws -> GaoJiXuWidgetSnapshot {
            try JSONDecoder().decode(GaoJiXuWidgetSnapshot.self, from: Data(contentsOf: url ?? shared))
        }
        func library() throws -> SavingsLibrary {
            try JSONDecoder().decode(SavingsLibrary.self, from: Data(contentsOf: data.appendingPathComponent("library.json")))
        }
        func flush() throws { try StoreWidgetSnapshotRegression.check(store.flushSave(), "business flush failed") }
    }

    @MainActor static func assertBusinessValues(_ f: Fixture, currency: SavingsCurrency) throws {
        let s = try f.snapshot(), store = f.store!
        try check(s.netWorth == store.netWorth(currency: currency), "net worth must match the actual store")
        let expectedAccounts = store.netWorthAccounts(currency: currency)
        try check(s.accounts.map(\.id) == expectedAccounts.map(\.id), "account ordering differs")
        for pair in zip(s.accounts, expectedAccounts) {
            try check(pair.0.balance == store.netWorthContribution(for: pair.1), "account balance differs")
        }
        try check(s.days == store.dailyFinanceSummary(currency: currency, month: f.now), "calendar values differ")
        let key = SavingsFormatters.monthKey(f.now)
        let expectedBudget = store.totalBudget(monthKey: key, currency: currency)
        try check(s.budgetTotal == (expectedBudget > 0 ? expectedBudget : nil), "budget total differs")
        try check(s.budgetSpent == (expectedBudget > 0 ? store.totalBudgetSpent(monthKey: key, currency: currency) : nil), "budget spent differs")
        try check(s.dataRevision == (try f.library()).financialRevision, "snapshot published before business revision")
    }

    @MainActor static func valuesAndTime() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let store = f.store!
        try check(store.financialUpdatedAt == nil, "unknown historical time must stay unknown")
        store.saveAccount(existingID: nil, name: "Unit CNY", type: .bank, currency: .CNY, balance: 1000, includeInNetWorth: true, colorKey: "blue")
        store.saveAccount(existingID: nil, name: "Unit savings", type: .bank, currency: .CNY, balance: 0, includeInNetWorth: true, colorKey: "blue")
        store.saveAccount(existingID: nil, name: "Unit USD", type: .bank, currency: .USD, balance: 200, includeInNetWorth: true, colorKey: "blue")
        let cny = store.accounts.first { $0.name == "Unit CNY" }!, savings = store.accounts.first { $0.name == "Unit savings" }!
        let usd = store.accounts.first { $0.name == "Unit USD" }!
        store.saveLedgerEntry(existingID: nil, kind: .income, accountID: cny.id, targetAccountID: nil, amount: 50.25, targetAmount: nil, categoryID: "salary", date: f.now, note: "unit income")
        store.saveLedgerEntry(existingID: nil, kind: .expense, accountID: cny.id, targetAccountID: nil, amount: 20.15, targetAmount: nil, categoryID: "food", date: f.now, note: "unit expense")
        let expense = store.ledgerEntries.first { $0.note == "unit expense" }!
        store.saveLedgerEntry(existingID: nil, kind: .expense, accountID: cny.id, targetAccountID: nil, amount: 12, targetAmount: nil, categoryID: "food", date: date("2026-11-03T12:00:00+08:00"), note: "future unit expense")
        try check(store.saveRecord(existingID: nil, goalID: store.goals[0].id, kind: .deposit, amount: 30, date: f.now,
                                   category: .other, note: "unit savings", fundingAccountID: cny.id, savingsAccountID: savings.id), "saving failed")
        store.saveBudget(monthKey: "2026-10", categoryID: "food", currency: .CNY, amount: 500)
        store.saveBudget(monthKey: "2026-11", categoryID: "food", currency: .CNY, amount: 700)
        try f.flush(); try assertBusinessValues(f, currency: .CNY)
        let original = try f.snapshot()
        try check(original.days.first { $0.day == 14 }?.saving == 30, "saving transfer must appear exactly once")
        try check(original.dataUpdatedAt == f.now, "financial edit time missing")
        f.now = date("2026-10-15T12:00:00+08:00")
        store.saveLedgerEntry(existingID: expense.id, kind: .expense, accountID: cny.id, targetAccountID: nil, amount: 25.25, targetAmount: nil, categoryID: "food", date: expense.date, note: expense.note)
        try f.flush(); try assertBusinessValues(f, currency: .CNY)
        try check(try f.snapshot().dataUpdatedAt == f.now, "financial edit did not advance timestamp")
        store.deleteLedgerEntry(store.ledgerEntries.first { $0.id == expense.id }!)
        store.deleteRecord(store.records[0])
        try f.flush(); try assertBusinessValues(f, currency: .CNY)
        let beforeGame = try f.snapshot(), oldBytes = try Data(contentsOf: f.shared)
        f.now = date("2026-10-16T12:00:00+08:00")
        store.addEvent(title: "unit", detail: "game only", symbol: "circle")
        store.ledgerEntries.reverse()
        store.save(); try f.flush()
        try check(store.financialUpdatedAt == beforeGame.dataUpdatedAt, "game/reordering changed financial timestamp")
        try check(try Data(contentsOf: f.shared) == oldBytes, "game-only save rewrote snapshot")
        store.setWidgetCurrency("USD"); try assertBusinessValues(f, currency: .USD)
        try check(try f.snapshot().netWorth == 200, "currency switch used wrong accounts")
        try check(store.financialUpdatedAt == beforeGame.dataUpdatedAt, "display currency changed business time")
        store.saveAccount(existingID: usd.id, name: usd.name, type: usd.type, currency: usd.currency, balance: 250, includeInNetWorth: true, colorKey: usd.colorKey)
        try f.flush(); try assertBusinessValues(f, currency: .USD)
        try check(try f.snapshot().netWorth == 250, "account edit missing from snapshot")
        store.setWidgetCurrency("CNY")
        let october = try f.snapshot()
        f.now = date("2026-11-01T00:30:00+08:00")
        store.maintainWidgetSnapshot()
        let november = try f.snapshot()
        try check(november.days.count == 30 && november.budgetTotal == 700 && november.budgetSpent == 12, "month rollover values stale")
        try check(november.dataUpdatedAt == october.dataUpdatedAt && november.sourceSavedAt == october.sourceSavedAt, "rollover fabricated source freshness")
        try check(october.projected(at: f.now, calendar: f.calendar).days == november.days, "closed-app projection differs")
        f.calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        store.maintainWidgetSnapshot()
        try check(try f.snapshot().days.count == 31 && f.snapshot().budgetTotal == 500, "timezone boundary did not restore October")
        try check(try f.snapshot().dataUpdatedAt == october.dataUpdatedAt, "timezone changed source data time")
        let reloads = f.reloads
        store.maintainWidgetSnapshot(); store.maintainWidgetSnapshot()
        try check(f.reloads == reloads, "unchanged maintenance triggered reloads")
        print("PASS Store values/time: ledger edit/delete, savings, account balance, currency, canonical financial revision, game timestamp, rollover, closed-app projection, timezone")
    }

    @MainActor static func retryAndRepair() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let store = f.store!, original = try Data(contentsOf: f.shared)
        f.failedTargets = [f.shared]
        store.setWidgetCurrency("USD")
        try check(try Data(contentsOf: f.shared) == original, "currency failure removed valid snapshot")
        try check(store.financesDirty && store.widgetSnapshotError != nil, "snapshot failure lost pending work")
        let pending = store.pendingWidgetSnapshot!.revision, reloads = f.reloads
        store.maintainWidgetSnapshot(); store.maintainWidgetSnapshot()
        try check(store.pendingWidgetSnapshot?.revision == pending && f.reloads == reloads, "failed retry regenerated/reloaded revision")
        f.failedTargets = []
        store.maintainWidgetSnapshot()
        try check(!store.financesDirty && store.pendingWidgetSnapshot == nil && f.reloads == reloads + 1, "retry needs manual financial edit")
        f.failedTargets = [f.mirror]
        store.setWidgetCurrency("CNY")
        let partialReloads = f.reloads
        store.maintainWidgetSnapshot(); store.maintainWidgetSnapshot()
        try check(f.reloads == partialReloads && store.financesDirty, "partial success reload loop")
        f.failedTargets = []; store.maintainWidgetSnapshot()
        try check(!store.financesDirty, "mirror retry did not finish")
        try original.write(to: f.mirror)
        store.maintainWidgetSnapshot()
        try check(try f.snapshot().revision == f.snapshot(f.mirror).revision, "stale mirror not repaired")
        try Data("broken snapshot".utf8).write(to: f.shared)
        store.maintainWidgetSnapshot()
        try check(try f.snapshot().revision == f.snapshot(f.mirror).revision, "corrupt shared snapshot not repaired")
        let newer = Data("{\"schemaVersion\":999}".utf8)
        try newer.write(to: f.shared)
        store.maintainWidgetSnapshot()
        try check(try Data(contentsOf: f.shared) == newer && store.financesDirty, "newer schema overwritten")
        try FileManager.default.removeItem(at: f.shared)
        store.maintainWidgetSnapshot()
        f.sharedAvailable = false
        store.setWidgetCurrency("USD")
        try check(store.financesDirty, "nil shared target acknowledged success")
        f.sharedAvailable = true; store.maintainWidgetSnapshot()
        try check(!store.financesDirty, "restored group did not retry")
        let diagnostic = try Data(contentsOf: f.shared.deletingLastPathComponent().appendingPathComponent("WidgetDiagnostics/publisher.json"))
        let text = String(decoding: diagnostic, as: UTF8.self)
        try check(!text.contains(f.root.path) && text.contains("dataRevision") && text.contains("published"), "diagnostic leaks paths or lacks outcome")
        print("PASS Store retry/repair: atomic currency failure, shared/mirror partial failure, deduplicated reload, stale/corrupt repair, future schema preservation, unavailable container, publisher diagnostic")
    }

    @MainActor static func persistenceProtection() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let store = f.store!, oldRevision = store.financialRevision, oldTime = store.financialUpdatedAt
        let original = try Data(contentsOf: f.shared)
        let moved = f.root.appendingPathComponent("saved-business")
        try FileManager.default.moveItem(at: f.data, to: moved)
        try Data("blocked directory".utf8).write(to: f.data)
        store.saveAccount(existingID: nil, name: "unit failure", type: .cash, currency: .CNY, balance: 42, includeInNetWorth: true, colorKey: "blue")
        try check(!store.flushSave(), "business write failure acknowledged")
        try check(store.financialRevision == oldRevision && store.financialUpdatedAt == oldTime, "failed business save advanced baseline")
        try check(try Data(contentsOf: f.shared) == original, "uncommitted data was published")
        try FileManager.default.removeItem(at: f.data)
        try FileManager.default.moveItem(at: moved, to: f.data)
        try f.flush()
        try check(store.financialRevision != oldRevision, "business retry did not commit")
        try FileManager.default.removeItem(at: f.data.appendingPathComponent("library.json"))
        let preserved = try Data(contentsOf: f.shared)
        let missing = SavingsStore(widgetCurrencyCode: "CNY", snapshotTargets: { [f.shared, f.mirror] }, snapshotReloader: {})
        try check(missing.loadFailed && !missing.flushSave(), "missing established library created blank data")
        try check(!FileManager.default.fileExists(atPath: f.data.appendingPathComponent("library.json").path), "missing library overwritten")
        try check(try Data(contentsOf: f.shared) == preserved, "missing library replaced last valid snapshot")
        try Data("{broken-library".utf8).write(to: f.data.appendingPathComponent("library.json"))
        let corrupt = SavingsStore(widgetCurrencyCode: "USD", snapshotTargets: { [f.shared, f.mirror] }, snapshotReloader: {})
        corrupt.setWidgetCurrency("JPY")
        try check(corrupt.loadFailed && (try Data(contentsOf: f.shared)) == preserved, "corrupt library/currency published defaults")
        try FileManager.default.removeItem(at: f.data)
        try FileManager.default.createDirectory(at: f.data, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: f.shared)
        try FileManager.default.removeItem(at: f.mirror)
        let cache = f.shared.deletingLastPathComponent().appendingPathComponent("gaojixu-widget-last-valid.json")
        try preserved.write(to: cache)
        let cacheOnly = SavingsStore(widgetCurrencyCode: "CNY", snapshotTargets: { [f.shared, f.mirror] }, snapshotReloader: {})
        try check(cacheOnly.loadFailed && !FileManager.default.fileExists(atPath: f.data.appendingPathComponent("library.json").path), "cache-only evidence created starter data")
        try check(try Data(contentsOf: cache) == preserved, "cache-only evidence was overwritten")
        print("PASS Store persistence: failed save retains baseline/snapshot, successful retry, missing/corrupt library and cache-only history preserve data")
    }

    @MainActor static func main() throws {
        let previousTimeZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "Asia/Shanghai")!
        defer { NSTimeZone.default = previousTimeZone; unsetenv("GAOJIXU_DATA_DIR") }
        try valuesAndTime()
        try retryAndRepair()
        try persistenceProtection()
        let usd = try Fixture(currency: "USD"); defer { usd.cleanup() }
        try check(try usd.snapshot().currency == "USD" && usd.reloads == 1, "startup published an intermediate CNY snapshot")
        print("PASS Store startup: configured currency on first publication")
        usd.store.maintainWidgetSnapshot()
        let due = usd.now.addingTimeInterval(3600)
        let rule = RecurringRule(kind: .expense, amount: 7, accountID: usd.store.accounts[0].id,
                                 categoryID: "food", note: "same-day recurring unit", frequency: .daily, nextDueDate: due)
        usd.store.saveRecurringRule(rule); try usd.flush()
        usd.now = due.addingTimeInterval(60)
        usd.store.maintainWidgetSnapshot(forceRecurring: true)
        try check(usd.store.ledgerEntries.filter { $0.recurringRuleID == rule.id }.count == 1, "same-day activation missed due recurring transaction")
        usd.store.maintainWidgetSnapshot(forceRecurring: true)
        try check(usd.store.ledgerEntries.filter { $0.recurringRuleID == rule.id }.count == 1, "activation duplicated recurring transaction")
        print("PASS Store lifecycle: same-day activation keeps recurring transactions idempotent")
    }
}
