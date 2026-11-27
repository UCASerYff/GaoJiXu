import Darwin
import Foundation

func tS(_ zh: String, _ en: String) -> String { zh }

@main private struct CSVReviewRegression {
    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    static func check(_ condition: Bool, _ reason: String) throws {
        if !condition { throw Failure(reason: reason) }
    }

    static func reject(_ reason: String, _ action: () throws -> Void) throws {
        do { try action() } catch { return }
        throw Failure(reason: reason)
    }

    static let header = "日期,类型,账户,目标账户,分类,备注,金额,币种,转入金额,转入币种"
    static let dateText = "2026-11-20T08:21:00+08:00"
    static let date = ISO8601DateFormatter().date(from: "2026-11-20T00:21:00Z")!

    @MainActor final class Fixture {
        let root: URL
        let library: URL
        let previousDataDirectory: String?

        init() throws {
            previousDataDirectory = ProcessInfo.processInfo.environment["GAOJIXU_DATA_DIR"]
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gaojixu-csv-review-" + UUID().uuidString)
            root = directory
            library = directory.appendingPathComponent("library.json")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            setenv("GAOJIXU_DATA_DIR", directory.path, 1)
        }

        func open(timeZone: String = "Asia/Shanghai") -> SavingsStore {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: timeZone)!
            let store = SavingsStore(widgetCurrencyCode: "CNY",
                                     now: { CSVReviewRegression.date.addingTimeInterval(86_400) }, calendar: { calendar },
                                     snapshotTargets: { [self.root.appendingPathComponent("shared/snapshot.json"),
                                                         self.root.appendingPathComponent("mirror/snapshot.json")] },
                                     snapshotReloader: {})
            store.saveDebounceInterval = 0
            return store
        }

        func cleanup() {
            if let previousDataDirectory { setenv("GAOJIXU_DATA_DIR", previousDataDirectory, 1) }
            else { unsetenv("GAOJIXU_DATA_DIR") }
            try? FileManager.default.removeItem(at: root)
        }
    }

    static func row(_ note: String, in detail: CSVReviewDetail) throws -> CSVReviewRowAssessment {
        guard let result = detail.rows.first(where: { $0.row.fields.note == note }) else {
            throw Failure(reason: "missing row: \(note)")
        }
        return result
    }

    @MainActor static func reviewAndUndo() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let setup = fixture.open()
        guard let cash = setup.activeAccounts.first(where: { $0.name == "现金" }),
              let bank = setup.activeAccounts.first(where: { $0.name == "银行卡" }) else {
            throw Failure(reason: "starter accounts must exist")
        }
        setup.saveAccount(existingID: nil, name: "美元测试", type: .bank, currency: .USD,
                          balance: 0, includeInNetWorth: true, colorKey: "blue")
        guard let usd = setup.activeAccounts.first(where: { $0.name == "美元测试" }) else {
            throw Failure(reason: "fixture USD account missing")
        }
        setup.saveLedgerEntry(existingID: nil, kind: .expense, accountID: cash.id, targetAccountID: nil,
                              amount: 28.45, targetAmount: nil, categoryID: "food", date: date, note: "合成重复")
        let previousEntries = setup.ledgerEntries
        let previousAccounts = setup.accounts
        let financialRevision = setup.financialRevision
        let csv = [
            header,
            "\(dateText),支出,现金,,餐饮,合成重复,28.45,CNY,,",
            "\(dateText),支出,现金,,转账,转账 银行卡,56.78,CNY,,",
            "\(dateText),收入,银行卡,,转账,转账 现金,56.78,CNY,,",
            "\(dateText),转账,现金,美元测试,,合成换汇,41.23,CNY,,USD",
            "\(dateText),支出,现金,,餐饮,缺少金额,,CNY,,"
        ].joined(separator: "\n")
        let initial = try setup.stageCSVReview(text: "\u{FEFF}" + csv, name: "fixture.csv")
        try check(initial.rows.count == 5 && initial.rows.allSatisfy { $0.row.status == .pending }, "stage must keep rows pending")
        try check(setup.ledgerEntries == previousEntries && setup.accounts == previousAccounts, "stage mutated the ledger or accounts")
        try check(setup.financialRevision == financialRevision, "stage advanced the financial revision")

        let store = fixture.open()
        let staged = try store.csvReviewDetail(initial.batch.id)
        try check(store.csvReviewBatches.count == 1 && staged.rows.count == 5, "batch did not survive restart")
        let duplicate = try row("合成重复", in: staged)
        let fx = try row("合成换汇", in: staged)
        let missing = try row("缺少金额", in: staged)
        try check(!duplicate.duplicates.isEmpty && duplicate.row.date == date, "duplicate explanation or explicit offset lost")
        try check(!fx.canApply && !missing.canApply, "incomplete rows can be posted")
        guard staged.pairs.count == 1, let pair = staged.pairs.first else { throw Failure(reason: "unique pair missing") }
        try check(pair.sourceName == cash.name && pair.targetName == bank.name && pair.amount == Decimal(5678) / 100,
                  "wrong match direction or amount")

        try reject("unconfirmed review wrote entries") {
            _ = try store.applyCSVReview(batchID: staged.batch.id, revision: staged.revision,
                                         decisions: [duplicate.id: .apply], overrideDuplicates: [duplicate.id], confirmed: false)
        }
        try reject("suspected duplicate accepted without override") {
            _ = try store.applyCSVReview(batchID: staged.batch.id, revision: staged.revision,
                                         decisions: [duplicate.id: .apply], confirmed: true)
        }
        try reject("cross-currency row posted without received amount") {
            _ = try store.applyCSVReview(batchID: staged.batch.id, revision: staged.revision,
                                         decisions: [fx.id: .apply], confirmed: true)
        }
        try check(store.ledgerEntries == previousEntries, "rejected review partially wrote entries")

        var repaired = fx.row.fields
        repaired.targetAmount = "6.07"
        let decisions: [String: CSVReviewDecision] = [duplicate.id: .apply, fx.id: .apply, missing.id: .skip]
        let reviewed = try store.applyCSVReview(batchID: staged.batch.id, revision: staged.revision,
                                                decisions: decisions, edits: [fx.id: repaired], pairs: [pair.id],
                                                overrideDuplicates: [duplicate.id], confirmed: true)
        try check(reviewed.rows.filter { $0.row.status == .applied }.count == 4, "manual rows or pair were not recorded")
        try check(store.ledgerEntries.count == 4, "two transfer legs must produce one ledger entry")
        try check(store.ledgerEntries.contains { $0.kind == .transfer && $0.targetAccountID == bank.id &&
            $0.amountValue == Decimal(5678) / 100 && $0.targetAmountValue == Decimal(5678) / 100 }, "same-currency leg values are wrong")
        try check(store.ledgerEntries.contains { $0.kind == .transfer && $0.targetAccountID == usd.id &&
            $0.amountValue == Decimal(4123) / 100 && $0.targetAmountValue == Decimal(607) / 100 }, "exact FX leg values are wrong")

        let again = fixture.open()
        let afterApply = again.ledgerEntries
        _ = try again.applyCSVReview(batchID: staged.batch.id, revision: staged.revision, decisions: decisions,
                                     edits: [fx.id: repaired], pairs: [pair.id], overrideDuplicates: [duplicate.id], confirmed: true)
        let repeated = try again.stageCSVReview(text: csv.replacingOccurrences(of: "\n", with: "\r\n"), name: "renamed.csv")
        try check(repeated.batch.id == initial.batch.id && again.csvReviewBatches.count == 1 && again.ledgerEntries == afterApply,
                  "replay or renamed identical batch duplicated the entry")
        let undone = try again.undoCSVReview(batchID: repeated.batch.id, revision: repeated.revision, confirmed: true)
        try check(undone.rows.filter { $0.row.status == .undone }.count == 4 && again.ledgerEntries == previousEntries,
                  "undo changed an existing ledger entry")
        _ = try again.undoCSVReview(batchID: repeated.batch.id, revision: repeated.revision, confirmed: true)
        let afterUndo = fixture.open()
        try check(afterUndo.ledgerEntries == previousEntries && afterUndo.accounts == previousAccounts, "undo did not persist cleanly")
        print("PASS CSV stage, restart, consent, duplicate override, pair, FX precision, retry, undo")
    }

    @MainActor static func conflictsAndFailure() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.open()
        let csv = [
            header,
            "\(dateText),支出,现金,,餐饮,合成普通支出,7.89,CNY,,",
            "\(dateText),收入,银行卡,,其他收入,合成普通收入,7.89,CNY,,",
            "\(dateText),支出,现金,,餐饮,超出精度,1.001,CNY,,"
        ].joined(separator: "\n")
        let staged = try store.stageCSVReview(text: csv, name: "ordinary.csv")
        try check(staged.pairs.isEmpty, "matched unrelated income and expense without transfer evidence")
        let imprecise = try row("超出精度", in: staged)
        try check(!imprecise.canApply, "would round away explicit sub-cent precision")
        let selected = try row("合成普通支出", in: staged)
        let pending = try row("合成普通收入", in: staged)
        let reviewed = try store.applyCSVReview(batchID: staged.batch.id, revision: staged.revision,
                                                decisions: [selected.id: .apply], confirmed: true)
        guard let entry = store.ledgerEntries.first else { throw Failure(reason: "fixture entry missing") }
        store.saveLedgerEntry(existingID: entry.id, kind: entry.kind, accountID: entry.accountID,
                              targetAccountID: nil, amount: entry.amount, targetAmount: nil,
                              categoryID: entry.categoryID, date: entry.date, note: "修改后不应撤销")
        let refreshed = try store.csvReviewDetail(reviewed.batch.id)
        let before = try Data(contentsOf: fixture.library)
        try reject("a stale edit changed the remaining row") {
            _ = try store.applyCSVReview(batchID: reviewed.batch.id, revision: reviewed.revision,
                                         decisions: [pending.id: .skip], confirmed: true)
        }
        try reject("undo removed an edited ledger row") {
            _ = try store.undoCSVReview(batchID: reviewed.batch.id, revision: refreshed.revision, confirmed: true)
        }
        try check(try Data(contentsOf: fixture.library) == before, "conflicting undo wrote to disk")

        let blocked = fixture.root.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blocked)
        setenv("GAOJIXU_DATA_DIR", blocked.path, 1)
        defer { setenv("GAOJIXU_DATA_DIR", fixture.root.path, 1) }
        try reject("write failure acknowledged a batch") {
            _ = try store.stageCSVReview(text: csv.replacingOccurrences(of: "7.89", with: "8.90"), name: "failed.csv")
        }
        try check(store.csvReviewBatches.map(\.id) == [staged.batch.id] && store.ledgerEntries.count == 1,
                  "failed stage left phantom state")
        setenv("GAOJIXU_DATA_DIR", fixture.root.path, 1)
        try check(try Data(contentsOf: fixture.library) == before, "isolated failure changed original fixture")
        print("PASS CSV unrelated payments, guarded undo, write failure rollback")
    }

    @MainActor static func protectedLibrary() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = Data("{broken-synthetic-library".utf8)
        try original.write(to: fixture.library)
        let store = fixture.open()
        try check(store.loadFailed, "corrupt library must be read-only")
        try reject("stage replaced an unreadable library") {
            _ = try store.stageCSVReview(text: header + "\n\(dateText),支出,现金,,餐饮,Protected,1.00,CNY,,", name: "blocked.csv")
        }
        try check(try Data(contentsOf: fixture.library) == original, "unreadable bytes were overwritten")
        print("PASS CSV protected library preserved")
    }

    @MainActor static func localTime() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.open(timeZone: "America/Los_Angeles")
        let csv = [
            header,
            "2026-11-01 01:30,支出,现金,,餐饮,无偏移的重复时刻,5.00,CNY,,",
            "2026-11-01T01:30:00-07:00,支出,现金,,餐饮,偏移七小时,5.01,CNY,,",
            "2026-11-01T01:30:00-08:00,支出,现金,,餐饮,偏移八小时,5.02,CNY,,",
            "2026-11-02 01:30,支出,现金,,餐饮,无歧义本地时间,5.03,CNY,,"
        ].joined(separator: "\n")
        let detail = try store.stageCSVReview(text: csv, name: "local-time.csv")
        let ambiguous = try row("无偏移的重复时刻", in: detail)
        let first = try row("偏移七小时", in: detail)
        let second = try row("偏移八小时", in: detail)
        let local = try row("无歧义本地时间", in: detail)
        try check(!ambiguous.canApply && ambiguous.row.ambiguousTime, "ambiguous wall-clock time was guessed")
        let distance = first.row.date.flatMap { earlier in second.row.date.map { $0.timeIntervalSince(earlier) } }
        try check(first.canApply && second.canApply && distance == 3600,
                  "explicit offsets did not preserve both instants")
        try check(local.canApply && local.row.timeZoneIdentifier == "America/Los_Angeles", "local-time origin was discarded")
        let ambiguousPairs = [
            header,
            "\(dateText),支出,现金,,转账,转账甲,9.87,CNY,,",
            "\(dateText),收入,银行卡,,转账,转账入,9.87,CNY,,",
            "\(dateText),支出,现金,,转账,转账乙,9.87,CNY,,"
        ].joined(separator: "\n")
        let multiple = try store.stageCSVReview(text: ambiguousPairs, name: "ambiguous-pairs.csv")
        try check(multiple.pairs.isEmpty, "ambiguous transfer group chose arbitrary rows")
        print("PASS CSV ambiguous transfer group and time, explicit offsets")
    }

    @MainActor static func crossPlatformMetadata() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = fixture.open()
        let initial = try Data(contentsOf: fixture.library)
        var library = try JSONSerialization.jsonObject(with: initial) as! [String: Any]
        let windows: [String: Any] = ["version": 1, "batches": ["windows-fixture": [
            "rows": [["status": "pending", "note": "保留 Windows 原生批次"]],
            "enabled": true, "receipt": NSNull()
        ]]]
        library["windowsCSVReview"] = windows
        try JSONSerialization.data(withJSONObject: library).write(to: fixture.library, options: .atomic)
        let store = fixture.open()
        try check(!store.loadFailed && store.csvReviewBatches.isEmpty, "mixed platform state was treated as a Mac batch")
        _ = try store.stageCSVReview(text: header + "\n\(dateText),支出,现金,,餐饮,Mac fixture,1.00,CNY,,", name: "mac.csv")
        var written = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.library)) as! [String: Any]
        let foreign = written["windowsCSVReview"] as? [String: Any] ?? [:]
        let expectedForeign = try JSONSerialization.data(withJSONObject: windows, options: .sortedKeys)
        try check(try JSONSerialization.data(withJSONObject: foreign, options: .sortedKeys) == expectedForeign,
                  "Mac stage rewrote Windows review data")
        written["macCSVReview"] = ["version": 999, "batches": []]
        let future = try JSONSerialization.data(withJSONObject: written, options: .sortedKeys)
        try future.write(to: fixture.library, options: .atomic)
        let protected = fixture.open()
        try check(protected.loadFailed && !protected.flushSave(), "future review metadata version was not protected")
        try check(try Data(contentsOf: fixture.library) == future, "opening a future review archive modified existing data")
        print("PASS CSV cross-platform metadata and future native review protection")
    }

    @MainActor static func main() throws {
        try reviewAndUndo()
        try conflictsAndFailure()
        try protectedLibrary()
        try localTime()
        try crossPlatformMetadata()
    }
}
