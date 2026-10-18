import Foundation

@main struct WidgetSnapshotRegression {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("gaojixu-widget-unit-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let iso = ISO8601DateFormatter()
        func date(_ text: String) -> Date { iso.date(from: text)! }
        let changed = date("2026-10-01T02:00:00Z"), generated = date("2026-10-31T15:59:00Z")
        let source = GaoJiXuWidgetSnapshot(updatedAt: generated, monthStart: date("2026-09-30T16:00:00Z"), monthTitle: "2026年10月",
            currencyCode: "CNY", currencySymbol: "¥", days: (1...31).map { .init(date: generated, day: $0, expense: 0, income: 0, saving: 0) },
            netWorth: 830, accounts: [.init(id: "test", name: "Test", balance: 830, symbol: "banknote")],
            revision: "r1", dataRevision: "financial-1", dataUpdatedAt: changed, sourceSavedAt: generated,
            timeZoneIdentifier: calendar.timeZone.identifier,
            projection: .init(movements: [
                .init(date: date("2026-10-31T15:30:00Z"), expense: Decimal(string: "0.1")!, income: 0, saving: 0),
                .init(date: date("2026-10-31T16:30:00Z"), expense: Decimal(string: "0.2")!, income: 10, saving: -5),
                .init(date: date("2026-11-01T03:30:00Z"), expense: Decimal(string: "0.1")!, income: 0, saving: 8)
            ], budgets: [.init(monthKey: "2026-11", amount: 100)]))
        let november = source.projected(at: date("2026-10-31T16:01:00Z"), calendar: calendar)
        assert(november.days.count == 30 && november.days[0].expense == 0.3)
        assert(november.days[0].income == 10 && november.days[0].saving == 3)
        assert(november.budgetTotal == 100 && november.budgetSpent == 0.3)
        assert(november.updatedAt == generated && november.dataUpdatedAt == changed && november.revision == "r1")
        var pacific = calendar; pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let western = source.projected(at: date("2026-10-31T16:01:00Z"), calendar: pacific)
        assert(western.days.count == 31 && western.days[30].expense == 0.4 && western.budgetTotal == nil)
        assert(western.netWorth == source.netWorth && western.accounts == source.accounts)
        let group = root.appendingPathComponent("group.json"), mirror = root.appendingPathComponent("mirror.json"), cache = root.appendingPathComponent("last.json")
        assert(SnapshotIO.publish(source, to: [group, mirror]).allSucceeded)
        let original = try Data(contentsOf: group)
        let read = SnapshotIO.read(candidates: [group, mirror], cacheURL: cache, at: generated)
        assert(read.snapshot?.revision == "r1" && read.issues.isEmpty && !read.usedCache)
        var object = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        object["revision"] = "r2"; object["updatedAt"] = generated.addingTimeInterval(60).timeIntervalSinceReferenceDate
        try JSONSerialization.data(withJSONObject: object).write(to: mirror)
        let newer = SnapshotIO.read(candidates: [group, mirror], cacheURL: cache, at: generated.addingTimeInterval(90))
        assert(newer.snapshot?.revision == "r2" && newer.source == "candidate-1" && newer.issues.contains("mirror-mismatch"))
        try Data("broken".utf8).write(to: group)
        object["schemaVersion"] = 999
        try JSONSerialization.data(withJSONObject: object).write(to: mirror)
        let cached = SnapshotIO.read(candidates: [group, mirror], cacheURL: cache, at: generated)
        assert(cached.usedCache && cached.snapshot?.revision == "r2" && cached.issues.contains("unsupported-schema-1"))
        let futureBytes = try Data(contentsOf: mirror)
        assert(!SnapshotIO.publish(source, to: [mirror]).allSucceeded)
        let keptFuture = try Data(contentsOf: mirror); assert(keptFuture == futureBytes)
        try futureBytes.write(to: cache)
        assert(SnapshotIO.publish(source, to: [group]).allSucceeded)
        let futureCache = SnapshotIO.read(candidates: [group], cacheURL: cache, at: generated)
        assert(futureCache.issues.contains("unsupported-schema-cache"))
        let keptCache = try Data(contentsOf: cache); assert(keptCache == futureBytes)
        object["schemaVersion"] = 2
        try JSONSerialization.data(withJSONObject: object).write(to: cache)
        try Data("broken".utf8).write(to: group)
        let absent = SnapshotIO.read(candidates: [group, mirror], cacheURL: nil, at: generated)
        assert(absent.snapshot == nil && !absent.issues.isEmpty)
        // Successful targets publish even if the other destination is unwritable; pending state is not success.
        let obstacle = root.appendingPathComponent("not-directory"); try Data("keep".utf8).write(to: obstacle)
        let result = SnapshotIO.publish(source, to: [group, obstacle.appendingPathComponent("snapshot.json")])
        assert(!result.allSucceeded && result.successfulURLs == [group] && result.failedURLs.count == 1)
        let kept = try Data(contentsOf: obstacle); assert(kept == Data("keep".utf8))
        // A stale source must not overwrite a newer, validated cache.
        let oldSource = SnapshotIO.read(candidates: [group], cacheURL: cache, at: generated, updateCache: false)
        assert(oldSource.usedCache && oldSource.snapshot?.revision == "r2")
        DispatchQueue.concurrentPerform(iterations: 24) { _ in
            _ = SnapshotIO.read(candidates: [group], cacheURL: cache, at: generated)
        }
        let afterConcurrentReads = SnapshotIO.read(candidates: [], cacheURL: cache, at: generated)
        assert(afterConcurrentReads.snapshot?.revision == "r2")
        object = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        for key in ["schemaVersion", "revision", "dataRevision", "dataUpdatedAt", "sourceSavedAt", "projection", "writerVersion", "writerBuild", "timeZoneIdentifier", "calendarIdentifier"] { object.removeValue(forKey: key) }
        let legacy = try JSONDecoder().decode(GaoJiXuWidgetSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        assert(legacy.schemaVersion == 1 && legacy.dataUpdatedAt == nil && legacy.projection == nil)
        assert(legacy.projected(at: date("2026-11-01T10:00:00Z"), calendar: calendar).monthStart == legacy.monthStart)
        assert(SnapshotIO.nextRefresh(after: generated, calendar: calendar) == date("2026-10-31T16:00:00Z"))
        let dst = date("2026-11-01T08:30:00Z")
        assert(SnapshotIO.nextRefresh(after: dst, calendar: pacific) > dst)
        SnapshotIO.recordRead(newer, kind: "test", family: "small", at: generated.addingTimeInterval(90), directory: root.appendingPathComponent("diagnostics"))
        let diagnostic = try String(contentsOf: root.appendingPathComponent("diagnostics/test-small.json"), encoding: .utf8)
        assert(!diagnostic.contains("balance") && diagnostic.contains("snapshotGeneratedAt") && diagnostic.contains("readAt"))
        print("PASS WidgetSnapshot: exact Decimal values, offline month/timezone projection, immutable financial timestamps, freshest mirror, legacy/future/corrupt files, last-valid cache, partial atomic publication, midnight/DST scheduling, private diagnostics")
    }
}
