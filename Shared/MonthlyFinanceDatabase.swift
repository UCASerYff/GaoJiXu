import Darwin
import Foundation
import SQLite3

/// The runtime path never creates or initializes a missing store, including when opened read-write.
final class MonthlyFinanceDatabase {
  static let groupID = "5G96498KGJ.com.gaojixu.savings"
  static func location() throws -> URL {
    guard
      let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    else { throw MonthlyFinanceError("积蓄共享容器不可用。") }
    return group.appendingPathComponent("IntegratedFinance/Monthly", isDirectory: true)
  }
  let directory: URL
  private let connection: MonthlyFinanceConnection
  private let readOnly: Bool
  init(directory: URL, readOnly: Bool = true) throws {
    self.directory = directory
    self.readOnly = readOnly
    try FinanceAuthority.require(module: "monthly", directory: directory)
    connection = try MonthlyFinanceConnection(
      existing: directory.appendingPathComponent("monthly.sqlite"), readOnly: readOnly)
    _ = try decode()
  }
  private func decode() throws -> MonthlyFinanceState {
    let value = try JSONDecoder().decode(MonthlyFinanceState.self, from: connection.payload())
    try MonthlyFinanceEngine.validate(value)
    return value
  }
  func read() throws -> MonthlyFinanceState {
    try FinanceAuthority.require(module: "monthly", directory: directory)
    return try decode()
  }
  @discardableResult func transaction(_ body: (inout MonthlyFinanceState) throws -> Void) throws
    -> MonthlyFinanceState
  {
    guard !readOnly else { throw MonthlyFinanceError("该业务库为只读。") }
    try FinanceAuthority.require(module: "monthly", directory: directory)
    try connection.exec("BEGIN IMMEDIATE")
    do {
      let prior = try decode()
      var next = prior
      try body(&next)
      next.updatedAt = prior.updatedAt
      try MonthlyFinanceEngine.validate(next)
      if next != prior {
        next.updatedAt = Date()
        try connection.updatePayload(JSONEncoder().encode(next))
      }
      try FinanceAuthority.require(module: "monthly", directory: directory)
      try connection.exec("COMMIT")
      return next
    } catch {
      try? connection.exec("ROLLBACK")
      throw error
    }
  }
}

/// Exact-row reader used by the receiver and by staging on detached, WAL-complete source snapshots.
final class MonthlyFinanceConnection {
  private var db: OpaquePointer?
  init(existing file: URL, readOnly: Bool) throws {
    let attrs = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
    guard attrs.isRegularFile == true, attrs.isSymbolicLink != true else {
      throw MonthlyFinanceError("固定支出库不是普通文件，未创建或替换。")
    }
    let flags =
      (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_FULLMUTEX
      | SQLITE_OPEN_NOFOLLOW
    // macOS exposes the same temporary/container directories through /var and /private/var.
    // Canonicalize only the parent; NOFOLLOW still rejects a replaced/symlinked leaf.
    guard let resolved = Darwin.realpath(file.deletingLastPathComponent().path, nil) else {
      throw MonthlyFinanceError("月供资料目录不可达。")
    }
    defer { free(resolved) }
    let path = String(cString: resolved) + "/" + file.lastPathComponent
    let rc = sqlite3_open_v2(path, &db, flags, nil)
    guard rc == SQLITE_OK else {
      let extended = sqlite3_extended_errcode(db)
      sqlite3_close(db)
      db = nil
      throw MonthlyFinanceError("月供数据文件不可读或不可写（SQLite \(extended)）。")
    }
    sqlite3_busy_timeout(db, 1000)
    if readOnly { try exec("PRAGMA query_only=ON") } else { try exec("PRAGMA synchronous=FULL") }
  }
  deinit { sqlite3_close(db) }
  func exec(_ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
      throw MonthlyFinanceError("月供数据库操作未完成（SQLite \(sqlite3_errcode(db))）。")
    }
  }
  func verifySnapshot() throws {
    var st: OpaquePointer?
    guard sqlite3_prepare_v2(db, "PRAGMA integrity_check", -1, &st, nil) == SQLITE_OK else {
      throw MonthlyFinanceError("无法校验月供快照。")
    }
    defer { sqlite3_finalize(st) }
    guard sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0),
      String(cString: c) == "ok", sqlite3_step(st) == SQLITE_DONE
    else { throw MonthlyFinanceError("月供快照完整性校验失败。") }
    var schema: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        db,
        "SELECT type,name FROM sqlite_master WHERE type IN ('table','view','trigger') AND name NOT LIKE 'sqlite_%' ORDER BY name",
        -1, &schema, nil) == SQLITE_OK
    else { throw MonthlyFinanceError("无法核验源表。") }
    defer { sqlite3_finalize(schema) }
    guard sqlite3_step(schema) == SQLITE_ROW, let type = sqlite3_column_text(schema, 0),
      String(cString: type) == "table", let name = sqlite3_column_text(schema, 1),
      String(cString: name) == "state", sqlite3_step(schema) == SQLITE_DONE
    else { throw MonthlyFinanceError("月供数据库对象超出已知格式。") }
    // A BLOB can be stored even in a TEXT-affinity column. Verify declarations, not just
    // the runtime types of the one row. table_xinfo also exposes hidden/generated columns.
    var fields: OpaquePointer?
    guard sqlite3_prepare_v2(db, "PRAGMA main.table_xinfo('state')", -1, &fields, nil) == SQLITE_OK
    else { throw MonthlyFinanceError("无法核验月供业务表的列定义。") }
    defer { sqlite3_finalize(fields) }
    let expected: [(name: String, type: String, notNull: Int32, primaryKey: Int32)] = [
      ("id", "INTEGER", 0, 1), ("json", "BLOB", 1, 0),
    ]
    for (cid, column) in expected.enumerated() {
      guard sqlite3_step(fields) == SQLITE_ROW, sqlite3_column_count(fields) == 7,
        sqlite3_column_int(fields, 0) == Int32(cid),
        let name = sqlite3_column_text(fields, 1), String(cString: name) == column.name,
        let type = sqlite3_column_text(fields, 2), String(cString: type).uppercased() == column.type,
        sqlite3_column_int(fields, 3) == column.notNull, sqlite3_column_type(fields, 4) == SQLITE_NULL,
        sqlite3_column_int(fields, 5) == column.primaryKey, sqlite3_column_int(fields, 6) == 0
      else { throw MonthlyFinanceError("月供业务表的列声明不匹配；未导入。") }
    }
    guard sqlite3_step(fields) == SQLITE_DONE else {
      throw MonthlyFinanceError("月供业务表存在额外或无法核验的列；未导入。")
    }
  }
  func payload() throws -> Data {
    var st: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT id,json FROM state LIMIT 2", -1, &st, nil) == SQLITE_OK
    else { throw MonthlyFinanceError("月供业务表不可读。") }
    defer { sqlite3_finalize(st) }
    guard sqlite3_step(st) == SQLITE_ROW, sqlite3_column_type(st, 0) == SQLITE_INTEGER,
      sqlite3_column_int64(st, 0) == 1, sqlite3_column_type(st, 1) == SQLITE_BLOB,
      let p = sqlite3_column_blob(st, 1), sqlite3_column_bytes(st, 1) > 0
    else { throw MonthlyFinanceError("缺失唯一有效月供记录，未初始化空库。") }
    let data = Data(bytes: p, count: Int(sqlite3_column_bytes(st, 1)))
    guard sqlite3_step(st) == SQLITE_DONE else { throw MonthlyFinanceError("月供业务库行数不符。") }
    return data
  }
  func updatePayload(_ data: Data, initial: Bool = false) throws {
    var st: OpaquePointer?
    let sql =
      initial ? "INSERT INTO state(id,json) VALUES(1,?)" : "UPDATE state SET json=? WHERE id=1"
    guard data.count <= Int(Int32.max), sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK
    else { throw MonthlyFinanceError("无法写入月供业务库。") }
    defer { sqlite3_finalize(st) }
    let rc = data.withUnsafeBytes {
      sqlite3_bind_blob(
        st, 1, $0.baseAddress, Int32(data.count),
        unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    guard rc == SQLITE_OK, sqlite3_step(st) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
      throw MonthlyFinanceError("月供业务记录未落盘。")
    }
  }
}
