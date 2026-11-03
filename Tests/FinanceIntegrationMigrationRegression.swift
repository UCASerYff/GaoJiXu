import CryptoKit
import Foundation

/// Real, temporary SQLite and JSON fixtures; no host/WidgetKit, live data or discovery. Run as a separate @main.
@main private struct FinanceIntegrationMigrationRegression {
  typealias Migration = FinanceIntegrationMigration
  struct TestError: Error {
    let text: String
    init(_ text: String) { self.text = text }
  }
  static func check(_ value: Bool, _ why: String) throws { if !value { throw TestError(why) } }
  static func rejects(_ why: String, _ block: () throws -> Void) throws {
    do { try block() } catch { return }
    throw TestError("accepted: " + why)
  }
  struct SimulatedInterruption: Error {}
  static func interrupt(_ request: Migration.Request, at expected: String) throws {
    do {
      _ = try Migration.run(request) { reached in
        if reached == expected { throw SimulatedInterruption() }
      }
    } catch is SimulatedInterruption { return }
    throw TestError("did not reach the requested interruption: " + expected)
  }
  static func sha(_ b: Data) -> String {
    SHA256.hash(data: b).map { String(format: "%02x", $0) }.joined()
  }
  static func main() throws {
    let fm = FileManager.default
    // Foundation may spell the user's temporary directory /var/..., an intentional symlink rejected by production.
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(
      "gaojixu-txn-test-" + UUID().uuidString + ".noindex")
    try fm.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: root) }
    let source = root.appendingPathComponent("frozen")
    try fm.createDirectory(at: source, withIntermediateDirectories: false)
    let monthly = source.appendingPathComponent("monthly.sqlite")
    let pack = source.appendingPathComponent("research.json")
    var sub = MonthlyFinanceSubscription()
    sub.name = "Synthetic subscription"
    sub.plans[0].price = 12
    let state = MonthlyFinanceState(subscriptions: [sub])
    var legacy =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
    var prefs = legacy["preferences"] as! [String: Any]
    prefs["game"] = true
    legacy["preferences"] = prefs
    legacy["pet"] = ["privateTestCat": "ARCHIVE-ONLY-CAT"]
    legacy["rewards"] = [["id": "unit-historical", "date": 10, "kind": "claim", "amount": 1200]]
    let payload = try JSONSerialization.data(withJSONObject: legacy, options: .sortedKeys)
    try Data().write(to: monthly)
    do {
      let c = try MonthlyFinanceConnection(existing: monthly, readOnly: false)
      try c.exec("CREATE TABLE state(id INTEGER PRIMARY KEY CHECK(id=1),json BLOB NOT NULL)")
      try c.updatePayload(payload, initial: true)
    }
    let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
      "Fixtures/ResearchFunding/research-funding-v1.json")
    var research = try JSONSerialization.jsonObject(with: Data(contentsOf: base)) as! [String: Any]
    let active = (research["fundingRecords"] as! [[String: Any]])[0]["id"] as! String
    let rev = research["sourceRevision"] as! String
    let attachment = Data("synthetic private attachment".utf8)
    let assets = source.appendingPathComponent("proofs")
    try fm.createDirectory(at: assets, withIntermediateDirectories: false)
    let at = assets.appendingPathComponent("unit.txt")
    try attachment.write(to: at)
    research["attachments"] = [
      [
        "id": "unit-asset", "fundingID": active, "relativePath": "proofs/unit.txt",
        "byteCount": attachment.count, "sha256": sha(attachment),
      ]
    ]
    let bundle = try JSONSerialization.data(withJSONObject: research, options: .sortedKeys)
    try bundle.write(to: pack)
    let sqliteHash = sha(try Data(contentsOf: monthly))
    let inp = Migration.MonthlyInput(
      snapshotPath: monthly.path, artifactSHA256: sqliteHash, sourceRevision: sha(payload))
    let rin = Migration.ResearchInput(
      packagePath: pack.path, artifactSHA256: sha(bundle), sourceRevision: rev)
    func request(
      _ label: String, _ tx: String = UUID().uuidString, _ research: Migration.ResearchInput? = nil,
      frozen: Bool = true
    ) -> Migration.Request {
      let dir = root.appendingPathComponent(label)
      return .init(
        schemaVersion: 1, txnID: tx, writersFrozen: frozen, targetWritersStopped: true,
        monthly: inp, research: research ?? rin,
        targetMonthlyDirectory: dir.appendingPathComponent("group/Monthly").path,
        targetResearchDirectory: dir.appendingPathComponent("support/Funding").path,
        journalDirectory: dir.appendingPathComponent("private/journal").path,
        commitMarkerPath: dir.appendingPathComponent("group/Migrations/" + tx + "/committed.json")
          .path)
    }
    let r = request("cutover")
    let m = URL(fileURLWithPath: r.targetMonthlyDirectory)
    let f = URL(fileURLWithPath: r.targetResearchDirectory)
    let marker = URL(fileURLWithPath: r.commitMarkerPath)
    let journal = URL(fileURLWithPath: r.journalDirectory)
    // Path gate only; these assertions never open or create a real production directory.
    let liveMonthly = FinanceAuthority.productionGroup.appendingPathComponent(
      "IntegratedFinance/Monthly")
    let liveResearch = FinanceAuthority.productionResearchDirectory
    let canonicalMarker = FinanceAuthority.productionGroup.appendingPathComponent(
      "IntegratedFinance/Migrations/" + r.txnID + "/committed.json")
    try FinanceAuthority.validateMarkerPlacement(
      canonicalMarker, transactionID: r.txnID, targets: [liveMonthly, liveResearch])
    try check(
      FinanceAuthority.markerReference(for: canonicalMarker)
        == "app-group:IntegratedFinance/Migrations/" + r.txnID + "/committed.json",
      "portable production marker")
    try FinanceAuthority.validateProductionReference(
      FinanceAuthority.markerReference(for: canonicalMarker), transactionID: r.txnID)
    for invalid in [
      marker.path, canonicalMarker.path,
      "app-group:IntegratedFinance/Migrations/" + UUID().uuidString + "/committed.json",
    ] {
      try rejects("runtime production marker gate") {
        try FinanceAuthority.validateProductionReference(invalid, transactionID: r.txnID)
      }
    }
    let counterfeit = root.appendingPathComponent(
      "5G96498KGJ.com.gaojixu.savings/IntegratedFinance/Migrations/" + r.txnID + "/committed.json")
    for realTarget in [liveMonthly, liveResearch] {
      for wrong in [
        marker, counterfeit,
        canonicalMarker.deletingLastPathComponent().appendingPathComponent("other.json"),
      ] {
        try rejects(
          "production marker must be in the actual app group with the canonical UUID path"
        ) {
          try FinanceAuthority.validateMarkerPlacement(
            wrong, transactionID: r.txnID, targets: [realTarget])
        }
      }
    }
    try check(
      FinanceAuthority.markerReference(for: counterfeit) == counterfeit.path,
      "lookalike group must remain isolated")
    try FinanceAuthority.validateMarkerPlacement(
      marker, transactionID: "local-fixture", targets: [m, f])
    try rejects("writers not frozen") { _ = try Migration.run(request("nofreeze", frozen: false)) }
    try rejects("invalid module B (no target A may appear)") {
      _ = try Migration.run(
        request(
          "bad", UUID().uuidString,
          .init(
            packagePath: pack.path, artifactSHA256: sha(bundle),
            sourceRevision: String(repeating: "0", count: 64))))
    }
    try check(
      !fm.fileExists(atPath: root.appendingPathComponent("bad/group/Monthly").path),
      "first module published before second staged")
    let abandonedRequest = request("recover-stage")
    try interrupt(abandonedRequest, at: "stage-built:monthly")
    let abandonedParent = URL(fileURLWithPath: abandonedRequest.targetMonthlyDirectory)
      .deletingLastPathComponent()
    let abandonedCandidates = try fm.contentsOfDirectory(
      at: abandonedParent, includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "noindex" }
    try check(abandonedCandidates.count == 1, "expected registered full stage")
    let oldStage = abandonedCandidates[0]
    let stagedBytes = try Data(contentsOf: oldStage.appendingPathComponent("monthly.sqlite"))
    let held = root.appendingPathComponent("held-original-stage.noindex")
    try fm.moveItem(at: oldStage, to: held)
    try fm.createDirectory(at: oldStage, withIntermediateDirectories: false)
    let unrelated = oldStage.appendingPathComponent("unrelated.txt")
    let userBytes = Data("not owned by interrupted transaction".utf8)
    try userBytes.write(to: unrelated)
    try rejects("replaced abandoned stage identity") { _ = try Migration.run(abandonedRequest) }
    try check(
      try Data(contentsOf: unrelated) == userBytes,
      "foreign content at abandoned path was moved or removed")
    try fm.removeItem(at: oldStage)
    try fm.moveItem(at: held, to: oldStage)
    let recovered = try Migration.run(abandonedRequest)
    let quarantine = URL(fileURLWithPath: abandonedRequest.journalDirectory).appendingPathComponent(
      "interrupted-stages/" + oldStage.lastPathComponent)
    try check(
      !recovered.alreadyCommitted && !fm.fileExists(atPath: oldStage.path)
        && (try Data(contentsOf: quarantine.appendingPathComponent("monthly.sqlite")))
          == stagedBytes,
      "registered interrupted data must not be left beside production or discarded")
    try interrupt(r, at: "promoted:monthly")
    try check(
      fm.fileExists(atPath: m.appendingPathComponent("monthly.sqlite").path)
        && !fm.fileExists(atPath: marker.path) && !fm.fileExists(atPath: f.path),
      "wrong partial state")
    try rejects("partial directory accidentally writable") {
      _ = try FinanceAuthority.require(module: "monthly", directory: m)
    }
    try interrupt(r, at: "marker-published")
    try check(fm.fileExists(atPath: marker.path), "global marker missing")
    _ = try FinanceAuthority.require(module: "monthly", directory: m)
    _ = try FinanceAuthority.require(module: "research-funding", directory: f)
    let conn = try MonthlyFinanceDatabase(directory: m, readOnly: false)
    let initial = try conn.read()
    try check(
      initial.subscriptions.map(\.id) == [sub.id] && initial.legacyRewardIDs == ["unit-historical"]
        && initial.payments.isEmpty, "origin IDs/reward tombstones changed")
    let raw = try MonthlyFinanceConnection(
      existing: m.appendingPathComponent("monthly.sqlite"), readOnly: true
    ).payload()
    let strip = String(decoding: raw, as: UTF8.self)
    try check(
      !strip.contains("ARCHIVE-ONLY-CAT") && !strip.contains("\"pet\""),
      "cat game leaked to production")
    let archive = journal.appendingPathComponent("sources/monthly/snapshot.sqlite")
    try check(
      sha(Data(contentsOf: archive)) == sqliteHash, "cat-containing source archive not identical")
    try check(
      try Data(
        contentsOf: journal.appendingPathComponent("sources/research-funding/proofs/unit.txt"))
        == attachment
        && Data(contentsOf: f.appendingPathComponent("Attachments/proofs/unit.txt")) == attachment,
      "attachment copies mismatch")
    try conn.transaction { $0.subscriptions[0].name = "User change after cutover" }
    let currentFile = f.appendingPathComponent("library.json")
    var changed = try JSONDecoder().decode(
      ResearchFundingLibrary.self, from: Data(contentsOf: currentFile))
    changed.fundingRecords[0].name = "Updated after migration"
    try ResearchFundingFiles.encode(changed).write(to: currentFile, options: .atomic)
    let updated = try Data(contentsOf: currentFile)
    let resume = try Migration.run(r)
    try check(
      resume.alreadyCommitted && resume.counts["research-funding"]?["attachments"] == 1,
      "did not finalize interrupted commit")
    try check(
      try conn.read().subscriptions.first?.name == "User change after cutover"
        && Data(contentsOf: currentFile) == updated, "rerun overwrote new user data")
    try check(try Migration.run(r).alreadyCommitted, "same transaction not idempotent")
    let beforeJournal = try Data(contentsOf: journal.appendingPathComponent("journal.json"))
    let j = try JSONSerialization.jsonObject(with: beforeJournal) as! [String: Any]
    let mods = j["prepared"] as! [String: [String: Any]]
    try check(
      j["phase"] as? String == "committed"
        && (mods["monthly"]?["idMap"] as? [String: String])?.values.contains(sub.id.uuidString)
          == true
        && (mods["research-funding"]?["idMap"] as? [String: String])?.values.contains("unit-asset")
          == true,
      "missing journal/source mapping")
    try rejects("conflicting transaction with same private root") {
      _ = try Migration.run(request("cutover"))
    }
    let savedMarker = try Data(contentsOf: marker)
    var incomplete = try JSONDecoder().decode(FinanceCommitMarker.self, from: savedMarker)
    incomplete.modules = ["monthly"]
    try JSONEncoder().encode(incomplete).write(to: marker, options: .atomic)
    try rejects("degraded joint marker cannot unlock surviving monthly member") {
      _ = try FinanceAuthority.require(module: "monthly", directory: m)
    }
    try rejects("degraded joint marker cannot unlock research") {
      _ = try FinanceAuthority.require(module: "research-funding", directory: f)
    }
    try savedMarker.write(to: marker, options: .atomic)
    let unknownField = Data(
      ("{\"unknownFutureFinancialField\":47," + String(decoding: updated.dropFirst(), as: UTF8.self))
        .utf8)
    let duplicateField = Data(
      ("{\"schemaVersion\":1," + String(decoding: updated.dropFirst(), as: UTF8.self)).utf8)
    for unknown in [unknownField, duplicateField] {
      try unknown.write(to: currentFile, options: .atomic)
      try rejects("reentry must use the same strict research readback as the host") {
        _ = try Migration.run(r)
      }
      try check(try Data(contentsOf: currentFile) == unknown, "invalid target was overwritten")
    }
    try updated.write(to: currentFile, options: .atomic)
    try Data("{bad".utf8).write(to: marker)
    try rejects("broken commit marker") { _ = try Migration.run(r) }
    try savedMarker.write(to: marker)
    try fm.removeItem(at: marker)
    try rejects("lost committed marker must not be recreated") { _ = try Migration.run(r) }
    try check(!fm.fileExists(atPath: marker.path), "missing marker recreated")
    try savedMarker.write(to: marker)
    let unknown = request("occupied")
    let u = URL(fileURLWithPath: unknown.targetResearchDirectory)
    try fm.createDirectory(at: u, withIntermediateDirectories: true)
    let user = u.appendingPathComponent("existing")
    try Data("private".utf8).write(to: user)
    try rejects("unknown preexisting target") { _ = try Migration.run(unknown) }
    try check(
      try Data(contentsOf: user) == Data("private".utf8), "existing user contents overwritten")
    try Data("other".utf8).write(to: at)
    try rejects("new transaction with replaced input attachment despite unchanged package JSON") {
      _ = try Migration.run(request("changed-attachment"))
    }
    try attachment.write(to: at)
    try fm.moveItem(at: source, to: root.appendingPathComponent("retired-source"))
    let archivedResume = try Migration.run(r)
    try check(
      archivedResume.alreadyCommitted
        && archivedResume.verifiedArtifactSHA256["research-funding"] == sha(bundle),
      "safe resume should use frozen archive after source retirement")
    try fm.removeItem(at: archive)
    try rejects("missing archived source after commit") { _ = try Migration.run(r) }
    try check(!fm.fileExists(atPath: archive.path), "missing archive silently regenerated")
    print(
      "PASS finance transaction: isolated full staging, detached source archives, attachments and IDs, partial-promotion lockout, marker recovery, no replay or overwrite, conflict and missing-data protection"
    )
  }
}
