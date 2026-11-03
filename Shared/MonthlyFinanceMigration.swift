import CryptoKit
import Darwin
import Foundation

/// Only this installer-side operation creates a database in a fresh staging directory. No authority marker is published here.
enum MonthlyFinanceMigration {
  struct Result {
    let sourceSHA256: String
    let databaseURL: URL
    let counts: [String: Int]
  }
  /// A one-way DTO: decode business fields without encoding the source game or reward values into the target database.
  private struct Source: Decodable {
    struct RewardID: Decodable {
      let id: String
      let date: Date
      let kind: String
      let amount: Int
      let subscriptionID: UUID?
    }
    let schemaVersion: Int, rulesVersion: Int, updatedAt: Date,
      subscriptions: [MonthlyFinanceSubscription], payments: [MonthlyFinancePayment],
      claims: [MonthlyFinanceClaim], reviews: [MonthlyFinanceReview], rewards: [RewardID],
      events: [MonthlyFinanceEvent]?, benefits: [MonthlyFinanceBenefitItem]?,
      preferences: MonthlyFinancePreferences, tombstones: [String]
  }
  static func stage(snapshotURL: URL, into directory: URL) throws -> Result {
    let file = directory.appendingPathComponent("monthly.sqlite")
    guard
      snapshotURL.standardizedFileURL.resolvingSymlinksInPath()
        != file.standardizedFileURL.resolvingSymlinksInPath()
    else { throw MonthlyFinanceError("来源与目标不能相同。") }
    let c = try MonthlyFinanceConnection(existing: snapshotURL, readOnly: true)
    try c.exec("BEGIN")
    let raw: Data
    do {
      try c.verifySnapshot()
      raw = try c.payload()
      try c.exec("COMMIT")
    } catch {
      try? c.exec("ROLLBACK")
      throw error
    }
    guard let envelope = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
      envelope["pet"] is [String: Any], let preferences = envelope["preferences"] as? [String: Any],
      preferences["game"] is Bool
    else { throw MonthlyFinanceError("原始月供快照不完整。") }
    let src = try JSONDecoder().decode(Source.self, from: raw)
    guard src.schemaVersion == 1, src.rulesVersion == 1 else {
      throw MonthlyFinanceError("原月供版本不受支持，保留原快照。")
    }
    let oldRewardIDs = src.rewards.map(\.id)
    guard Set(oldRewardIDs).count == oldRewardIDs.count,
      Set(src.tombstones).count == src.tombstones.count
    else { throw MonthlyFinanceError("历史防重标记存在冲突。") }
    var s = MonthlyFinanceState(
      updatedAt: src.updatedAt, subscriptions: src.subscriptions, payments: src.payments,
      claims: src.claims, reviews: src.reviews, events: src.events ?? [],
      benefits: src.benefits ?? [], tombstones: Set(src.tombstones),
      legacyRewardIDs: Set(oldRewardIDs), preferences: src.preferences)
    if !s.tombstones.contains("migration|benefits-v1") {
      for sub in s.subscriptions
      where !sub.plans.isEmpty && sub.current.benefit != .none
        && !s.tombstones.contains("deleted-benefit|\(sub.id)")
        && !s.benefits.contains(where: { $0.id == sub.id })
      {
        s.benefits.append(
          .init(
            id: sub.id, name: sub.name, kind: sub.current.benefit, subscriptionID: sub.id,
            createdAt: sub.createdAt, archived: sub.archived))
      }
      s.tombstones.insert("migration|benefits-v1")
    }
    try MonthlyFinanceEngine.validate(s)
    let fm = FileManager.default
    try fm.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let attrs = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
    guard attrs.isSymbolicLink != true, attrs.isDirectory == true,
      try fm.contentsOfDirectory(atPath: directory.path).isEmpty
    else { throw MonthlyFinanceError("暂存目录不为空或不是目录，拒绝覆盖。") }
    let fd = Darwin.open(file.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, mode_t(0o600))
    guard fd >= 0 else { throw MonthlyFinanceError("暂存文件已存在或不可写。") }
    Darwin.close(fd)
    // Never remove/replace an unknown file on failure; the containing private transaction is recoverable by its owning coordinator.
    let out = try MonthlyFinanceConnection(existing: file, readOnly: false)
    try out.exec("BEGIN IMMEDIATE")
    do {
      try out.exec("CREATE TABLE state(id INTEGER PRIMARY KEY CHECK(id=1),json BLOB NOT NULL)")
      try out.updatePayload(JSONEncoder().encode(s), initial: true)
      try out.exec("COMMIT")
    } catch {
      try? out.exec("ROLLBACK")
      throw error
    }
    let verify = try MonthlyFinanceConnection(existing: file, readOnly: true)
    try verify.verifySnapshot()
    let actual = try JSONDecoder().decode(MonthlyFinanceState.self, from: verify.payload())
    try MonthlyFinanceEngine.validate(actual)
    guard actual == s else { throw MonthlyFinanceError("月供暂存逐字段回读不一致。") }
    return Result(
      sourceSHA256: SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined(),
      databaseURL: file,
      counts: [
        "subscriptions": s.subscriptions.count,
        "plans": s.subscriptions.reduce(0) { $0 + $1.plans.count }, "payments": s.payments.count,
        "benefits": s.benefits.count, "claims": s.claims.count, "reviews": s.reviews.count,
        "events": s.events.count, "legacyRewardIDs": s.legacyRewardIDs.count,
        "tombstones": s.tombstones.count,
      ])
  }
}

extension MonthlyFinanceMigration {
  /// Explicit user action only. The new DB and marker become visible together by an exclusive same-volume rename.
  static func initializeNew(directory: URL, legacyEvidence: [URL]) throws {
    let fm = FileManager.default
    guard !legacyEvidence.isEmpty else { throw MonthlyFinanceError("未提供既有资料检查，拒绝初始化。") }
    let parent = directory.deletingLastPathComponent()
    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
    let staged = parent.appendingPathComponent(
      ".monthly-new-\(UUID().uuidString).noindex", isDirectory: true)
    guard mkdir(staged.path, 0o700) == 0 else { throw MonthlyFinanceError("不能准备新的固定支出库。") }
    defer { try? fm.removeItem(at: staged) }
    try FinanceAuthority.createNew(
      module: "monthly", directory: staged, legacyEvidence: legacyEvidence)
    let file = staged.appendingPathComponent("monthly.sqlite")
    let fd = Darwin.open(file.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, mode_t(0o600))
    guard fd >= 0 else { throw MonthlyFinanceError("不能创建新的固定支出文件。") }
    Darwin.close(fd)
    do {
      let db = try MonthlyFinanceConnection(existing: file, readOnly: false)
      try db.exec("BEGIN IMMEDIATE")
      try db.exec("CREATE TABLE state(id INTEGER PRIMARY KEY CHECK(id=1),json BLOB NOT NULL)")
      try db.updatePayload(JSONEncoder().encode(MonthlyFinanceState()), initial: true)
      try db.exec("COMMIT")
      try db.verifySnapshot()
    }
    _ = try MonthlyFinanceDatabase(directory: staged).read()
    guard renamex_np(staged.path, directory.path, UInt32(RENAME_EXCL)) == 0 else {
      throw MonthlyFinanceError("目标已存在或无法安全启用，未覆盖原资料。")
    }
  }
}
