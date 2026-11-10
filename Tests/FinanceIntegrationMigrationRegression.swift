import CryptoKit
import Foundation

/// Real, temporary SQLite fixtures; no host/WidgetKit, live data or discovery. Run as a separate @main.
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
    let sqliteBytes = try Data(contentsOf: monthly)
    let sqliteHash = sha(sqliteBytes)
    let inp = Migration.MonthlyInput(
      snapshotPath: monthly.path, artifactSHA256: sqliteHash, sourceRevision: sha(payload))
    func request(
      _ label: String, _ tx: String = UUID().uuidString, frozen: Bool = true,
      input: Migration.MonthlyInput? = nil
    ) -> Migration.Request {
      let dir = root.appendingPathComponent(label)
      return .init(
        schemaVersion: 1, txnID: tx, writersFrozen: frozen, targetWritersStopped: true,
        monthly: input ?? inp,
        targetMonthlyDirectory: dir.appendingPathComponent("group/Monthly").path,
        journalDirectory: dir.appendingPathComponent("private/journal").path,
        commitMarkerPath: dir.appendingPathComponent("group/Migrations/" + tx + "/committed.json")
          .path)
    }
    let r = request("cutover")
    let m = URL(fileURLWithPath: r.targetMonthlyDirectory)
    let marker = URL(fileURLWithPath: r.commitMarkerPath)
    let journal = URL(fileURLWithPath: r.journalDirectory)
    // Path gate only; these assertions never open or create a real production directory.
    let liveMonthly = FinanceAuthority.productionGroup.appendingPathComponent(
      "IntegratedFinance/Monthly")
    let canonicalMarker = FinanceAuthority.productionGroup.appendingPathComponent(
      "IntegratedFinance/Migrations/" + r.txnID + "/committed.json")
    try FinanceAuthority.validateMarkerPlacement(
      canonicalMarker, transactionID: r.txnID, targets: [liveMonthly])
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
    for wrong in [
      marker, counterfeit,
      canonicalMarker.deletingLastPathComponent().appendingPathComponent("other.json"),
    ] {
      try rejects(
        "production marker must be in the actual app group with the canonical UUID path"
      ) {
        try FinanceAuthority.validateMarkerPlacement(
          wrong, transactionID: r.txnID, targets: [liveMonthly])
      }
    }
    try check(
      FinanceAuthority.markerReference(for: counterfeit) == counterfeit.path,
      "lookalike group must remain isolated")
    try FinanceAuthority.validateMarkerPlacement(
      marker, transactionID: "local-fixture", targets: [m])
    try rejects("writers not frozen") { _ = try Migration.run(request("nofreeze", frozen: false)) }
    let invalidInput = Migration.MonthlyInput(
      snapshotPath: monthly.path, artifactSHA256: sqliteHash,
      sourceRevision: String(repeating: "0", count: 64))
    try rejects("monthly source revision mismatch") {
      _ = try Migration.run(request("bad", input: invalidInput))
    }
    try check(
      !fm.fileExists(atPath: root.appendingPathComponent("bad/group/Monthly").path),
      "invalid input was promoted")
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
        && !fm.fileExists(atPath: marker.path),
      "wrong partial state")
    try rejects("partial directory accidentally writable") {
      _ = try FinanceAuthority.require(module: "monthly", directory: m)
    }
    try interrupt(r, at: "marker-published")
    try check(fm.fileExists(atPath: marker.path), "global marker missing")
    _ = try FinanceAuthority.require(module: "monthly", directory: m)
    try rejects("research module cannot run") {
      _ = try FinanceAuthority.require(module: "research-funding", directory: m)
    }
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
    try conn.transaction { $0.subscriptions[0].name = "User change after cutover" }
    let resume = try Migration.run(r)
    try check(
      resume.alreadyCommitted && resume.verifiedArtifactSHA256["monthly"] == sqliteHash,
      "did not finalize interrupted commit")
    try check(
      try conn.read().subscriptions.first?.name == "User change after cutover",
      "rerun overwrote new user data")
    try check(try Migration.run(r).alreadyCommitted, "same transaction not idempotent")
    let beforeJournal = try Data(contentsOf: journal.appendingPathComponent("journal.json"))
    let j = try JSONSerialization.jsonObject(with: beforeJournal) as! [String: Any]
    let mods = j["prepared"] as! [String: [String: Any]]
    try check(
      j["phase"] as? String == "committed" && Set(mods.keys) == ["monthly"]
        && (mods["monthly"]?["idMap"] as? [String: String])?.values.contains(sub.id.uuidString)
          == true,
      "missing journal/source mapping")
    try rejects("conflicting transaction with same private root") {
      _ = try Migration.run(request("cutover"))
    }
    let savedMarker = try Data(contentsOf: marker)
    var incompatible = try JSONDecoder().decode(FinanceCommitMarker.self, from: savedMarker)
    incompatible.modules = ["monthly", "research-funding"]
    try JSONEncoder().encode(incompatible).write(to: marker, options: .atomic)
    try rejects("marker broader than monthly receipt cannot unlock monthly") {
      _ = try FinanceAuthority.require(module: "monthly", directory: m)
    }
    try savedMarker.write(to: marker, options: .atomic)
    try Data("{bad".utf8).write(to: marker)
    try rejects("broken commit marker") { _ = try Migration.run(r) }
    try savedMarker.write(to: marker)
    try fm.removeItem(at: marker)
    try rejects("lost committed marker must not be recreated") { _ = try Migration.run(r) }
    try check(!fm.fileExists(atPath: marker.path), "missing marker recreated")
    try savedMarker.write(to: marker)
    let unknown = request("occupied")
    let u = URL(fileURLWithPath: unknown.targetMonthlyDirectory)
    try fm.createDirectory(at: u, withIntermediateDirectories: true)
    let user = u.appendingPathComponent("existing")
    try Data("private".utf8).write(to: user)
    try rejects("unknown preexisting target") { _ = try Migration.run(unknown) }
    try check(
      try Data(contentsOf: user) == Data("private".utf8), "existing user contents overwritten")
    try Data("other".utf8).write(to: monthly)
    try rejects("new transaction with replaced input snapshot") {
      _ = try Migration.run(request("changed-input"))
    }
    try sqliteBytes.write(to: monthly)
    try fm.moveItem(at: source, to: root.appendingPathComponent("retired-source"))
    let archivedResume = try Migration.run(r)
    try check(
      archivedResume.alreadyCommitted
        && archivedResume.verifiedArtifactSHA256["monthly"] == sqliteHash,
      "safe resume should use frozen archive after source retirement")
    try fm.removeItem(at: archive)
    try rejects("missing archived source after commit") { _ = try Migration.run(r) }
    try check(!fm.fileExists(atPath: archive.path), "missing archive silently regenerated")

    // Historical joint receipts remain valid for monthly only. No migration run follows these writes.
    var legacyReceipt = try JSONDecoder().decode(
      FinanceAuthorityReceipt.self, from: Data(contentsOf: m.appendingPathComponent("authority.json")))
    legacyReceipt.expectedModules = ["monthly", "research-funding"]
    var legacyMarker = try JSONDecoder().decode(FinanceCommitMarker.self, from: savedMarker)
    legacyMarker.modules = ["monthly", "research-funding"]
    try JSONEncoder().encode(legacyReceipt).write(
      to: m.appendingPathComponent("authority.json"), options: .atomic)
    try JSONEncoder().encode(legacyMarker).write(to: marker, options: .atomic)
    _ = try FinanceAuthority.require(module: "monthly", directory: m)
    try rejects("legacy research identifier cannot enable research") {
      _ = try FinanceAuthority.require(module: "research-funding", directory: m)
    }
    print(
      "PASS monthly finance transaction: staging, recovery, idempotence, input and marker protection, legacy joint receipt compatibility"
    )
  }
}
