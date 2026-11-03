import Combine
import Darwin
import Foundation

enum ResearchFundingAccess: Equatable { case awaitingAuthority, mayCreate, ready, protected }

/// This store knows only its own directory. It never touches the personal ledger or game store.
@MainActor final class ResearchFundingStore: ObservableObject {
  @Published private(set) var access: ResearchFundingAccess = .awaitingAuthority
  @Published private(set) var library: ResearchFundingLibrary?
  @Published var message: String?
  let directory: URL
  private var lastReadBytes: Data?
  private var transactionID: String?
  private let fm = FileManager.default
  private var file: URL { directory.appendingPathComponent("library.json") }
  private var initialized: URL { directory.appendingPathComponent("library.initialized") }
  private var assets: URL { directory.appendingPathComponent("Attachments", isDirectory: true) }
  private let newLibraryEvidence: () -> [URL]
  nonisolated static var defaultDirectory: URL {
    let override = ProcessInfo.processInfo.environment["GAOJIXU_DATA_DIR"]
    let support =
      override.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("GaoSeries/Savings", isDirectory: true)
    return support.appendingPathComponent("ResearchFunding", isDirectory: true)
  }
  init(directory: URL = ResearchFundingStore.defaultDirectory, legacyEvidence: (() -> [URL])? = nil)
  {
    self.directory = directory
    self.newLibraryEvidence =
      legacyEvidence ?? {
        if ProcessInfo.processInfo.environment["GAOJIXU_DATA_DIR"]?.isEmpty == false {
          // In an isolated data root use only the harness's sibling evidence, never the real home.
          return [directory.deletingLastPathComponent().appendingPathComponent("LegacyResearch")]
        }
        let support = FileManager.default.urls(
          for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let homes = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
          "Library", isDirectory: true)
        return [
          support.appendingPathComponent("GaoSeries/Research"),
          support.appendingPathComponent("PaperSignal"),
          support.appendingPathComponent("GaoSeriesRestore/Research"),
          homes.appendingPathComponent(
            "Group Containers/5G96498KGJ.com.academic-achievement.manager"),
          homes.appendingPathComponent("Containers/com.academic-achievement.manager"),
        ]
      }
    reload()
  }

  /// This explicit action checks for legacy installations but never reads or imports a live Research library.
  func requestNewLibrary() throws {
    guard access == .awaitingAuthority else { throw ResearchFundingError.readOnly }
    try FinanceAuthority.createNew(
      module: "research-funding", directory: directory, legacyEvidence: newLibraryEvidence())
    reload()
    try initializeNew()
  }

  func reload() {
    do {
      lastReadBytes = nil
      transactionID = nil
      library = nil
      message = nil
      guard try ResearchFundingFiles.exists(directory) else {
        access = .awaitingAuthority
        return
      }
      try ResearchFundingFiles.requireDirectory(directory)
      let names = try fm.contentsOfDirectory(atPath: directory.path)
      guard !names.isEmpty else {
        access = .awaitingAuthority
        return
      }
      let auth = try FinanceAuthority.require(module: "research-funding", directory: directory)
      if try !ResearchFundingFiles.exists(file) {
        if auth.sourceRevision == nil && Set(names) == ["authority.json"] {
          access = .mayCreate
          return
        }
        throw ResearchFundingError.unavailable
      }
      let bytes = try ResearchFundingFiles.data(at: file)
      let content = try ResearchFundingFiles.decode(bytes)
      guard content.sourceBundleID == auth.sourceBundleID,
        content.sourceRevision == auth.sourceRevision
      else { throw ResearchFundingError.readOnly }
      for asset in content.attachments { try ResearchFundingFiles.verify(asset, at: assets) }
      transactionID = auth.transactionID
      lastReadBytes = bytes
      library = content
      access = .ready
    } catch {
      access = .protected
      message = "科研资金资料或迁移凭据无法核验。原资料已保留，请检查备份。"
    }
  }

  private func locked<T>(_ body: () throws -> T) throws -> T {
    let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw ResearchFundingError.unavailable }
    defer { close(fd) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw ResearchFundingError.changed }
    defer { flock(fd, LOCK_UN) }
    return try body()
  }
  /// Root separately authorizes a genuinely new installation after checking all legacy evidence.
  /// A missing previously initialized file is not a fresh library, even with a valid new-mode receipt.
  func initializeNew() throws {
    guard access == .mayCreate else { throw ResearchFundingError.readOnly }
    try locked {
      let auth = try FinanceAuthority.require(module: "research-funding", directory: directory)
      guard auth.sourceRevision == nil, auth.sourceBundleID == nil,
        Set(try fm.contentsOfDirectory(atPath: directory.path)) == ["authority.json"]
      else { throw ResearchFundingError.readOnly }
      let bytes = try ResearchFundingFiles.encode(.empty)
      try Data("1\n".utf8).write(to: initialized, options: [.withoutOverwriting])
      try bytes.write(to: file, options: [.withoutOverwriting])
      try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      guard try ResearchFundingFiles.data(at: file) == bytes else {
        throw ResearchFundingError.unavailable
      }
    }
    reload()
    guard access == .ready else { throw ResearchFundingError.unavailable }
  }
  private func change(_ edit: (inout ResearchFundingLibrary) throws -> Void) throws {
    guard access == .ready, var next = library, let expected = lastReadBytes, let transactionID
    else { throw ResearchFundingError.readOnly }
    try locked {
      let auth = try FinanceAuthority.require(module: "research-funding", directory: directory)
      guard auth.transactionID == transactionID, auth.sourceBundleID == next.sourceBundleID,
        auth.sourceRevision == next.sourceRevision,
        try ResearchFundingFiles.data(at: file) == expected
      else { throw ResearchFundingError.changed }
      for a in next.attachments { try ResearchFundingFiles.verify(a, at: assets) }
      try edit(&next)
      let bytes = try ResearchFundingFiles.encode(next)
      try bytes.write(to: file, options: .atomic)
      try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      guard try ResearchFundingFiles.data(at: file) == bytes else {
        throw ResearchFundingError.unavailable
      }
      lastReadBytes = bytes
      library = next
    }
  }
  @discardableResult func save(
    id: String?, name: String, amount: Double, year: Int, months: [Int], receivingAccount: String,
    currency: String?, projectReference: String? = nil
  ) throws -> String {
    guard amount > 0, !months.isEmpty, id != nil || currency != nil,
      !receivingAccount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw ResearchFundingError.invalidRecord }
    let now = ResearchFundingFormat.timestamp()
    let key = id ?? UUID().uuidString
    try change { lib in
      let index = lib.fundingRecords.firstIndex(where: { $0.id == key })
      guard id == nil || index != nil else { throw ResearchFundingError.changed }
      let item = ResearchFundingRecord(
        id: key, name: name.trimmingCharacters(in: .whitespacesAndNewlines), amount: amount,
        year: year, months: months.sorted(),
        receivingAccount: receivingAccount.trimmingCharacters(in: .whitespacesAndNewlines),
        createdAt: index.map { lib.fundingRecords[$0].createdAt } ?? now, updatedAt: now,
        currency: currency, projectReference: projectReference)
      try item.validate()
      if let index {
        lib.fundingRecords[index] = item
      } else {
        lib.fundingRecords.insert(item, at: 0)
      }
    }
    return key
  }
  func moveToTrash(_ id: String) throws {
    try change { lib in
      guard let i = lib.fundingRecords.firstIndex(where: { $0.id == id }) else {
        throw ResearchFundingError.changed
      }
      let record = lib.fundingRecords.remove(at: i)
      lib.trashItems.insert(
        .init(
          id: UUID().uuidString, kind: "funding", title: record.name,
          deletedAt: ResearchFundingFormat.timestamp(), funding: record), at: 0)
    }
  }
  func restore(_ id: String) throws {
    try change { lib in
      guard let i = lib.trashItems.firstIndex(where: { $0.id == id }) else {
        throw ResearchFundingError.changed
      }
      let record = lib.trashItems[i].funding
      guard !lib.fundingRecords.contains(where: { $0.id == record.id }) else {
        throw ResearchFundingError.conflict
      }
      lib.trashItems.remove(at: i)
      lib.fundingRecords.append(record)
    }
  }
  func permanentlyDelete(_ id: String) throws {
    var removed: [ResearchFundingAttachment] = []
    try change { lib in
      guard let i = lib.trashItems.firstIndex(where: { $0.id == id }) else {
        throw ResearchFundingError.changed
      }
      let recordID = lib.trashItems.remove(at: i).funding.id
      removed = lib.attachments.filter { $0.fundingID == recordID }
      lib.attachments.removeAll { $0.fundingID == recordID }
    }
    // Delete only individually verified, now-unreferenced copies after a durable library write.
    for a in removed {
      do {
        try ResearchFundingFiles.verify(a, at: assets)
        try fm.removeItem(at: assets.appendingPathComponent(a.relativePath))
      } catch { message = "记录已删除，无法安全清理的附件副本仍然保留。" }
    }
  }
  func attachmentURL(_ id: String) throws -> URL {
    guard access == .ready, let a = library?.attachments.first(where: { $0.id == id }) else {
      throw ResearchFundingError.unavailable
    }
    let auth = try FinanceAuthority.require(module: "research-funding", directory: directory)
    guard auth.transactionID == transactionID, auth.sourceRevision == library?.sourceRevision,
      try ResearchFundingFiles.data(at: file) == lastReadBytes
    else { throw ResearchFundingError.changed }
    try ResearchFundingFiles.verify(a, at: assets)
    return assets.appendingPathComponent(a.relativePath)
  }
}
