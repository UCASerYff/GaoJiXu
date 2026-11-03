import CryptoKit
import Foundation

/// Targeted command-line regression; all inputs and writes stay under a unique temporary root.
@main struct ResearchFundingRegression {
  enum Failed: Error { case assertion(String) }
  static func check(_ ok: @autoclosure () throws -> Bool, _ msg: String) throws {
    if try !ok() { throw Failed.assertion(msg) }
  }
  static func rejects(_ msg: String, _ perform: () throws -> Void) throws {
    do { try perform() } catch { return }
    throw Failed.assertion("should reject: " + msg)
  }
  static func hash(_ d: Data) -> String {
    SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
  }
  @MainActor static func main() throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent(
      "research-funding-regression-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/ResearchFunding")
    let src = tmp.appendingPathComponent("isolated-source", isDirectory: true)
    let target = tmp.appendingPathComponent("target", isDirectory: true)
    try fm.createDirectory(at: src, withIntermediateDirectories: true)
    let bundle = src.appendingPathComponent("research-funding-v1.json")
    let sourceArchive = try Data(
      contentsOf: fixture.appendingPathComponent("synthetic-source-v32.json"))
    let rev = hash(sourceArchive)
    let input = try Data(contentsOf: fixture.appendingPathComponent("research-funding-v1.json"))
    try input.write(to: bundle)
    try rejects("export bundle digest mismatch") {
      _ = try ResearchFundingImport.stage(
        packageURL: bundle, into: target, expectedSourceRevision: rev,
        expectedPackageSHA256: String(repeating: "0", count: 64))
    }
    let result = try ResearchFundingImport.stage(
      packageURL: bundle, into: target, expectedSourceRevision: rev,
      expectedPackageSHA256: hash(input))
    try check(
      result.activeCount == 2 && result.trashCount == 1 && result.attachmentCount == 0
        && result.idMap.count == 4, "preserve active/trashed identities")
    let libraryFile = target.appendingPathComponent("library.json")
    let initial = try Data(contentsOf: libraryFile)
    let model = try JSONDecoder().decode(ResearchFundingLibrary.self, from: initial)
    try check(
      model.fundingRecords[0].amount == 120.125 && model.fundingRecords[0].months == [1, 3]
        && model.fundingRecords[0].currency == nil
        && model.fundingRecords[0].projectReference == nil,
      "original schedule, exact amount and no invented relation")
    try check(
      model.trashItems[0].id != model.trashItems[0].funding.id
        && model.trashItems[0].originalEnvelope != nil, "original deletion envelope retained")
    // No personal ledger, no game, no source writes, no implicit authority.
    let guarded = ResearchFundingStore(directory: target)
    try check(guarded.access == .protected, "staged library cannot be edited")
    let tx = UUID().uuidString
    let marker = tmp.appendingPathComponent("integration-commit.json")
    let receipt = FinanceAuthorityReceipt(
      module: "research-funding", transactionID: tx,
      sourceBundleID: ResearchFundingLibrary.sourceID, sourceRevision: rev, sourceFrozen: true,
      mode: "migrated", activatedAt: Date(), commitMarkerPath: marker.path, expectedModules: ["research-funding"])
    try JSONEncoder().encode(receipt).write(to: target.appendingPathComponent("authority.json"))
    guarded.reload()
    try check(guarded.access == .protected, "partial commit remains locked")
    try JSONEncoder().encode(
      FinanceCommitMarker(transactionID: tx, modules: ["research-funding"], committedAt: Date())
    ).write(to: marker)
    guarded.reload()
    let stale = ResearchFundingStore(directory: target)
    try check(guarded.access == .ready, "verified cutover should open domain")
    let key = try guarded.save(
      id: nil, name: "支出之外的研究计划", amount: 47.125, year: 2030, months: [12, 2],
      receivingAccount: "仅测试标签", currency: "USD", projectReference: "explicit-test-reference")
    try rejects("stale editor") {
      _ = try stale.save(
        id: nil, name: "stale", amount: 1, year: 2030, months: [1], receivingAccount: "x",
        currency: "CNY")
    }
    try check(
      guarded.library!.fundingRecords[0].months == [2, 12],
      "canonical month order for new user input")
    try guarded.moveToTrash(key)
    let trashID = guarded.library!.trashItems.first(where: { $0.funding.id == key })!.id
    try guarded.restore(trashID)
    _ = try guarded.save(
      id: key, name: "重命名", amount: 50, year: 2030, months: [2], receivingAccount: "explicit",
      currency: "USD", projectReference: "explicit-test-reference")
    try guarded.moveToTrash(key)
    try guarded.permanentlyDelete(
      guarded.library!.trashItems.first(where: { $0.funding.id == key })!.id)
    guarded.reload()
    try check(
      guarded.library == model, "roundtrip CRUD leaves all original records/deletions unchanged")
    try check(
      try Data(contentsOf: bundle) == input
        && !fm.fileExists(atPath: tmp.appendingPathComponent("library.json").path),
      "no source rewrite or personal ledger")
    try rejects("do not overwrite edited/occupied stage") {
      _ = try ResearchFundingImport.stage(
        packageURL: bundle, into: target, expectedSourceRevision: rev)
    }
    var unexpected = try JSONSerialization.jsonObject(with: initial) as! [String: Any]
    unexpected["unrecognizedFutureRelation"] = ["id": "keep-this-on-disk"]
    let modifiedBytes = try JSONSerialization.data(withJSONObject: unexpected)
    try modifiedBytes.write(to: libraryFile)
    guarded.reload()
    try check(
      guarded.access == .protected && Data(contentsOf: libraryFile) == modifiedBytes,
      "new target fields must not be discarded on edit")
    let removed = tmp.appendingPathComponent("temporarily-removed-library.json")
    try fm.moveItem(at: libraryFile, to: removed)
    guarded.reload()
    try check(guarded.access == .protected, "migrated library deletion is not a new user")
    try rejects("no reset") { try guarded.initializeNew() }
    try check(!fm.fileExists(atPath: libraryFile.path), "missing library not recreated during load")
    let fresh = tmp.appendingPathComponent("fresh")
    let legacy = tmp.appendingPathComponent("legacy-evidence")
    let c = ResearchFundingStore(directory: fresh, legacyEvidence: { [legacy] })
    try check(
      c.access == .awaitingAuthority && !fm.fileExists(atPath: fresh.path),
      "just opening cannot create anything")
    try Data("legacy".utf8).write(to: legacy)
    try rejects("legacy evidence blocks empty initialization") { try c.requestNewLibrary() }
    try check(!fm.fileExists(atPath: fresh.path), "failed new-library action did not claim root")
    try fm.removeItem(at: legacy)
    try c.requestNewLibrary()
    try check(c.access == .ready, "created empty after explicit approval")
    try fm.removeItem(at: fresh.appendingPathComponent("library.json"))
    c.reload()
    try check(c.access == .protected, "new account lost library after creation stays protected")
    let raw = try JSONSerialization.jsonObject(with: input) as! [String: Any]
    func attempt(_ change: (inout [String: Any]) -> Void) throws {
      var b = raw
      change(&b)
      try JSONSerialization.data(withJSONObject: b).write(to: bundle)
      let isolated = tmp.appendingPathComponent(UUID().uuidString)
      try rejects("invalid import") {
        _ = try ResearchFundingImport.stage(
          packageURL: bundle, into: isolated, expectedSourceRevision: rev)
      }
      try check(
        !fm.fileExists(atPath: isolated.appendingPathComponent("library.json").path),
        "invalid import produced target library")
    }
    try attempt { $0.removeValue(forKey: "fundingRecords") }
    try attempt { $0["schemaVersion"] = 2 }
    try attempt { $0["sourceRevision"] = String(repeating: "0", count: 64) }
    try attempt {
      var a = $0["fundingRecords"] as! [[String: Any]]
      a[0]["months"] = [1, 1]
      $0["fundingRecords"] = a
    }
    try attempt {
      let a = $0["fundingRecords"] as! [[String: Any]]
      var t = $0["trashItems"] as! [[String: Any]]
      t[0]["funding"] = a[0]
      $0["trashItems"] = t
    }
    let recID = model.fundingRecords[0].id
    let bytes = Data("Public synthetic document".utf8)
    let template: [String: Any] = [
      "id": "a", "fundingID": recID, "relativePath": "proofs/unit.txt", "byteCount": bytes.count,
      "sha256": hash(bytes),
    ]
    try attempt { $0["attachments"] = [template] }
    try attempt {
      var a = template
      a["relativePath"] = "../unit.txt"
      $0["attachments"] = [a]
    }
    let proof = src.appendingPathComponent("proofs")
    try fm.createDirectory(at: proof, withIntermediateDirectories: true)
    let doc = proof.appendingPathComponent("unit.txt")
    try fm.createSymbolicLink(at: doc, withDestinationURL: bundle)
    try attempt { $0["attachments"] = [template] }
    try fm.removeItem(at: doc)
    try Data("wrong".utf8).write(to: doc)
    try attempt { $0["attachments"] = [template] }
    try bytes.write(to: doc)
    var good = raw
    good["attachments"] = [template]
    try JSONSerialization.data(withJSONObject: good).write(to: bundle)
    let folder = tmp.appendingPathComponent("good-attachment")
    let copied = try ResearchFundingImport.stage(
      packageURL: bundle, into: folder, expectedSourceRevision: rev)
    try check(
      copied.attachmentCount == 1
        && Data(contentsOf: folder.appendingPathComponent("Attachments/proofs/unit.txt")) == bytes,
      "verified linked file copied")
    let duplicate = String(decoding: input, as: UTF8.self).replacingOccurrences(
      of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 1, \"schemaVersion\": 1")
    try Data(duplicate.utf8).write(to: bundle)
    try rejects("ambiguous JSON member") {
      _ = try ResearchFundingImport.stage(
        packageURL: bundle, into: tmp.appendingPathComponent("ambiguous"),
        expectedSourceRevision: rev)
    }
    print(
      "PASS research funding: strict fixture and source hash, separate plan/trash IDs, authority and optimistic write protection, explicit creation, data-loss lockout, independent CRUD, attachment hash/path/symlink checks"
    )
  }
}
