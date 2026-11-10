import CryptoKit
import Darwin
import Foundation

/// Offline monthly cutover. Nothing in this type discovers live sources or runs on app startup.
enum FinanceIntegrationMigration {
  struct MonthlyInput: Codable, Equatable {
    let snapshotPath: String
    let artifactSHA256: String
    let sourceRevision: String
  }
  struct Request: Codable, Equatable {
    let schemaVersion: Int, txnID: String, writersFrozen: Bool, targetWritersStopped: Bool
    let monthly: MonthlyInput?
    let targetMonthlyDirectory: String, journalDirectory: String, commitMarkerPath: String
  }
  struct Report: Codable {
    let transactionID: String, modules: [String], alreadyCommitted: Bool
    let counts: [String: [String: Int]], verifiedArtifactSHA256: [String: String],
      sourceRevisions: [String: String]
  }
  struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
  }
  private struct Metadata: Codable, Equatable { let bytes: UInt64, sha256: String }
  private struct Manifest: Codable, Equatable {
    var files: [String: Metadata] = [:]
    var directories: [String] = []
  }
  private struct Prepared: Codable {
    let stagePath: String, destinationPath: String, manifest: Manifest,
      sourceArchiveManifest: Manifest
    let idMap: [String: String], counts: [String: Int]
  }
  private struct StageIdentity: Codable, Equatable {
    let device: Int64, inode: UInt64, born: Int64, nanos: Int64
    init(_ st: stat) {
      device = Int64(st.st_dev)
      inode = UInt64(st.st_ino)
      born = Int64(st.st_birthtimespec.tv_sec)
      nanos = Int64(st.st_birthtimespec.tv_nsec)
    }
  }
  private struct Journal: Codable {
    let schemaVersion: Int, request: Request, startedAt: Date
    var phase: String, prepared: [String: Prepared], promoted: [String]
    // Record a stage location before creating it. A killed process never leaves an unaccounted directory beside the live destination.
    var stageAttempts: [String: [String]] = [:]
    // Persist before writing finance bytes. An intent path alone does not prove a surviving directory belongs to this process.
    var stageIdentities: [String: StageIdentity]? = nil
  }
  private struct Module {
    let name: String, bundle: String, input: URL, artifact: String, revision: String, target: URL
    var archiveName: String { "snapshot.sqlite" }
  }
  private static let fm = FileManager.default
  private static func check(_ test: Bool, _ message: String) throws {
    if !test { throw Failure(message) }
  }
  private static func url(_ path: String, inspect: Bool = true) throws -> URL {
    try check(
      path.hasPrefix("/") && path != "/" && !path.utf8.contains(0) && !path.hasSuffix("/")
        && !path.contains("//")
        && !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }), "需要规范的绝对文件路径。")
    let u = URL(fileURLWithPath: path)
    if !inspect { return u }
    var current = URL(fileURLWithPath: "/", isDirectory: true)
    for component in u.pathComponents.dropFirst() {
      current.appendPathComponent(component)
      if let st = try status(current) {
        try check((st.st_mode & S_IFMT) != S_IFLNK, "迁移路径不能通过符号链接。")
      }
    }
    return u
  }
  private static func status(_ u: URL) throws -> stat? {
    var st = stat()
    if lstat(u.path, &st) == 0 { return st }
    if errno == ENOENT { return nil }
    throw Failure("无法检查迁移路径（errno \(errno)）。")
  }
  private static func requireDirectory(_ url: URL) throws {
    guard let st = try status(url), (st.st_mode & S_IFMT) == S_IFDIR else {
      throw Failure("迁移目录不存在或不是普通目录。")
    }
  }
  private static func validDigest(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy {
      (48...57).contains($0) || (97...102).contains($0)
    }
  }
  private static func isInside(_ child: URL, _ directory: URL) -> Bool {
    let a = child.path.precomposedStringWithCanonicalMapping.lowercased()
    let b = directory.path.precomposedStringWithCanonicalMapping.lowercased()
    return a == b || a.hasPrefix(b + "/")
  }
  private static func makeDir(_ u: URL) throws {
    if let st = try status(u) {
      try check((st.st_mode & S_IFMT) == S_IFDIR, "期望的迁移目录不是目录。")
      return
    }
    try makeDir(u.deletingLastPathComponent())
    if mkdir(u.path, 0o700) != 0 {
      guard errno == EEXIST, let st = try status(u), (st.st_mode & S_IFMT) == S_IFDIR else {
        throw Failure("无法创建受保护的迁移目录。")
      }
    }
  }
  private static func temporaryDir(_ parent: URL, _ prefix: String) throws -> URL {
    try makeDir(parent)
    let out = parent.appendingPathComponent(prefix + UUID().uuidString + ".noindex")
    try check(mkdir(out.path, 0o700) == 0, "不能创建独占暂存目录。")
    return out
  }
  private static func reader(_ u: URL) throws -> FileHandle {
    let fd = Darwin.open(u.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard fd >= 0 else { throw Failure("必需的文件无法读取。") }
    var st = stat()
    guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1 else {
      close(fd)
      throw Failure("文件不是独立普通文件。")
    }
    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  }
  private static func bytes(_ u: URL) throws -> Data {
    let f = try reader(u)
    defer { try? f.close() }
    return try f.readToEnd() ?? Data()
  }
  private static func exclusiveWriter(_ u: URL) throws -> FileHandle {
    let fd = Darwin.open(u.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw Failure("不能独占创建文件；已有内容不会被覆盖。") }
    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  }
  @discardableResult private static func digest(_ u: URL, copyTo target: URL? = nil) throws
    -> Metadata
  {
    let f = try reader(u)
    defer { try? f.close() }
    let w = try target.map(exclusiveWriter)
    defer { try? w?.close() }
    var hash = SHA256()
    var count: UInt64 = 0
    while let b = try f.read(upToCount: 1 << 20), !b.isEmpty {
      hash.update(data: b)
      count += UInt64(b.count)
      try w?.write(contentsOf: b)
    }
    try w?.synchronize()
    return .init(bytes: count, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
  }
  private static func manifest(_ root: URL) throws -> Manifest {
    var result = Manifest()
    func descend(_ d: URL, _ prefix: String) throws {
      try requireDirectory(d)
      for name in try fm.contentsOfDirectory(atPath: d.path).sorted() {
        let u = d.appendingPathComponent(name)
        let k = prefix + name
        guard let st = try status(u) else { throw Failure("核验时有文件消失。") }
        switch st.st_mode & S_IFMT {
        case S_IFDIR:
          result.directories.append(k)
          try descend(u, k + "/")
        case S_IFREG: result.files[k] = try digest(u)
        default: throw Failure("快照目录有不受支持的文件类型。")
        }
      }
    }
    try descend(root, "")
    return result
  }
  private static func syncParent(_ u: URL) throws {
    let fd = Darwin.open(
      u.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw Failure("无法同步目录。") }
    defer { close(fd) }
    if fsync(fd) != 0 && errno != EINVAL && errno != ENOTSUP { throw Failure("目录同步失败。") }
  }
  private static func promote(_ from: URL, _ to: URL) throws {
    guard renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 else {
      throw Failure("目标已存在或不支持同卷独占重命名（errno \(errno)），未覆盖。")
    }
    try syncParent(to)
  }
  private static func write<T: Encodable>(_ value: T, _ u: URL, replace: Bool = false) throws {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys, .prettyPrinted]
    let data = try e.encode(value)
    let tmp = u.deletingLastPathComponent().appendingPathComponent(
      ".txn-" + UUID().uuidString + ".tmp")
    let h = try exclusiveWriter(tmp)
    defer {
      try? h.close()
      try? fm.removeItem(at: tmp)
    }
    try h.write(contentsOf: data)
    try h.synchronize()
    try h.close()
    if replace {
      guard let st = try status(u), (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1,
        rename(tmp.path, u.path) == 0
      else { throw Failure("事务日志更新失败。") }
      try syncParent(u)
    } else {
      try promote(tmp, u)
    }
  }
  private static func decode<T: Decodable>(_ type: T.Type, _ u: URL) throws -> T {
    try JSONDecoder().decode(type, from: bytes(u))
  }
  private static func setup(_ r: Request) throws -> ([Module], URL, URL) {
    try check(
      r.schemaVersion == 1 && UUID(uuidString: r.txnID) != nil && r.writersFrozen
        && r.targetWritersStopped, "需要 schema 1、有效事务 UUID，并先冻结所有源/目标写入者。")
    let monthly = try url(r.targetMonthlyDirectory)
    let journal = try url(r.journalDirectory)
    let marker = try url(r.commitMarkerPath)
    let archivePath = journal.path.lowercased() + "/"
    try check(
      !archivePath.contains("/5g96498kgj.com.gaojixu.savings/")
        && !archivePath.contains("/application support/gaoseries/savings/")
        && !archivePath.contains(".app/contents/"), "含原始资料的事务归档必须放在非生产的私有位置。")
    let dirs = [monthly, journal]
    for i in dirs.indices {
      for j in dirs.indices where j != i {
        try check(!isInside(dirs[i], dirs[j]), "业务目录与归档事务目录不能重叠。")
      }
    }
    try check(!isInside(marker, monthly) && !isInside(monthly, marker), "提交标记不能在业务目录内。")
    try check(
      !isInside(journal, marker)
        && (!isInside(marker, journal)
          || (marker.deletingLastPathComponent().path == journal.path
            && marker.lastPathComponent == "committed.json")),
      "提交标记与事务内部文件冲突。")
    let reference = FinanceAuthority.markerReference(for: marker)
    if reference.hasPrefix("app-group:") {
      try check(
        reference == "app-group:IntegratedFinance/Migrations/\(r.txnID)/committed.json",
        "共享提交标记的路径与事务号不一致。")
    }
    var modules: [Module] = []
    if let m = r.monthly {
      modules.append(
        .init(
          name: "monthly", bundle: "com.gaoseries.GaoYueGong",
          input: try url(m.snapshotPath, inspect: false), artifact: m.artifactSHA256,
          revision: m.sourceRevision, target: monthly))
    }
    try check(!modules.isEmpty, "该事务没有明确输入模块。")
    try FinanceAuthority.validateMarkerPlacement(
      marker, transactionID: r.txnID, targets: modules.map(\.target))
    for m in modules {
      try check(validDigest(m.artifact) && validDigest(m.revision), "输入摘要或来源修订格式无效。")
      for out in dirs + [marker] {
        try check(!isInside(m.input, out) && !isInside(out, m.input), "输入与输出路径重叠。")
      }
    }
    return (modules, journal, marker)
  }
  private static func verifyInput(_ m: Module) throws {
    _ = try url(m.input.path)
    for suffix in ["-wal", "-journal", "-shm"] {
      try check(
        try status(URL(fileURLWithPath: m.input.path + suffix)) == nil,
        "需要已合并 WAL 的独立 SQLite 一致快照，不能直接截取活动数据库。")
    }
    try check(try digest(m.input).sha256 == m.artifact, "输入文件实际 SHA-256 不符。")
  }
  private static func archive(_ m: Module, _ journal: URL) throws -> (URL, Manifest) {
    let root = journal.appendingPathComponent("sources")
    let final = root.appendingPathComponent(m.name)
    let file = final.appendingPathComponent(m.archiveName)
    try makeDir(root)
    let initial = try digest(m.input)
    try check(initial.sha256 == m.artifact, "归档前输入已变化。")
    if try status(final) == nil {
      let tmp = try temporaryDir(root, ".archive-" + m.name + "-")
      defer { try? fm.removeItem(at: tmp) }
      try check(
        try digest(m.input, copyTo: tmp.appendingPathComponent(m.archiveName)) == initial,
        "归档期间输入已变化。")
      try promote(tmp, final)
    }
    try requireDirectory(final)
    let stat = try manifest(final)
    try check(
      Set(stat.files.keys) == [m.archiveName] && stat.files[m.archiveName] == initial,
      "源归档文件清单不一致。")
    try check(try digest(m.input) == initial, "归档后冻结输入已变化。")
    return (file, stat)
  }
  private static func authority(_ m: Module, _ j: Journal, _ marker: URL) -> FinanceAuthorityReceipt
  {
    .init(
      module: m.name, transactionID: j.request.txnID, sourceBundleID: m.bundle,
      sourceRevision: m.revision, sourceFrozen: true, mode: "migrated", activatedAt: j.startedAt,
      commitMarkerPath: FinanceAuthority.markerReference(for: marker),
      expectedModules: [j.request.monthly == nil ? nil : "monthly"].compactMap { $0 })
  }
  private static func monthlyData(_ u: URL) throws -> MonthlyFinanceState {
    let conn = try MonthlyFinanceConnection(existing: u, readOnly: true)
    try conn.verifySnapshot()
    let s = try JSONDecoder().decode(MonthlyFinanceState.self, from: conn.payload())
    try MonthlyFinanceEngine.validate(s)
    return s
  }
  private static func prepare(
    _ m: Module, _ j: Journal, _ marker: URL, _ archived: URL, _ archiveManifest: Manifest,
    at stage: URL, register: (StageIdentity) throws -> Void
  ) throws -> Prepared {
    try makeDir(stage.deletingLastPathComponent())
    try check(mkdir(stage.path, 0o700) == 0, "无法创建已登记的独占暂存目录。")
    var complete = false
    defer { if !complete { try? fm.removeItem(at: stage) } }
    guard let identity = try status(stage) else { throw Failure("暂存目录消失。") }
    try register(StageIdentity(identity))
    let x = try MonthlyFinanceMigration.stage(snapshotURL: archived, into: stage)
    try check(x.sourceSHA256 == m.revision, "月供业务 BLOB 修订不符。")
    let counts = x.counts
    let s = try monthlyData(x.databaseURL)
    var mapping: [String: String] = [:]
    func add(_ type: String, _ id: String) { mapping[m.bundle + "|" + type + "|" + id] = id }
    for a in s.subscriptions {
      add("subscription", a.id.uuidString)
      for p in a.plans { add("plan|" + a.id.uuidString, p.id.uuidString) }
    }
    for a in s.payments { add("payment", a.id) }
    for a in s.claims { add("claim", a.id) }
    for a in s.reviews { add("review", a.id) }
    for a in s.events { add("event", a.id.uuidString) }
    for a in s.benefits { add("benefit", a.id.uuidString) }
    for id in s.legacyRewardIDs { add("legacyRewardID", id) }
    for id in s.tombstones { add("tombstone", id) }
    try write(authority(m, j, marker), stage.appendingPathComponent("authority.json"))
    let contents = try manifest(stage)
    for name in contents.files.keys {
      let u = stage.appendingPathComponent(name)
      let fd = Darwin.open(u.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
      guard fd >= 0 else { throw Failure("无法同步暂存文件。") }
      let rc = fsync(fd)
      close(fd)
      try check(rc == 0, "暂存文件同步失败。")
      try syncParent(u)
    }
    for name in contents.directories.reversed() {
      try syncParent(stage.appendingPathComponent(name))
    }
    try syncParent(stage)
    let result = Prepared(
      stagePath: stage.path, destinationPath: m.target.path, manifest: contents,
      sourceArchiveManifest: archiveManifest, idMap: mapping, counts: counts)
    complete = true
    return result
  }
  private static func stageURL(_ p: Prepared, _ m: Module, _ txn: String) throws -> URL {
    let s = try url(p.stagePath)
    try check(
      p.destinationPath == m.target.path
        && s.deletingLastPathComponent() == m.target.deletingLastPathComponent()
        && s.lastPathComponent.hasPrefix(".gaojixu-" + txn + "-" + m.name + "-")
        && s.pathExtension == "noindex", "事务日志暂存路径与目标不符。 ")
    return s
  }
  /// A real process kill bypasses prepare()'s defer. Move the exact registered inode out of the
  /// production parent before creating another attempt; never discard an unidentified directory.
  private static func recoverAbandoned(_ j: Journal, _ m: Module, journalRoot: URL) throws {
    for path in j.stageAttempts[m.name] ?? [] where path != j.prepared[m.name]?.stagePath {
      let old = try url(path)
      let prefix = ".gaojixu-" + j.request.txnID + "-" + m.name + "-"
      let name = old.deletingPathExtension().lastPathComponent
      try check(
        old.deletingLastPathComponent().path == m.target.deletingLastPathComponent().path
          && old.pathExtension == "noindex" && name.hasPrefix(prefix)
          && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil, "日志中的中断暂存路径无效。")
      guard let s = try status(old) else { continue }
      try check((s.st_mode & S_IFMT) == S_IFDIR && s.st_uid == getuid(), "中断暂存的目录类型或所有者变化，未移动。")
      guard let pinned = j.stageIdentities?[path], pinned == StageIdentity(s) else {
        // A kill immediately after mkdir can leave an empty, unproven directory: it contains no financial data.
        try check(
          try fm.contentsOfDirectory(atPath: old.path).isEmpty, "中断暂存无法证明归属且有内容；请核对并安全归档，未触碰。")
        continue
      }
      let recovery = journalRoot.appendingPathComponent("interrupted-stages")
      let final = recovery.appendingPathComponent(old.lastPathComponent)
      try makeDir(recovery)
      let before = try manifest(old)
      if try status(final) == nil, let dest = try status(recovery), s.st_dev == dest.st_dev {
        try promote(old, final)
        try syncParent(old)
        continue
      }
      // Cross-volume journal: publish a verified private recovery copy first. A second interruption
      // while unlinking leaves a matching subset. Unlisted or modified files are never recursively deleted.
      if try status(final) == nil {
        let tmp = try temporaryDir(recovery, ".recovery-")
        defer { try? fm.removeItem(at: tmp) }
        for sub in before.directories { try makeDir(tmp.appendingPathComponent(sub)) }
        for (key, digestBefore) in before.files {
          let dst = tmp.appendingPathComponent(key)
          try check(
            try digest(old.appendingPathComponent(key), copyTo: dst) == digestBefore, "中断暂存复制时发生变化。"
          )
          try syncParent(dst)
        }
        for sub in before.directories.reversed() { try syncParent(tmp.appendingPathComponent(sub)) }
        try check(try manifest(tmp) == before && manifest(old) == before, "中断暂存的恢复副本校验失败。")
        try promote(tmp, final)
      }
      let archive = try manifest(final)
      try check(
        before.files.allSatisfy { archive.files[$0.key] == $0.value }
          && Set(before.directories).isSubset(of: archive.directories), "中断暂存和已归档副本不一致；保留两份。")
      for (key, metadata) in before.files {
        let file = old.appendingPathComponent(key)
        try check(try digest(file) == metadata && unlink(file.path) == 0, "不能安全清理已核验的中断暂存文件。")
      }
      for sub in before.directories.reversed() {
        try check(rmdir(old.appendingPathComponent(sub).path) == 0, "中断目录有未归档内容，已保留。")
      }
      try check(rmdir(old.path) == 0, "中断目录有新增内容，已保留。")
      try syncParent(old)
    }
  }
  private static func validateCurrent(_ m: Module, _ j: Journal, _ marker: URL) throws {
    try requireDirectory(m.target)
    try check(
      try decode(FinanceAuthorityReceipt.self, m.target.appendingPathComponent("authority.json"))
        == authority(m, j, marker), "已提交目录的权威凭据不一致。")
    _ = try monthlyData(m.target.appendingPathComponent("monthly.sqlite"))
  }
  static func run(_ request: Request, checkpoint: ((String) throws -> Void)? = nil) throws -> Report
  {
    let (mods, dir, marker) = try setup(request)
    let names = mods.map(\.name)
    let file = dir.appendingPathComponent("journal.json")
    if try status(dir) == nil {
      for m in mods { try verifyInput(m) }
      try check(try status(marker) == nil, "存在没有本事务日志的提交标记。")
      for m in mods { try check(try status(m.target) == nil, "目标已存在，不能初始化迁移事务。") }
      let tmp = try temporaryDir(dir.deletingLastPathComponent(), ".finance-journal-init-")
      defer { try? fm.removeItem(at: tmp) }
      try write(
        Journal(
          schemaVersion: 1, request: request, startedAt: Date(), phase: "preparing", prepared: [:],
          promoted: []), tmp.appendingPathComponent("journal.json"))
      try promote(tmp, dir)
    }
    try requireDirectory(dir)
    let lock = Darwin.open(dir.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard lock >= 0 else { throw Failure("无法锁定迁移日志。") }
    defer { close(lock) }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw Failure("另一进程正在处理相同事务。") }
    defer { flock(lock, LOCK_UN) }
    var j = try decode(Journal.self, file)
    try check(
      j.schemaVersion == 1 && j.request == request
        && ["preparing", "prepared", "promoting", "committed"].contains(j.phase)
        && Set(j.prepared.keys).isSubset(of: names) && Set(j.promoted).isSubset(of: names),
      "事务号、来源、目标或日志状态不一致。")
    let markerExists = try status(marker) != nil
    if markerExists || j.phase == "committed" {
      try check(
        markerExists && Set(j.prepared.keys) == Set(names)
          && ["promoting", "committed"].contains(j.phase), "提交凭据缺失或事务未准备完整。")
      let c = try decode(FinanceCommitMarker.self, marker)
      try check(
        c
          == FinanceCommitMarker(
            transactionID: request.txnID, modules: names, committedAt: c.committedAt)
          && c.committedAt.timeIntervalSince1970.isFinite, "提交凭据无效。")
      for m in mods {
        guard let p = j.prepared[m.name] else { throw Failure("缺少已迁移模块清单。") }
        _ = try stageURL(p, m, request.txnID)
        let archiveDir = dir.appendingPathComponent("sources/" + m.name)
        try check(
          try manifest(archiveDir) == p.sourceArchiveManifest
            && p.sourceArchiveManifest.files[m.archiveName]?.sha256 == m.artifact, "归档资料缺失或已改变。")
        try validateCurrent(m, j, marker)
      }
      for m in mods { try recoverAbandoned(j, m, journalRoot: dir) }
      if j.phase != "committed" {
        j.phase = "committed"
        j.promoted = names
        try write(j, file, replace: true)
      }
      return .init(
        transactionID: request.txnID, modules: names, alreadyCommitted: true,
        counts: j.prepared.mapValues(\.counts),
        verifiedArtifactSHA256: Dictionary(
          uniqueKeysWithValues: mods.map { ($0.name, $0.artifact) }),
        sourceRevisions: Dictionary(uniqueKeysWithValues: mods.map { ($0.name, $0.revision) }))
    }
    for m in mods { try verifyInput(m) }
    for m in mods {
      if j.prepared[m.name] == nil {
        try check(try status(m.target) == nil, "发现非本事务的目标，拒绝覆盖。")
      } else {
        try check(
          try status(dir.appendingPathComponent("sources/" + m.name)) != nil,
          "已核验的必需源归档缺失；不将缺档视为未开始。 ")
      }
      let (archived, am) = try archive(m, dir)
      if let p = j.prepared[m.name] {
        try check(p.sourceArchiveManifest == am, "归档与原日志不一致。")
        _ = try stageURL(p, m, request.txnID)
      } else {
        try recoverAbandoned(j, m, journalRoot: dir)
        let stage = m.target.deletingLastPathComponent().appendingPathComponent(
          ".gaojixu-" + request.txnID + "-" + m.name + "-" + UUID().uuidString + ".noindex")
        j.stageAttempts[m.name, default: []].append(stage.path)
        try write(j, file, replace: true)
        try checkpoint?("stage-intent:" + m.name)
        let prepared = try prepare(m, j, marker, archived, am, at: stage) { identity in
          if j.stageIdentities == nil { j.stageIdentities = [:] }
          j.stageIdentities?[stage.path] = identity
          try write(j, file, replace: true)
        }
        try checkpoint?("stage-built:" + m.name)
        j.prepared[m.name] = prepared
        try write(j, file, replace: true)
        try checkpoint?("staged:" + m.name)
      }
    }
    // Verify every stage/orphaned promotion before moving a single remaining directory. No authority is writable yet.
    for m in mods {
      guard let p = j.prepared[m.name] else { throw Failure("缺少已准备模块。") }
      let stage = try stageURL(p, m, request.txnID)
      let s = try status(stage) != nil
      let d = try status(m.target) != nil
      try check(
        s != d && (!d || j.phase == "promoting") && (d || !j.promoted.contains(m.name)),
        "暂存/目标目录存在歧义或丢失。")
      let tree = s ? stage : m.target
      try check(
        try manifest(tree) == p.manifest
          && decode(FinanceAuthorityReceipt.self, tree.appendingPathComponent("authority.json"))
            == authority(m, j, marker),
        "暂存或已移动模块的摘要核验失败。")
    }
    if j.phase != "promoting" {
      j.phase = "prepared"
      try write(j, file, replace: true)
      try checkpoint?("prepared")
      j.phase = "promoting"
      try write(j, file, replace: true)
    }
    for m in mods {
      let p = j.prepared[m.name]!
      let stage = try stageURL(p, m, request.txnID)
      if try status(stage) != nil {
        try promote(stage, m.target)
        try checkpoint?("promoted:" + m.name)
      }
      try check(try manifest(m.target) == p.manifest, "目标移动后校验失败，仍未提交。")
      if !j.promoted.contains(m.name) {
        j.promoted.append(m.name)
        try write(j, file, replace: true)
      }
    }
    for m in mods { try validateCurrent(m, j, marker) }
    try makeDir(marker.deletingLastPathComponent())
    try write(
      FinanceCommitMarker(transactionID: request.txnID, modules: names, committedAt: Date()), marker
    )
    try checkpoint?("marker-published")
    j.phase = "committed"
    try write(j, file, replace: true)
    return .init(
      transactionID: request.txnID, modules: names, alreadyCommitted: false,
      counts: j.prepared.mapValues(\.counts),
      verifiedArtifactSHA256: Dictionary(uniqueKeysWithValues: mods.map { ($0.name, $0.artifact) }),
      sourceRevisions: Dictionary(uniqueKeysWithValues: mods.map { ($0.name, $0.revision) }))
  }
}
