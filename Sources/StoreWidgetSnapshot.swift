import Foundation
import CryptoKit
#if !SMOKE_TEST && !UNIT_TEST
import WidgetKit
#endif

extension SavingsStore {
    nonisolated static func defaultWidgetSnapshotTargets() -> [URL?] {
        if let directory = ProcessInfo.processInfo.environment["GAOJIXU_DATA_DIR"], !directory.isEmpty {
            let root = URL(fileURLWithPath: directory, isDirectory: true)
            return [root.appendingPathComponent("IsolatedWidgetGroup/gaojixu-widget.json"), root.appendingPathComponent("gaojixu-widget.json")]
        }
        return [GaoJiXuWidgetSnapshot.fileURL, GaoJiXuWidgetSnapshot.fallbackFileURL]
    }

    /// Canonical financial content excludes game progress, array ordering and widget preferences.
    func financialFingerprint() throws -> String {
        struct Content: Encodable {
            let accounts: [LedgerAccount]
            let entries: [LedgerEntry]
            let goals: [SavingsGoal]
            let records: [SavingsRecord]
            let budgets: [BudgetPlan]
            let recurring: [RecurringRule]
        }
        let content = Content(accounts: accounts.sorted { $0.id < $1.id },
                              entries: ledgerEntries.sorted { $0.id < $1.id },
                              goals: goals.sorted { $0.id < $1.id },
                              records: records.sorted { $0.id < $1.id },
                              budgets: budgets.sorted { $0.id < $1.id },
                              recurring: recurringRules.sorted { $0.id < $1.id })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(content)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func reloadFinanceWidgets() {
        #if !SMOKE_TEST && !UNIT_TEST
        WidgetCenter.shared.reloadTimelines(ofKind: "GaoJiXuMonthlyFinanceCalendar")
        WidgetCenter.shared.reloadTimelines(ofKind: "GaoJiXuNetWorth")
        #endif
    }

    func setWidgetCurrency(_ code: String) {
        guard let currency = SavingsCurrency(rawValue: code), widgetCurrencyCode != currency.rawValue else { return }
        widgetCurrencyCode = currency.rawValue
        financesDirty = true
        pendingWidgetSnapshot = nil
        // Atomic replacement keeps the last valid snapshot if the new currency cannot be published.
        refreshWidgetSnapshotIfNeeded()
    }

    /// Called on activation, wake, calendar notifications and a low-frequency maintenance timer.
    /// No reload occurs unless a new snapshot revision is actually written.
    func maintainWidgetSnapshot(forceRecurring: Bool = false) {
        guard !loadFailed else { return }
        let now = snapshotNow(), calendar = snapshotCalendar()
        let parts = calendar.dateComponents([.era, .year, .month, .day], from: now)
        let key = "\(calendar.identifier)|\(calendar.timeZone.identifier)|\(parts)"
        if forceRecurring || key != lastCalendarCheck {
            lastCalendarCheck = key
            materializeRecurringTransactions(asOf: now)
        }
        // Readback is deliberately restricted to maintenance, not every game autosave.
        if let expected = pendingWidgetSnapshot ?? lastWidgetSnapshot {
            for url in widgetSnapshotTargets().compactMap({ $0 }) {
                do {
                    let actual = try JSONDecoder().decode(GaoJiXuWidgetSnapshot.self, from: Data(contentsOf: url))
                    if actual.schemaVersion != expected.schemaVersion || actual.revision != expected.revision {
                        financesDirty = true
                    }
                } catch { financesDirty = true }
            }
        }
        refreshWidgetSnapshotIfNeeded()
    }

    /// Snapshot failure is independent of business persistence. Pending work survives until both
    /// required destinations succeed; it can retry even when no financial editing follows.
    func refreshWidgetSnapshotIfNeeded() {
        guard !loadFailed, hasLoadedValidLibrary, let financialRevision else { return }
        if saveIsDirty { _ = flushSave(); return }
        let now = snapshotNow(), calendar = snapshotCalendar()
        let prior = pendingWidgetSnapshot ?? lastWidgetSnapshot
        let contextChanged = prior.map {
            $0.currency != widgetCurrencyCode || $0.dataRevision != financialRevision ||
            $0.timeZoneIdentifier != calendar.timeZone.identifier ||
            $0.calendarIdentifier != String(describing: calendar.identifier) ||
            !calendar.isDate($0.monthStart, equalTo: now, toGranularity: .month)
        } ?? true
        let targets = widgetSnapshotTargets()
        let urls = targets.compactMap { $0 }
        let missing = urls.contains { !FileManager.default.fileExists(atPath: $0.path) }
        guard financesDirty || contextChanged || missing || targets.contains(where: { $0 == nil }) else { return }
        if pendingWidgetSnapshot == nil || contextChanged {
            pendingWidgetSnapshot = makeWidgetSnapshot(at: now, calendar: calendar)
        }
        guard let snapshot = pendingWidgetSnapshot else { return }
        let result = widgetSnapshotPublisher(snapshot, urls)
        writeWidgetPublicationDiagnostic(snapshot: snapshot, targets: targets, result: result, attemptedAt: now)
        // Notify only if the shared file was updated. A local mirror cannot make the extension fresh.
        if let sharedTarget = targets.first ?? nil,
           result.successfulURLs.contains(sharedTarget), lastWidgetReloadRevision != snapshot.revision {
            lastWidgetReloadRevision = snapshot.revision
            widgetSnapshotReloader()
        }
        if result.allSucceeded && !targets.isEmpty && !targets.contains(where: { $0 == nil }) {
            lastWidgetSnapshot = snapshot
            pendingWidgetSnapshot = nil
            financesDirty = false
            widgetSnapshotError = nil
        } else {
            financesDirty = true
            widgetSnapshotError = "小组件同步待重试；上次有效快照已保留。"
        }
    }

    private func writeWidgetPublicationDiagnostic(snapshot: GaoJiXuWidgetSnapshot, targets: [URL?], result: SnapshotPublishResult, attemptedAt: Date) {
        struct Diagnostic: Encodable {
            struct Destination: Encodable { let role: String; let status: String }
            let attemptAt: Date
            let generatedAt: Date
            let dataUpdatedAt: Date?
            let sourceSavedAt: Date?
            let revision: String
            let dataRevision: String
            let destinations: [Destination]
        }
        let destinations = targets.enumerated().map { index, url in
            Diagnostic.Destination(role: index == 0 ? "shared" : "mirror", status: url.map {
                result.successfulURLs.contains($0) ? "published" : "pending-retry"
            } ?? "container-unavailable")
        }
        let diagnostic = Diagnostic(attemptAt: attemptedAt, generatedAt: snapshot.updatedAt,
                                    dataUpdatedAt: snapshot.dataUpdatedAt, sourceSavedAt: snapshot.sourceSavedAt,
                                    revision: snapshot.revision, dataRevision: snapshot.dataRevision, destinations: destinations)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]; encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(diagnostic) else { return }
        for parent in targets.compactMap({ $0?.deletingLastPathComponent() }) {
            do {
                let directory = parent.appendingPathComponent("WidgetDiagnostics", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent("publisher.json"), options: .atomic)
                return
            } catch { continue }
        }
    }

    private func makeWidgetSnapshot(at now: Date, calendar: Calendar) -> GaoJiXuWidgetSnapshot? {
        guard let currency = SavingsCurrency(rawValue: widgetCurrencyCode), let financialRevision,
              let start = calendar.dateInterval(of: .month, for: now)?.start else { return nil }
        let accountCurrencies = Dictionary(accounts.map { ($0.id, $0.currency) }, uniquingKeysWith: { first, _ in first })
        let goalCurrencies = Dictionary(goals.map { ($0.id, $0.currency) }, uniquingKeysWith: { first, _ in first })
        var movements: [GaoJiXuWidgetSnapshot.Projection.Movement] = ledgerEntries.compactMap { entry in
            guard entry.kind != .transfer, !entry.isBalanceAdjustment, accountCurrencies[entry.accountID] == currency else { return nil }
            return .init(date: entry.date, expense: entry.kind == .expense ? entry.amountValue : 0,
                         income: entry.kind == .income ? entry.amountValue : 0, saving: 0)
        }
        // Match dailyFinanceSummary's existing financial semantics; this change does not migrate currencies.
        movements += records.compactMap { record in
            guard goalCurrencies[record.goalID] == currency else { return nil }
            return .init(date: record.date, expense: 0, income: 0,
                         saving: record.kind == .deposit ? record.amountValue : -record.amountValue)
        }
        let projection = GaoJiXuWidgetSnapshot.Projection(
            movements: movements,
            budgets: budgets.filter { $0.currency == currency }.map { .init(monthKey: $0.monthKey, amount: $0.amountValue) })
        let snapshot = GaoJiXuWidgetSnapshot(
            updatedAt: now, monthStart: start, monthTitle: "", currencyCode: currency.rawValue,
            currencySymbol: currency.symbol, days: [], netWorth: netWorth(currency: currency),
            accounts: netWorthAccounts(currency: currency).map {
                .init(id: $0.id, name: $0.name, balance: netWorthContribution(for: $0), symbol: $0.symbol)
            }, currency: currency.rawValue,
            dataRevision: financialRevision, dataUpdatedAt: financialUpdatedAt, sourceSavedAt: financialSourceSavedAt,
            writerVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            writerBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            timeZoneIdentifier: calendar.timeZone.identifier, calendarIdentifier: String(describing: calendar.identifier),
            projection: projection)
        return snapshot.projected(at: now, calendar: calendar)
    }
}
