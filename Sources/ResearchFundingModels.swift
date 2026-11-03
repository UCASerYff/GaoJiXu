import Foundation

/// This is a schedule in a separate research domain. It never denotes an actual receipt.
struct ResearchFundingRecord: Codable, Equatable, Identifiable {
  let id: String
  var name: String
  var amount: Double
  var year: Int
  var months: [Int]
  var receivingAccount: String
  let createdAt: String
  var updatedAt: String
  // Only set by explicit user input in Savings. Old research records had neither field.
  var currency: String? = nil
  var projectReference: String? = nil

  func validate() throws {
    guard !id.isEmpty, id.unicodeScalars.count <= 1024, !id.utf8.contains(0),
      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      amount.isFinite, amount >= 0, (1...9999).contains(year),
      months.allSatisfy({ (1...12).contains($0) }), Set(months).count == months.count,
      ResearchFundingFormat.date(createdAt) != nil, ResearchFundingFormat.date(updatedAt) != nil,
      currency.map(ResearchFundingFormat.validCurrency) ?? true
    else { throw ResearchFundingError.invalidRecord }
  }
}

struct ResearchFundingTrashItem: Codable, Equatable, Identifiable {
  let id: String
  let kind: String
  let title: String
  let deletedAt: String
  let funding: ResearchFundingRecord
  /// Complete original v32 trash envelope, including its own ID, not just the nested funding record.
  var originalEnvelope: Data? = nil
}

struct ResearchFundingAttachment: Codable, Equatable, Identifiable {
  let id: String
  let fundingID: String
  let relativePath: String
  let byteCount: Int64
  let sha256: String
}

struct ResearchFundingLibrary: Codable, Equatable {
  let schemaVersion: Int
  let sourceBundleID: String?
  let sourceRevision: String?
  var fundingRecords: [ResearchFundingRecord]
  var trashItems: [ResearchFundingTrashItem]
  var attachments: [ResearchFundingAttachment]

  static let sourceID = "com.academic-achievement.manager"
  static let empty = Self(
    schemaVersion: 1, sourceBundleID: nil, sourceRevision: nil,
    fundingRecords: [], trashItems: [], attachments: [])
  func validate() throws {
    guard schemaVersion == 1 else { throw ResearchFundingError.schema }
    guard
      (sourceBundleID == nil && sourceRevision == nil)
        || (sourceBundleID == Self.sourceID
          && sourceRevision.map(ResearchFundingFormat.digest) == true)
    else { throw ResearchFundingError.invalidRecord }
    let records = fundingRecords + trashItems.map(\.funding)
    let ids = Set(records.map(\.id))
    guard ids.count == records.count, Set(trashItems.map(\.id)).count == trashItems.count,
      Set(attachments.map(\.id)).count == attachments.count,
      Set(attachments.map { $0.relativePath.precomposedStringWithCanonicalMapping.lowercased() })
        .count == attachments.count
    else { throw ResearchFundingError.conflict }
    for r in records { try r.validate() }
    for t in trashItems {
      guard !t.id.isEmpty, t.kind == "funding", ResearchFundingFormat.date(t.deletedAt) != nil
      else { throw ResearchFundingError.invalidRecord }
      if let envelope = t.originalEnvelope {
        let original = try JSONDecoder().decode(ResearchFundingTrashItem.self, from: envelope)
        guard original.id == t.id, original.kind == t.kind, original.title == t.title,
          original.deletedAt == t.deletedAt, original.funding == t.funding,
          original.originalEnvelope == nil
        else { throw ResearchFundingError.invalidRecord }
      }
    }
    for a in attachments {
      guard ids.contains(a.fundingID), !a.id.isEmpty, a.byteCount >= 0,
        ResearchFundingFormat.digest(a.sha256), ResearchFundingFormat.safeRelative(a.relativePath)
      else { throw ResearchFundingError.unsafeAttachment }
    }
  }
}

enum ResearchFundingFormat {
  static func date(_ s: String) -> Date? {
    guard s.utf8.count <= 64,
      s.range(
        of:
          #"^\d{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12]\d|3[01])T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d+)?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)$"#,
        options: .regularExpression) != nil
    else { return nil }
    let ymd = s.prefix(10).split(separator: "-").compactMap { Int($0) }
    guard ymd.count == 3, ymd[0] > 0 else { return nil }
    let leap =
      ymd[0].isMultiple(of: 4) && (!ymd[0].isMultiple(of: 100) || ymd[0].isMultiple(of: 400))
    let limits = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    guard (1...12).contains(ymd[1]), ymd[2] <= limits[ymd[1] - 1] else { return nil }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = iso.date(from: s) { return date }
    iso.formatOptions = [.withInternetDateTime]
    return iso.date(from: s)
  }
  static func timestamp(_ date: Date = Date()) -> String {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return iso.string(from: date)
  }
  static func digest(_ s: String) -> Bool {
    s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
  static func validCurrency(_ s: String) -> Bool {
    s.utf8.count == 3 && s.utf8.allSatisfy { (65...90).contains($0) }
  }
  static func safeRelative(_ s: String) -> Bool {
    guard !s.isEmpty, !s.contains("\\"), !s.utf8.contains(0) else { return false }
    return s.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
      !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains(":")
    }
  }
}

enum ResearchFundingError: LocalizedError {
  case schema, invalidRecord, conflict, unavailable, changed, invalidPackage, unsafeAttachment,
    invalidStage, readOnly
  var errorDescription: String? {
    switch self {
    case .schema: return "不支持该科研资金资料版本，原文件已保留。"
    case .invalidRecord: return "科研资金字段、月份或日期不完整，已停止处理。"
    case .conflict: return "科研资金项目、回收项或附件存在重复或冲突的标识。"
    case .unavailable: return "科研资金资料缺失或无法读取，请检查已验证的备份。"
    case .changed: return "科研资金资料已经变化，请重新载入后再操作。"
    case .invalidPackage: return "科研资金迁移包的来源、摘要或结构无法核验。"
    case .unsafeAttachment: return "科研资金附件路径、大小或摘要不符，未提交迁移。"
    case .invalidStage: return "科研资金暂存目录必须为空且不能与来源重叠。"
    case .readOnly: return "科研资金尚未获准在搞积蓄中管理，当前为只读。"
    }
  }
}
