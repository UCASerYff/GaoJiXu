import Darwin
import Foundation

struct FinanceAuthorityReceipt: Codable, Equatable {
  var schemaVersion = 1
  var ownerBundleID = "com.gaojixu.savings"
  var module: String
  var transactionID: String
  var sourceBundleID: String?
  var sourceRevision: String?
  var sourceFrozen: Bool
  var mode: String
  var activatedAt: Date
  var commitMarkerPath: String? = nil
  var expectedModules: [String]? = nil
}
struct FinanceCommitMarker: Codable, Equatable {
  var schemaVersion = 1
  var ownerBundleID = "com.gaojixu.savings"
  var transactionID: String
  var modules: [String]
  var committedAt: Date
}
enum FinanceAuthority {
  static let owner = "com.gaojixu.savings"
  static let modules: Set<String> = ["monthly", "research-funding"]
  static func failure(_ message: String) -> NSError {
    NSError(
      domain: "GaoJiXu.FinanceAuthority", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
  static func regularData(_ url: URL) throws -> Data {
    let a = try FileManager.default.attributesOfItem(atPath: url.path)
    guard a[.type] as? FileAttributeType == .typeRegular else {
      throw failure("金融资料凭据不是普通文件，已暂停写入。")
    }
    return try Data(contentsOf: url)
  }
  @discardableResult static func require(module: String, directory: URL) throws
    -> FinanceAuthorityReceipt
  {
    guard modules.contains(module) else { throw failure("金融模块不受支持。") }
    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    guard directoryAttributes[.type] as? FileAttributeType == .typeDirectory else {
      throw failure("金融资料目录无效，已暂停写入。")
    }
    let receipt = try JSONDecoder().decode(
      FinanceAuthorityReceipt.self,
      from: regularData(directory.appendingPathComponent("authority.json")))
    guard receipt.schemaVersion == 1, receipt.ownerBundleID == owner, receipt.module == module,
      !receipt.transactionID.isEmpty, receipt.activatedAt.timeIntervalSince1970.isFinite
    else { throw failure("金融资料尚未完成安全切换，已暂停写入。") }
    if receipt.mode == "migrated" {
      let expected =
        module == "monthly" ? "com.gaoseries.GaoYueGong" : "com.academic-achievement.manager"
      guard receipt.sourceFrozen, receipt.sourceBundleID == expected,
        let revision = receipt.sourceRevision,
        revision.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
        let path = receipt.commitMarkerPath, let expectedModules = receipt.expectedModules,
        Set(expectedModules).count == expectedModules.count, expectedModules.contains(module),
        Set(expectedModules).isSubset(of: modules)
      else { throw failure("来源尚未冻结或迁移未完成，保留原资料并暂停写入。") }
      if isProductionDirectory(directory) {
        try validateProductionReference(path, transactionID: receipt.transactionID)
      }
      let marker = try JSONDecoder().decode(
        FinanceCommitMarker.self,
        from: regularData(try resolveMarker(path, transactionID: receipt.transactionID)))
      guard marker.schemaVersion == 1, marker.ownerBundleID == owner,
        marker.transactionID == receipt.transactionID,
        marker.committedAt.timeIntervalSince1970.isFinite,
        Set(marker.modules).count == marker.modules.count,
        Set(marker.modules) == Set(expectedModules)
      else { throw failure("金融迁移尚未完整提交，已暂停写入。") }
    } else {
      guard receipt.mode == "new", receipt.sourceBundleID == nil, receipt.sourceRevision == nil,
        receipt.commitMarkerPath == nil, receipt.expectedModules == nil
      else { throw failure("金融资料来源凭据无效，已暂停写入。") }
    }
    return receipt
  }
  private static let groupID = "5G96498KGJ.com.gaojixu.savings"
  private static var userHome: URL {
    if let home = getpwuid(getuid())?.pointee.pw_dir {
      return URL(fileURLWithPath: String(cString: home), isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
  }
  static var productionGroup: URL {
    userHome.appendingPathComponent("Library/Group Containers/" + groupID, isDirectory: true)
  }
  static var productionResearchDirectory: URL {
    userHome.appendingPathComponent(
      "Library/Application Support/GaoSeries/Savings/ResearchFunding", isDirectory: true)
  }
  private static func normalized(_ u: URL) -> String {
    u.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
  }
  static func isProductionDirectory(_ u: URL) -> Bool {
    let destination = normalized(u)
    let group = normalized(productionGroup)
    let localSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first?.appendingPathComponent("GaoSeries/Savings/ResearchFunding")
    return destination == group || destination.hasPrefix(group + "/")
      || destination == normalized(productionResearchDirectory)
      || localSupport.map { destination == normalized($0) } == true
  }
  private static func groupReference(_ txn: String) -> String {
    "app-group:IntegratedFinance/Migrations/" + txn + "/committed.json"
  }
  static func validateProductionReference(_ reference: String, transactionID: String) throws {
    guard UUID(uuidString: transactionID) != nil, reference == groupReference(transactionID) else {
      throw failure("正式金融资料必须绑定本应用共享容器内的事务提交凭据。")
    }
  }
  static func validateMarkerPlacement(_ marker: URL, transactionID: String, targets: [URL]) throws {
    if targets.contains(where: isProductionDirectory) || isProductionDirectory(marker) {
      let expected = productionGroup.appendingPathComponent(
        "IntegratedFinance/Migrations/" + transactionID + "/committed.json")
      guard UUID(uuidString: transactionID) != nil,
        marker.standardizedFileURL.path == expected.standardizedFileURL.path
      else { throw failure("正式迁移必须将标记提交到本应用真实 App Group 的规范路径。") }
    }
  }
  /// Portable references keep restored authorities valid when the user's home/container path changes.
  static func markerReference(for url: URL) -> String {
    let prefix = productionGroup.path + "/"
    if url.path.hasPrefix(prefix + "IntegratedFinance/Migrations/") {
      return "app-group:" + url.path.dropFirst(prefix.count)
    }
    return url.path  // Explicit isolated migration roots may be outside an app container.
  }
  static func resolveMarker(_ reference: String, transactionID: String) throws -> URL {
    if reference.hasPrefix("app-group:") {
      let expected = "IntegratedFinance/Migrations/" + transactionID + "/committed.json"
      guard UUID(uuidString: transactionID) != nil, reference == groupReference(transactionID),
        let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
      else { throw failure("金融资料共享容器尚不可用，已暂停写入。") }
      let marker = group.appendingPathComponent(expected)
      guard
        marker.resolvingSymlinksInPath().path
          == group.resolvingSymlinksInPath().appendingPathComponent(expected).path
      else { throw failure("迁移标记不能经过共享容器中的符号链接。") }
      return marker
    }
    guard reference.hasPrefix("/") else { throw failure("迁移提交凭据位置无效。") }
    return URL(fileURLWithPath: reference)
  }
  /// Called only by an explicit new-library action, never by load failure or automatic migration.
  static func createNew(module: String, directory: URL, legacyEvidence: [URL], now: Date = Date())
    throws
  {
    guard modules.contains(module) else { throw failure("金融模块不受支持。") }
    let fm = FileManager.default
    for path in legacyEvidence {
      do {
        _ = try fm.attributesOfItem(atPath: path.path)
        throw failure("发现原有金融资料，需先迁移，未创建空白库。")
      } catch let e as NSError
        where e.domain == NSCocoaErrorDomain
        && (e.code == NSFileNoSuchFileError || e.code == NSFileReadNoSuchFileError)
      { continue }
    }
    if fm.fileExists(atPath: directory.path) {
      let attributes = try fm.attributesOfItem(atPath: directory.path)
      guard attributes[.type] as? FileAttributeType == .typeDirectory,
        try fm.contentsOfDirectory(atPath: directory.path).isEmpty
      else { throw failure("目标已有资料，不能重新初始化。") }
    } else {
      try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let receipt = FinanceAuthorityReceipt(
      module: module, transactionID: UUID().uuidString, sourceFrozen: true, mode: "new",
      activatedAt: now)
    let data = try JSONEncoder().encode(receipt)
    try data.write(
      to: directory.appendingPathComponent("authority.json"), options: .withoutOverwriting)
  }
}
