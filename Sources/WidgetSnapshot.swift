import Foundation
import Darwin

/// Versioned financial projection shared with the extension. No game state or credentials.
struct GaoJiXuWidgetSnapshot: Codable {
    static let groupID = "5G96498KGJ.com.gaojixu.savings"
    static let currentSchemaVersion = 2

    struct Day: Codable, Identifiable, Hashable {
        let date: Date
        let day: Int
        let expense: Double
        let income: Double
        let saving: Double
        var id: String { "\(day)-\(date.timeIntervalSince1970)" }
    }
    struct Account: Codable, Identifiable, Hashable {
        let id: String
        let name: String
        let balance: Double
        let symbol: String
    }
    /// Only dated amounts for the selected currency, sufficient to regroup without launching the app.
    /// Decimal retains the main ledger's arithmetic. Transfers and balance adjustments are excluded.
    struct Projection: Codable {
        struct Movement: Codable {
            let date: Date
            let expense: Decimal
            let income: Decimal
            let saving: Decimal
        }
        struct Budget: Codable {
            let monthKey: String
            let amount: Decimal
        }
        let movements: [Movement]
        let budgets: [Budget]
    }

    let schemaVersion: Int
    let revision: String
    let dataRevision: String
    let dataUpdatedAt: Date?
    let sourceSavedAt: Date?
    let writerVersion: String
    let writerBuild: String
    let timeZoneIdentifier: String
    let calendarIdentifier: String
    /// Snapshot generation time, never the timeline read time.
    let updatedAt: Date
    let monthStart: Date
    let monthTitle: String
    let currencyCode: String
    let currencySymbol: String
    let days: [Day]
    let netWorth: Double
    let accounts: [Account]
    let currency: String
    let budgetTotal: Double?
    let budgetSpent: Double?
    let projection: Projection?

    init(updatedAt: Date, monthStart: Date, monthTitle: String, currencyCode: String, currencySymbol: String,
         days: [Day], netWorth: Double, accounts: [Account], currency: String = "CNY",
         budgetTotal: Double? = nil, budgetSpent: Double? = nil,
         schemaVersion: Int = currentSchemaVersion, revision: String = UUID().uuidString,
         dataRevision: String = "", dataUpdatedAt: Date? = nil, sourceSavedAt: Date? = nil,
         writerVersion: String = "unknown", writerBuild: String = "unknown",
         timeZoneIdentifier: String = TimeZone.autoupdatingCurrent.identifier,
         calendarIdentifier: String = String(describing: Calendar.autoupdatingCurrent.identifier),
         projection: Projection? = nil) {
        self.updatedAt = updatedAt; self.monthStart = monthStart; self.monthTitle = monthTitle
        self.currencyCode = currencyCode; self.currencySymbol = currencySymbol
        self.days = days; self.netWorth = netWorth; self.accounts = accounts; self.currency = currency
        self.budgetTotal = budgetTotal; self.budgetSpent = budgetSpent
        self.schemaVersion = schemaVersion; self.revision = revision; self.dataRevision = dataRevision
        self.dataUpdatedAt = dataUpdatedAt; self.sourceSavedAt = sourceSavedAt
        self.writerVersion = writerVersion; self.writerBuild = writerBuild
        self.timeZoneIdentifier = timeZoneIdentifier; self.calendarIdentifier = calendarIdentifier
        self.projection = projection
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard (1...Self.currentSchemaVersion).contains(schemaVersion) else { throw SnapshotError.unsupportedSchema }
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        monthStart = try c.decode(Date.self, forKey: .monthStart)
        monthTitle = try c.decode(String.self, forKey: .monthTitle)
        currencyCode = try c.decode(String.self, forKey: .currencyCode)
        currencySymbol = try c.decode(String.self, forKey: .currencySymbol)
        days = try c.decode([Day].self, forKey: .days)
        netWorth = try c.decode(Double.self, forKey: .netWorth)
        accounts = try c.decode([Account].self, forKey: .accounts)
        currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? currencyCode
        budgetTotal = try c.decodeIfPresent(Double.self, forKey: .budgetTotal)
        budgetSpent = try c.decodeIfPresent(Double.self, forKey: .budgetSpent)
        dataUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .dataUpdatedAt)
        sourceSavedAt = try c.decodeIfPresent(Date.self, forKey: .sourceSavedAt)
        if schemaVersion >= 2 {
            revision = try c.decode(String.self, forKey: .revision)
            dataRevision = try c.decode(String.self, forKey: .dataRevision)
            writerVersion = try c.decode(String.self, forKey: .writerVersion)
            writerBuild = try c.decode(String.self, forKey: .writerBuild)
            timeZoneIdentifier = try c.decode(String.self, forKey: .timeZoneIdentifier)
            calendarIdentifier = try c.decode(String.self, forKey: .calendarIdentifier)
            projection = try c.decode(Projection.self, forKey: .projection)
        } else {
            revision = "legacy"; dataRevision = ""; writerVersion = "legacy"; writerBuild = "unknown"
            timeZoneIdentifier = ""; calendarIdentifier = ""; projection = nil
        }
        try validate()
    }

    enum SnapshotError: Error { case unsupportedSchema, invalidContent }

    func validate() throws {
        let dates = [updatedAt, monthStart] + [dataUpdatedAt, sourceSavedAt].compactMap { $0 } + days.map(\.date)
        guard (1...Self.currentSchemaVersion).contains(schemaVersion), dates.allSatisfy({ $0.timeIntervalSince1970.isFinite }),
              currency == currencyCode, !currency.isEmpty, !currencySymbol.isEmpty,
              netWorth.isFinite, accounts.allSatisfy({ $0.balance.isFinite }),
              Set(accounts.map(\.id)).count == accounts.count,
              (28...31).contains(days.count), Set(days.map(\.day)) == Set(1...days.count),
              days.allSatisfy({ $0.expense.isFinite && $0.income.isFinite && $0.saving.isFinite }),
              [budgetTotal, budgetSpent].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw SnapshotError.invalidContent }
        if schemaVersion >= 2 {
            guard !revision.isEmpty, !dataRevision.isEmpty,
                  TimeZone(identifier: timeZoneIdentifier) != nil, !calendarIdentifier.isEmpty,
                  let projection,
                  projection.movements.allSatisfy({ $0.date.timeIntervalSince1970.isFinite && !$0.expense.isNaN && !$0.income.isNaN && !$0.saving.isNaN }),
                  projection.budgets.allSatisfy({ !$0.amount.isNaN && $0.amount >= 0 && !$0.monthKey.isEmpty }) else { throw SnapshotError.invalidContent }
        }
    }

    /// Recompute only calendar-dependent values; all source freshness metadata remains unchanged.
    func projected(at date: Date, calendar: Calendar) -> Self {
        guard let projection, schemaVersion == Self.currentSchemaVersion,
              let start = calendar.dateInterval(of: .month, for: date)?.start,
              let range = calendar.range(of: .day, in: .month, for: start) else { return self }
        var expenses: [Int: Decimal] = [:], incomes: [Int: Decimal] = [:], savings: [Int: Decimal] = [:]
        for item in projection.movements where calendar.isDate(item.date, equalTo: start, toGranularity: .month) {
            let day = calendar.component(.day, from: item.date)
            expenses[day, default: 0] += item.expense
            incomes[day, default: 0] += item.income
            savings[day, default: 0] += item.saving
        }
        let days: [Day] = range.map { day in
            .init(date: calendar.date(byAdding: .day, value: day - 1, to: start)!, day: day,
                  expense: NSDecimalNumber(decimal: expenses[day] ?? 0).doubleValue,
                  income: NSDecimalNumber(decimal: incomes[day] ?? 0).doubleValue,
                  saving: NSDecimalNumber(decimal: savings[day] ?? 0).doubleValue)
        }
        let monthFormatter = DateFormatter(); monthFormatter.locale = Locale(identifier: "zh_CN")
        monthFormatter.calendar = calendar; monthFormatter.timeZone = calendar.timeZone; monthFormatter.dateFormat = "yyyy年M月"
        let keyFormatter = DateFormatter(); keyFormatter.locale = Locale(identifier: "en_US_POSIX")
        keyFormatter.calendar = calendar; keyFormatter.timeZone = calendar.timeZone; keyFormatter.dateFormat = "yyyy-MM"
        let key = keyFormatter.string(from: start)
        let budget = projection.budgets.filter { $0.monthKey == key }.reduce(Decimal(0)) { $0 + $1.amount }
        let total: Double? = budget > 0 ? NSDecimalNumber(decimal: budget).doubleValue : nil
        return .init(updatedAt: updatedAt, monthStart: start, monthTitle: monthFormatter.string(from: start),
                     currencyCode: currencyCode, currencySymbol: currencySymbol, days: days, netWorth: netWorth,
                     accounts: accounts, currency: currency, budgetTotal: total,
                     budgetSpent: total.map { _ in NSDecimalNumber(decimal: expenses.values.reduce(0, +)).doubleValue },
                     schemaVersion: schemaVersion, revision: revision, dataRevision: dataRevision,
                     dataUpdatedAt: dataUpdatedAt, sourceSavedAt: sourceSavedAt, writerVersion: writerVersion,
                     writerBuild: writerBuild, timeZoneIdentifier: calendar.timeZone.identifier,
                     calendarIdentifier: String(describing: calendar.identifier), projection: projection)
    }

    static var groupDirectory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }
    static var fileURL: URL? { groupDirectory?.appendingPathComponent("gaojixu-widget.json") }
    /// Main-app mirror only. A sandboxed extension must not interpret its own Application Support as this mirror.
    static var fallbackFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("GaoSeries/Savings/gaojixu-widget.json")
    }
    static var lastValidFileURL: URL? { groupDirectory?.appendingPathComponent("gaojixu-widget-last-valid.json") }
    static var diagnosticsDirectory: URL? { groupDirectory?.appendingPathComponent("WidgetDiagnostics", isDirectory: true) }
}

struct SnapshotPublishResult {
    let successfulURLs: [URL]
    let failedURLs: [URL]
    var allSucceeded: Bool { !successfulURLs.isEmpty && failedURLs.isEmpty }
}
struct SnapshotReadResult {
    let snapshot: GaoJiXuWidgetSnapshot?
    let source: String?
    let issues: [String]
    let readAt: Date
    let usedCache: Bool
}

/// This code runs in both processes and in isolated unit tests. No default finance data is synthesized.
enum SnapshotIO {
    static func publish(_ snapshot: GaoJiXuWidgetSnapshot, to urls: [URL]) -> SnapshotPublishResult {
        let targets = Array(Set(urls))
        do {
            try snapshot.validate()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            _ = try JSONDecoder().decode(GaoJiXuWidgetSnapshot.self, from: data)
            var successful: [URL] = [], failed: [URL] = []
            for url in targets {
                do {
                    if let existing = try? Data(contentsOf: url), isFutureSchema(existing) {
                        throw GaoJiXuWidgetSnapshot.SnapshotError.unsupportedSchema
                    }
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                    guard try Data(contentsOf: url) == data else { throw CocoaError(.fileReadCorruptFile) }
                    successful.append(url)
                } catch { failed.append(url) }
            }
            return .init(successfulURLs: successful, failedURLs: failed)
        } catch { return .init(successfulURLs: [], failedURLs: targets) }
    }

    static func read(candidates: [URL], cacheURL: URL?, at date: Date = Date(), updateCache: Bool = true) -> SnapshotReadResult {
        guard updateCache, let cacheURL else {
            return readUnlocked(candidates: candidates, cacheURL: cacheURL, at: date, updateCache: false)
        }
        // Several widget instances can read different source revisions concurrently. Atomic rename
        // alone is insufficient: serialize the freshness check and cache replacement across processes.
        var descriptor: Int32 = -1
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            descriptor = Darwin.open(cacheURL.appendingPathExtension("lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            if descriptor >= 0 { Darwin.close(descriptor) }
            let result = readUnlocked(candidates: candidates, cacheURL: cacheURL, at: date, updateCache: false)
            return .init(snapshot: result.snapshot, source: result.source, issues: result.issues + ["cache-lock-failed"], readAt: date, usedCache: result.usedCache)
        }
        defer { _ = flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
        return readUnlocked(candidates: candidates, cacheURL: cacheURL, at: date, updateCache: true)
    }

    private static func readUnlocked(candidates: [URL], cacheURL: URL?, at date: Date, updateCache: Bool) -> SnapshotReadResult {
        var valid: [(URL, GaoJiXuWidgetSnapshot, Data)] = [], issues: [String] = []
        for (index, url) in candidates.enumerated() {
            do {
                let data = try Data(contentsOf: url)
                valid.append((url, try JSONDecoder().decode(GaoJiXuWidgetSnapshot.self, from: data), data))
            } catch GaoJiXuWidgetSnapshot.SnapshotError.unsupportedSchema {
                issues.append("unsupported-schema-\(index)")
            } catch { issues.append("unavailable-or-invalid-\(index)") }
        }
        valid.sort { a, b in
            if a.1.updatedAt != b.1.updatedAt { return a.1.updatedAt > b.1.updatedAt }
            if a.1.schemaVersion != b.1.schemaVersion { return a.1.schemaVersion > b.1.schemaVersion }
            return a.0.path < b.0.path
        }
        if let winner = valid.first {
            if valid.dropFirst().contains(where: { $0.1.revision != winner.1.revision || $0.2 != winner.2 }) { issues.append("mirror-mismatch") }
            if let cacheURL, cacheURL != winner.0 {
                let existing = try? Data(contentsOf: cacheURL)
                // A future reader owns this cache. Never replace it with an older schema.
                let futureCache = existing.map(isFutureSchema) ?? false
                if futureCache { issues.append("unsupported-schema-cache") }
                if let existing,
                   let last = try? JSONDecoder().decode(GaoJiXuWidgetSnapshot.self, from: existing),
                   last.updatedAt > winner.1.updatedAt {
                    return .init(snapshot: last, source: "last-valid", issues: issues + ["source-older-than-cache"], readAt: date, usedCache: true)
                }
                if updateCache && !futureCache && existing != winner.2 {
                    do {
                        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try winner.2.write(to: cacheURL, options: .atomic)
                    } catch { issues.append("cache-write-failed") }
                }
            }
            return .init(snapshot: winner.1, source: candidates.firstIndex(of: winner.0).map { "candidate-\($0)" }, issues: issues, readAt: date, usedCache: false)
        }
        if let cacheURL, let data = try? Data(contentsOf: cacheURL),
           let last = try? JSONDecoder().decode(GaoJiXuWidgetSnapshot.self, from: data) {
            return .init(snapshot: last, source: "last-valid", issues: issues + ["using-last-valid"], readAt: date, usedCache: true)
        }
        return .init(snapshot: nil, source: nil, issues: issues.isEmpty ? ["container-unavailable"] : issues, readAt: date, usedCache: false)
    }

    private static func isFutureSchema(_ data: Data) -> Bool {
        struct Header: Decodable { let schemaVersion: Int? }
        return ((try? JSONDecoder().decode(Header.self, from: data).schemaVersion) ?? 1) > GaoJiXuWidgetSnapshot.currentSchemaVersion
    }

    static func nextRefresh(after date: Date, calendar: Calendar) -> Date {
        let midnight = calendar.dateInterval(of: .day, for: date)?.end ?? date.addingTimeInterval(3 * 3600)
        return min(midnight, date.addingTimeInterval(3 * 3600))
    }

    /// Local diagnostic only: no balances, names, transaction IDs, or paths are logged.
    static func recordRead(_ result: SnapshotReadResult, kind: String, family: String, at date: Date,
                           directory: URL? = GaoJiXuWidgetSnapshot.diagnosticsDirectory) {
        guard let directory else { return }
        struct Diagnostic: Encodable {
            let readAt: Date
            let snapshotGeneratedAt: Date?
            let financialDataUpdatedAt: Date?
            let sourceSavedAt: Date?
            let snapshotAgeAtReadSeconds: Double?
            let revision: String?
            let dataRevision: String?
            let schemaVersion: Int?
            let writerVersion: String?
            let writerBuild: String?
            let readerVersion: String
            let readerBuild: String
            let source: String?
            let issues: [String]
            let usedCache: Bool
            let kind: String
            let family: String
            let projectedMonthStart: Date?
            let timeZoneIdentifier: String
        }
        let value = result.snapshot
        let record = Diagnostic(readAt: date, snapshotGeneratedAt: value?.updatedAt,
            financialDataUpdatedAt: value?.dataUpdatedAt, sourceSavedAt: value?.sourceSavedAt,
            snapshotAgeAtReadSeconds: value.map { date.timeIntervalSince($0.updatedAt) },
            revision: value?.revision, dataRevision: value?.dataRevision, schemaVersion: value?.schemaVersion,
            writerVersion: value?.writerVersion, writerBuild: value?.writerBuild,
            readerVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            readerBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            source: result.source, issues: result.issues, usedCache: result.usedCache, kind: kind, family: family,
            projectedMonthStart: value?.projected(at: date, calendar: .autoupdatingCurrent).monthStart,
            timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier)
        let safeName = (kind + "-" + family).map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(record).write(to: directory.appendingPathComponent(String(safeName) + ".json"), options: .atomic)
        } catch { /* Diagnostics never replace financial data or prevent a timeline. */ }
    }
}
