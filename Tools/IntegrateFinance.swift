import Foundation

/// Offline executable; a request must name all inputs and destinations; there is no auto-detection or sample/default data.
@main struct IntegrateFinance {
  private static let help = """
    IntegrateFinance --request /absolute/private/request.json
    Required JSON: schemaVersion=1, txnID=<UUID>, writersFrozen=true, targetWritersStopped=true,
      targetMonthlyDirectory, journalDirectory, commitMarkerPath (absolute paths),
      and monthly:{snapshotPath,artifactSHA256,sourceRevision}.
    The monthly snapshot must be detached and WAL-complete.
    Use a new private per-transaction journal directory, outside the target business directory.
    For the installed app set commitMarkerPath to <Savings App Group>/IntegratedFinance/Migrations/<txnID>/committed.json.
    Use the exact same request for recovery. The tool does not stop old writers, make payments, or discover live data.
    """
  private static func request(_ path: String) throws -> FinanceIntegrationMigration.Request {
    guard path.hasPrefix("/") else { throw FinanceIntegrationMigration.Failure("请求文件必须使用绝对路径。") }
    let b = try FinanceAuthority.regularData(URL(fileURLWithPath: path))
    guard b.count <= 128 * 1024, let j = try JSONSerialization.jsonObject(with: b) as? [String: Any]
    else { throw FinanceIntegrationMigration.Failure("请求文件无效。") }
    let allowed: Set<String> = [
      "schemaVersion", "txnID", "writersFrozen", "targetWritersStopped", "monthly",
      "targetMonthlyDirectory", "journalDirectory", "commitMarkerPath",
    ]
    guard Set(j.keys).isSubset(of: allowed) else {
      throw FinanceIntegrationMigration.Failure("请求含未知字段，未执行。")
    }
    if let v = j["monthly"], !(v is NSNull) {
      guard let inputs = v as? [String: Any],
        Set(inputs.keys) == ["snapshotPath", "artifactSHA256", "sourceRevision"]
      else { throw FinanceIntegrationMigration.Failure("冻结输入字段无效。") }
    }
    return try JSONDecoder().decode(FinanceIntegrationMigration.Request.self, from: b)
  }
  static func main() {
    let a = Array(CommandLine.arguments.dropFirst())
    if a == ["--help"] {
      print(help)
      return
    }
    guard a.count == 2, a[0] == "--request" else {
      FileHandle.standardError.write(Data((help + "\n").utf8))
      exit(2)
    }
    do {
      let r = try FinanceIntegrationMigration.run(try request(a[1]))
      let e = JSONEncoder()
      e.outputFormatting = [.prettyPrinted, .sortedKeys]
      FileHandle.standardOutput.write(try e.encode(r))
      print()
    } catch {
      let message = (error as? LocalizedError)?.errorDescription ?? "迁移未能完成：输入、事务状态或文件无法核验。"
      FileHandle.standardError.write(Data((message + "\n").utf8))
      exit(1)
    }
  }
}
