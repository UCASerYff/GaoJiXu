import CryptoKit
import Darwin
import Foundation

/// Filesystem operations shared by the isolated migration stage and target-only repository.
/// openat with O_NOFOLLOW on each path component avoids resolving a manifest through symlinks.
enum ResearchFundingFiles {
  static func exists(_ url: URL) throws -> Bool {
    var st = stat()
    if lstat(url.path, &st) == 0 { return true }
    if errno == ENOENT { return false }
    throw ResearchFundingError.unavailable
  }
  static func requireDirectory(_ url: URL) throws {
    var st = stat()
    guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
      throw ResearchFundingError.unavailable
    }
  }
  static func openRegular(parent: URL, relative: String) throws -> FileHandle {
    guard ResearchFundingFormat.safeRelative(relative) else {
      throw ResearchFundingError.unsafeAttachment
    }
    let pieces = relative.split(separator: "/").map(String.init)
    var dir = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard dir >= 0 else { throw ResearchFundingError.unavailable }
    defer { close(dir) }
    for piece in pieces.dropLast() {
      let next = openat(dir, piece, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard next >= 0 else { throw ResearchFundingError.unsafeAttachment }
      close(dir)
      dir = next
    }
    let fd = openat(dir, pieces.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw ResearchFundingError.unavailable }
    var st = stat()
    guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1 else {
      close(fd)
      throw ResearchFundingError.unsafeAttachment
    }
    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  }
  static func data(at url: URL) throws -> Data {
    let file = try openRegular(
      parent: url.deletingLastPathComponent(), relative: url.lastPathComponent)
    defer { try? file.close() }
    let limit = 128 * 1024 * 1024
    var result = Data()
    while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty {
      guard result.count + chunk.count <= limit else { throw ResearchFundingError.invalidPackage }
      result.append(chunk)
    }
    return result
  }
  static func verify(
    _ asset: ResearchFundingAttachment, at root: URL, copyingTo destination: URL? = nil
  ) throws {
    let input = try openRegular(parent: root, relative: asset.relativePath)
    defer { try? input.close() }
    var writer: FileHandle?
    if let destination {
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      let fd = Darwin.open(
        destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard fd >= 0 else { throw ResearchFundingError.unsafeAttachment }
      writer = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    defer { try? writer?.close() }
    var hash = SHA256()
    var size: Int64 = 0
    while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
      size += Int64(data.count)
      guard size <= asset.byteCount else { throw ResearchFundingError.unsafeAttachment }
      hash.update(data: data)
      try writer?.write(contentsOf: data)
    }
    guard size == asset.byteCount,
      hash.finalize().map({ String(format: "%02x", $0) }).joined() == asset.sha256
    else { throw ResearchFundingError.unsafeAttachment }
    try writer?.synchronize()
  }
  static func encode(_ library: ResearchFundingLibrary) throws -> Data {
    try library.validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(library)
  }

  /// Never let Codable silently discard new, unrecognized target fields on an edit.
  static func decode(_ bytes: Data) throws -> ResearchFundingLibrary {
    var keys = ResearchFundingUniqueKeys(bytes)
    try keys.validate()
    let recordKeys: Set<String> = [
      "id", "name", "amount", "year", "months", "receivingAccount", "createdAt", "updatedAt",
      "currency", "projectReference",
    ]
    let trashKeys: Set<String> = [
      "id", "kind", "title", "deletedAt", "funding", "originalEnvelope",
    ]
    let assetKeys: Set<String> = ["id", "fundingID", "relativePath", "byteCount", "sha256"]
    guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
      Set(object.keys).isSubset(of: [
        "schemaVersion", "sourceBundleID", "sourceRevision", "fundingRecords", "trashItems",
        "attachments",
      ]),
      let records = object["fundingRecords"] as? [[String: Any]],
      records.allSatisfy({ Set($0.keys).isSubset(of: recordKeys) }),
      let trash = object["trashItems"] as? [[String: Any]],
      trash.allSatisfy({ item in
        guard let nested = item["funding"] as? [String: Any] else { return false }
        return Set(item.keys).isSubset(of: trashKeys) && Set(nested.keys).isSubset(of: recordKeys)
      }), let assets = object["attachments"] as? [[String: Any]],
      assets.allSatisfy({ Set($0.keys) == assetKeys })
    else { throw ResearchFundingError.schema }
    let library = try JSONDecoder().decode(ResearchFundingLibrary.self, from: bytes)
    try library.validate()
    return library
  }
}

enum ResearchFundingImport {
  struct Result {
    let sourceRevision: String
    let packageSHA256: String
    let activeCount: Int
    let trashCount: Int
    let attachmentCount: Int
    let idMap: [String: String]
  }
  private static let fields: Set<String> = [
    "id", "name", "amount", "year", "months", "receivingAccount", "createdAt", "updatedAt",
  ]
  private static func raw(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  }
  private static func record(_ value: [String: Any]) throws -> ResearchFundingRecord {
    // Decode only the known source shape: Codable alone silently drops unknown future relationships.
    guard Set(value.keys) == fields else { throw ResearchFundingError.invalidRecord }
    let result = try JSONDecoder().decode(ResearchFundingRecord.self, from: raw(value))
    try result.validate()
    return result
  }
  /// Stage only. Root owns the transaction, freeze, readback, and one-time authority switch.
  static func stage(
    packageURL: URL, into stagingDirectory: URL, expectedSourceRevision: String,
    expectedPackageSHA256: String? = nil
  )
    throws -> Result
  {
    let source = packageURL.deletingLastPathComponent().standardizedFileURL
    let dst = stagingDirectory.standardizedFileURL
    let sourcePath = source.resolvingSymlinksInPath().path
    let dstPath = dst.resolvingSymlinksInPath().path
    guard sourcePath != dstPath, !sourcePath.hasPrefix(dstPath + "/"),
      !dstPath.hasPrefix(sourcePath + "/")
    else { throw ResearchFundingError.invalidStage }
    let data = try ResearchFundingFiles.data(at: packageURL)
    let packageSHA = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    if let expectedPackageSHA256, expectedPackageSHA256 != packageSHA {
      throw ResearchFundingError.invalidPackage
    }
    var keys = ResearchFundingUniqueKeys(data)
    try keys.validate()
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(root.keys) == [
        "format", "schemaVersion", "sourceBundleID", "sourceLibrarySchema", "sourceRevision",
        "exportedAt", "fundingRecords", "trashItems", "relatedProjects", "attachments",
      ],
      root["format"] as? String == "gaoseries.research-funding",
      root["sourceBundleID"] as? String == ResearchFundingLibrary.sourceID,
      ResearchFundingFormat.digest(expectedSourceRevision),
      root["sourceRevision"] as? String == expectedSourceRevision,
      let date = root["exportedAt"] as? String, ResearchFundingFormat.date(date) != nil,
      let records = root["fundingRecords"] as? [[String: Any]],
      let deleted = root["trashItems"] as? [[String: Any]],
      let projects = root["relatedProjects"] as? [Any], projects.isEmpty,
      let attachments = root["attachments"] as? [[String: Any]]
    else { throw ResearchFundingError.invalidPackage }
    struct Versions: Decodable {
      var schemaVersion: Int
      var sourceLibrarySchema: Int
    }
    let versions = try JSONDecoder().decode(Versions.self, from: data)
    guard versions.schemaVersion == 1, versions.sourceLibrarySchema == 32 else {
      throw ResearchFundingError.schema
    }
    let active = try records.map(record)
    let trash: [ResearchFundingTrashItem] = try deleted.map { rawItem in
      guard rawItem["originalEnvelope"] == nil, rawItem["kind"] as? String == "funding",
        let body = rawItem["funding"] as? [String: Any]
      else { throw ResearchFundingError.invalidRecord }
      for key in [
        "paper", "work", "project", "documentFolder", "certificate", "attachment", "parentID",
      ] {
        if let relation = rawItem[key], !(relation is NSNull) {
          throw ResearchFundingError.invalidRecord
        }
      }
      if let docs = rawItem["documents"] {
        guard let items = docs as? [Any], items.isEmpty else {
          throw ResearchFundingError.invalidRecord
        }
      }
      _ = try record(body)
      let bytes = try raw(rawItem)
      var item = try JSONDecoder().decode(ResearchFundingTrashItem.self, from: bytes)
      // Retain every source wrapper field and source timestamp; never resolve unknown metadata as a path.
      item.originalEnvelope = bytes
      return item
    }
    let assets: [ResearchFundingAttachment] = try attachments.map { value in
      guard Set(value.keys) == ["id", "fundingID", "relativePath", "byteCount", "sha256"] else {
        throw ResearchFundingError.unsafeAttachment
      }
      return try JSONDecoder().decode(ResearchFundingAttachment.self, from: raw(value))
    }
    let library = ResearchFundingLibrary(
      schemaVersion: 1, sourceBundleID: ResearchFundingLibrary.sourceID,
      sourceRevision: expectedSourceRevision,
      fundingRecords: active, trashItems: trash, attachments: assets)
    let bytes = try ResearchFundingFiles.encode(library)
    let fm = FileManager.default
    if try ResearchFundingFiles.exists(dst) {
      try ResearchFundingFiles.requireDirectory(dst)
      guard try fm.contentsOfDirectory(atPath: dst.path).isEmpty else {
        throw ResearchFundingError.invalidStage
      }
    } else {
      try fm.createDirectory(
        at: dst, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    // Never erase an existing staging root on error. Its owning transaction can inspect/retry with a fresh stage.
    let assetRoot = dst.appendingPathComponent("Attachments", isDirectory: true)
    for asset in assets {
      try ResearchFundingFiles.verify(
        asset, at: source, copyingTo: assetRoot.appendingPathComponent(asset.relativePath))
      try ResearchFundingFiles.verify(asset, at: assetRoot)
    }
    let file = dst.appendingPathComponent("library.json")
    try bytes.write(to: file, options: [.withoutOverwriting])
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let staged = try ResearchFundingFiles.data(at: file)
    guard staged == bytes, try ResearchFundingFiles.decode(staged) == library else {
      throw ResearchFundingError.invalidStage
    }
    var map: [String: String] = [:]
    for id in (active + trash.map(\.funding)).map(\.id) {
      map["\(ResearchFundingLibrary.sourceID)|funding|\(id)"] = id
    }
    for item in trash {
      map["\(ResearchFundingLibrary.sourceID)|fundingTrash|\(item.id)"] = item.id
    }
    return Result(
      sourceRevision: expectedSourceRevision, packageSHA256: packageSHA, activeCount: active.count,
      trashCount: trash.count,
      attachmentCount: assets.count, idMap: map)
  }
}

/// JSON decoders may silently keep one of two identically named keys. Preserve fail-closed
/// semantics even when duplicates are escaped differently (e.g. "id" and "\\u0069d").
private struct ResearchFundingUniqueKeys {
  let bytes: [UInt8]
  var i = 0
  init(_ data: Data) { bytes = Array(data) }
  mutating func skip() { while i < bytes.count, [9, 10, 13, 32].contains(bytes[i]) { i += 1 } }
  mutating func take(_ char: UInt8) -> Bool {
    skip()
    guard i < bytes.count, bytes[i] == char else { return false }
    i += 1
    return true
  }
  mutating func string() throws -> Range<Int> {
    skip()
    let start = i
    guard take(34) else { throw ResearchFundingError.invalidPackage }
    while i < bytes.count {
      let c = bytes[i]
      i += 1
      if c == 34 { return start..<i }
      if c == 92 { i += 1 }
    }
    throw ResearchFundingError.invalidPackage
  }
  mutating func value(_ depth: Int) throws {
    skip()
    guard depth < 128, i < bytes.count else { throw ResearchFundingError.invalidPackage }
    if take(123) {
      var seen = Set<String>()
      if take(125) { return }
      repeat {
        let range = try string()
        let key = try JSONDecoder().decode(String.self, from: Data(bytes[range]))
        guard seen.insert(key).inserted, take(58) else { throw ResearchFundingError.invalidPackage }
        try value(depth + 1)
      } while take(44)
      guard take(125) else { throw ResearchFundingError.invalidPackage }
    } else if take(91) {
      if take(93) { return }
      repeat { try value(depth + 1) } while take(44)
      guard take(93) else { throw ResearchFundingError.invalidPackage }
    } else if bytes[i] == 34 {
      _ = try string()
    } else {
      let start = i
      while i < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[i]) { i += 1 }
      guard i > start else { throw ResearchFundingError.invalidPackage }
    }
  }
  mutating func validate() throws {
    try value(0)
    skip()
    guard i == bytes.count else { throw ResearchFundingError.invalidPackage }
  }
}
