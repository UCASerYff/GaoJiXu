import CryptoKit
import Foundation

@main struct MonthlyFinanceRegression {
  static func check(_ ok: Bool, _ message: String) throws {
    if !ok { throw MonthlyFinanceError(message) }
  }
  static func rejects(_ f: () throws -> Void) throws {
    var rejected = false
    do { try f() } catch { rejected = true }
    try check(rejected, "操作应当被拒绝")
  }
  static func main() throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(
      "MonthlyFinanceUnit-\(UUID()).noindex", isDirectory: true)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let source = base.appendingPathComponent("frozen.sqlite")
    let dest = base.appendingPathComponent("monthly")
    let authority = dest.appendingPathComponent("authority.json")
    let marker = base.appendingPathComponent("commit.json")
    func d(_ t: String) -> Date { ISO8601DateFormatter().date(from: t)! }
    let oct = d("2026-10-01T00:00:00Z")
    let now = d("2026-11-02T08:00:00Z")
    let plan = MonthlyFinancePlan(
      start: oct, anchor: oct, price: Decimal(string: "12.34")!, benefit: .weekly)
    let sub = MonthlyFinanceSubscription(name: "隔离订阅", plans: [plan])
    let ind = MonthlyFinanceBenefitItem(name: "独立周权益", kind: .weekly)
    let linked = MonthlyFinanceBenefitItem(name: "日权益", kind: .daily, subscriptionID: sub.id)
    var seed = MonthlyFinanceState(updatedAt: oct, subscriptions: [sub], benefits: [ind, linked])
    seed.preferences.timezone = "Asia/Shanghai"
    let paidBill = MonthlyFinanceEngine.bills(sub, state: seed, from: oct, through: oct).first!
    try MonthlyFinanceEngine.savePayment(
      &seed, bill: paidBill, expected: nil, amount: 12.34, paidAt: oct, skipped: false, note: "原确认",
      periods: 1, now: now)
    seed.claims = [
      .init(id: "\(ind.id)|weekly|2026-11-02", subscriptionID: ind.id, date: now, recordedAt: now),
      .init(id: "\(linked.id)|daily|2026-11-02", subscriptionID: sub.id, date: now, recordedAt: now),
    ]
    var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(seed)) as! [String: Any]
    obj.removeValue(forKey: "legacyRewardIDs")
    obj["rewards"] = [["id": "claim|legacy", "date": 10, "kind": "claim", "amount": 20]]
    obj["tombstones"] = ["migration|benefits-v1", "claim|legacy"]
    obj["pet"] = ["privateTrace": "never-copy-value"]
    var prefs = obj["preferences"] as! [String: Any]
    prefs["game"] = true
    obj["preferences"] = prefs
    let raw = try JSONSerialization.data(withJSONObject: obj, options: .sortedKeys)
    try Data().write(to: source, options: .withoutOverwriting)
    let conn = try MonthlyFinanceConnection(existing: source, readOnly: false)
    try conn.exec("CREATE TABLE state(id INTEGER PRIMARY KEY CHECK(id=1),json BLOB NOT NULL)")
    try conn.updatePayload(raw, initial: true)
    let staged = try MonthlyFinanceMigration.stage(snapshotURL: source, into: dest)
    try check(
      staged.sourceSHA256 == SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined(),
      "不是原始记录摘要")
    try check(!fm.fileExists(atPath: authority.path), "暂存不能发布权威标记")
    try rejects { _ = try MonthlyFinanceDatabase(directory: dest) }
    try rejects { _ = try MonthlyFinanceMigration.stage(snapshotURL: source, into: dest) }
    let rec = FinanceAuthorityReceipt(
      module: "monthly", transactionID: "fixture", sourceBundleID: "com.gaoseries.GaoYueGong",
      sourceRevision: staged.sourceSHA256, sourceFrozen: true, mode: "migrated", activatedAt: now,
      commitMarkerPath: marker.path, expectedModules: ["monthly"])
    try JSONEncoder().encode(rec).write(to: authority)
    try rejects { _ = try MonthlyFinanceDatabase(directory: dest) }
    try JSONEncoder().encode(
      FinanceCommitMarker(transactionID: "fixture", modules: ["monthly"], committedAt: now)
    ).write(to: marker)
    let db = try MonthlyFinanceDatabase(directory: dest, readOnly: false)
    let original = try db.read()
    try check(
      original.subscriptions == seed.subscriptions && original.payments == seed.payments
        && original.benefits == seed.benefits && original.claims == seed.claims
        && original.legacyRewardIDs == Set(["claim|legacy"]),
      "迁移数据不一致")
    let encoded = try MonthlyFinanceConnection(existing: staged.databaseURL, readOnly: true)
      .payload()
    let fields = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    try check(
      fields["pet"] == nil && fields["rewards"] == nil
        && !String(decoding: encoded, as: UTF8.self).contains("never-copy-value"), "源游戏数据进入目标库")
    let future = d("2027-02-03T08:00:00Z")
    try check(
      MonthlyFinanceEngine.rating(sub, original, now: now).score == nil
        && !MonthlyFinanceEngine.dusty(sub, original, now: future),
      "停用的权益打卡不应代替订阅自评或产生续费提醒")
    let b = MonthlyFinanceEngine.pending(original, now: now).first!
    try db.transaction { s in
      try MonthlyFinanceEngine.savePayment(
        &s, bill: b, expected: nil, amount: 0, paidAt: now, skipped: true, note: "未扣", periods: 1,
        now: now)
    }
    try rejects {
      try db.transaction { s in
        try MonthlyFinanceEngine.savePayment(
          &s, bill: b, expected: nil, amount: 12.34, paidAt: now, skipped: false, note: "",
          periods: 1, now: now)
      }
    }
    let skipTotals = MonthlyFinanceEngine.statistics(try db.read(), currency: "CNY", now: now)
    try check(
      skipTotals.trend.count == 12 && skipTotals.trend.last?.paid == 0
        && skipTotals.monthlyEstimate == 12.34, "未扣、未确认与预计支出混淆")
    let skip = try db.read().payments.first { $0.id == b.id }!
    try db.transaction { s in
      try MonthlyFinanceEngine.savePayment(
        &s, bill: b, expected: skip, amount: 12.35, paidAt: now, skipped: false, note: "更正",
        periods: 1, now: now)
    }
    try check(try db.read().payments.count == 2, "支付更正重复建记录")
    let spend = MonthlyFinanceEngine.statistics(try db.read(), currency: "CNY", now: now)
    let usd = MonthlyFinanceEngine.statistics(try db.read(), currency: "USD", now: now)
    try check(
      spend.trend.last?.paid == 12.35 && spend.trend.last?.count == 1 && usd.monthlyEstimate == 0
        && usd.trend.allSatisfy { $0.paid == 0 }, "实付月/币种口径错误")
    try db.transaction {
      try MonthlyFinanceEngine.setReview(
        &$0, subscriptionID: sub.id, month: now, score: 0, expected: nil, now: now)
    }
    let oldReview = try db.read().reviews.first!
    try db.transaction {
      try MonthlyFinanceEngine.setReview(
        &$0, subscriptionID: sub.id, month: now, score: 2, expected: oldReview, now: now)
    }
    try rejects {
      try db.transaction {
        try MonthlyFinanceEngine.setReview(
          &$0, subscriptionID: sub.id, month: now, score: 1, expected: oldReview, now: now)
      }
    }
    let reviewState = try db.read()
    try check(
      reviewState.reviews.count == 1 && reviewState.reviews[0].rating == 2
        && MonthlyFinanceEngine.rating(sub, reviewState, now: now).score == 2
        && reviewState.benefits == seed.benefits && reviewState.claims == seed.claims
        && reviewState.legacyRewardIDs == original.legacyRewardIDs
        && reviewState.tombstones == original.tombstones, "自评、支付写入或旧权益历史回读不一致")
    var reviewHistory = reviewState
    try MonthlyFinanceEngine.setReview(
      &reviewHistory, subscriptionID: sub.id, month: d("2026-12-15T08:00:00Z"),
      score: 0, expected: nil, now: future)
    try check(
      !MonthlyFinanceEngine.dusty(sub, reviewHistory, now: future), "缺失评分月不应记为低使用")
    try MonthlyFinanceEngine.setReview(
      &reviewHistory, subscriptionID: sub.id, month: d("2027-01-15T08:00:00Z"),
      score: 0, expected: nil, now: future)
    try check(
      MonthlyFinanceEngine.dusty(sub, reviewHistory, now: future), "两个完整月的低使用自评应保留复盘提示")
    try db.transaction { s in
      var changed = sub
      changed.plans[0].price = 20
      try MonthlyFinanceEngine.saveSubscription(
        &s, input: changed, expected: sub, effectiveAt: now, now: now)
    }
    let revised = try db.read().subscriptions[0]
    try check(
      revised.plans.count == 2 && revised.plans[0].price == 12.34
        && revised.plans[0].benefit == .weekly && revised.plans[1].benefit == .none
        && revised.plans[0].end == revised.plans[1].start, "修订没有保留历史计划")
    try db.transaction { s in
      try MonthlyFinanceEngine.removeSubscription(&s, expected: revised)
    }
    let detached = try db.read()
    var detachedBenefit = linked
    detachedBenefit.subscriptionID = nil
    var detachedClaim = seed.claims[1]
    detachedClaim.subscriptionID = linked.id
    try check(
      detached.benefits == [ind, detachedBenefit]
        && detached.claims == [seed.claims[0], detachedClaim]
        && detached.legacyRewardIDs == original.legacyRewardIDs, "解除订阅损坏了旧权益或打卡")
    // The earliest snapshots kept the benefit on the subscription plan, without a benefits array.
    let olderClaim = MonthlyFinanceClaim(
      id: "\(sub.id)|weekly|2026-11-02", subscriptionID: sub.id, date: now, recordedAt: now)
    var older = obj
    older.removeValue(forKey: "benefits")
    older["claims"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([olderClaim]))
    older["tombstones"] = ["claim|legacy"]
    let olderRaw = try JSONSerialization.data(withJSONObject: older, options: .sortedKeys)
    try conn.updatePayload(olderRaw)
    let olderStaged = try MonthlyFinanceMigration.stage(
      snapshotURL: source, into: base.appendingPathComponent("older-monthly"))
    let olderState = try JSONDecoder().decode(
      MonthlyFinanceState.self,
      from: MonthlyFinanceConnection(existing: olderStaged.databaseURL, readOnly: true).payload())
    var olderBenefit = MonthlyFinanceBenefitItem(
      id: sub.id, name: sub.name, kind: .weekly, subscriptionID: sub.id,
      createdAt: sub.createdAt, archived: sub.archived)
    try check(
      try conn.payload() == olderRaw && olderState.claims == [olderClaim]
        && olderState.benefits == [olderBenefit]
        && olderState.subscriptions == seed.subscriptions && olderState.payments == seed.payments
        && olderState.legacyRewardIDs == original.legacyRewardIDs,
      "仅有计划权益的旧快照未完整保留关联、历史或原始源")
    var olderDetached = olderState
    try MonthlyFinanceEngine.removeSubscription(&olderDetached, expected: sub)
    try MonthlyFinanceEngine.validate(olderDetached)
    olderBenefit.subscriptionID = nil
    try check(
      olderDetached.benefits == [olderBenefit] && olderDetached.claims == [olderClaim],
      "解除旧式订阅不应删除仍有历史所有者的打卡")
    try fm.removeItem(at: marker)
    try rejects { _ = try db.read() }
    try rejects { try db.transaction { $0.events = [] } }
    let missing = base.appendingPathComponent("missing")
    try rejects { _ = try MonthlyFinanceDatabase(directory: missing, readOnly: false) }
    try check(!fm.fileExists(atPath: missing.path), "读取创建空库")
    let newDir = base.appendingPathComponent("fresh")
    try rejects {
      try MonthlyFinanceMigration.initializeNew(directory: newDir, legacyEvidence: [source])
    }
    try MonthlyFinanceMigration.initializeNew(directory: newDir, legacyEvidence: [missing])
    try check(try MonthlyFinanceDatabase(directory: newDir).read().subscriptions.isEmpty, "显式新建应为空")
    var bad = obj
    bad["schemaVersion"] = 2
    try conn.updatePayload(JSONSerialization.data(withJSONObject: bad))
    try rejects {
      _ = try MonthlyFinanceMigration.stage(
        snapshotURL: source, into: base.appendingPathComponent("unknown"))
    }
    bad = obj
    bad["payments"] = (bad["payments"] as! [[String: Any]]) + (bad["payments"] as! [[String: Any]])
    try conn.updatePayload(JSONSerialization.data(withJSONObject: bad))
    try rejects {
      _ = try MonthlyFinanceMigration.stage(
        snapshotURL: source, into: base.appendingPathComponent("duplicate"))
    }
    // Both stores contain the same valid BLOB at id=1. Reading just those two values would
    // accept them and silently discard an added column or an incompatible declared schema.
    for (name, schema) in [
      ("extra-column", "id INTEGER PRIMARY KEY CHECK(id=1), json BLOB NOT NULL, future TEXT DEFAULT 'keep'"),
      ("wrong-affinity", "id INTEGER PRIMARY KEY CHECK(id=1), json TEXT NOT NULL"),
    ] {
      let fixture = base.appendingPathComponent(name + ".sqlite")
      try Data().write(to: fixture, options: .withoutOverwriting)
      let malformed = try MonthlyFinanceConnection(existing: fixture, readOnly: false)
      try malformed.exec("CREATE TABLE state(\(schema))")
      try malformed.updatePayload(raw, initial: true)
      try check(try malformed.payload() == raw, "隔离夹具未保存原始 BLOB")
      let destination = base.appendingPathComponent(name + "-target")
      try rejects { _ = try MonthlyFinanceMigration.stage(snapshotURL: fixture, into: destination) }
      try check(!fm.fileExists(atPath: destination.path), "未知表结构创建了目标暂存库")
    }
    print(
      "PASS: snapshot-only staging, old benefit history, source hash, authority, payment/plan history, manual usage review, no reward replay, orphan protection, no silent empty store."
    )
  }
}
