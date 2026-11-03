import Foundation
@main struct AutoLedgerTaskSafetyRegression {
    static func check(_ b: Bool) { precondition(b) }
    static func reject(_ f: () throws -> Void) { do { try f(); preconditionFailure("expected rejection") } catch {} }
    static func main() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("monthly-task-regression-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root);unsetenv("GQNS_AUTOLEDGER_TASKS_FILE")}
        let file=root.appendingPathComponent("tasks.json");setenv("GQNS_AUTOLEDGER_TASKS_FILE",file.path,1)
        check(try AutoLedgerTasks.loadChecked().isEmpty)
        reject { _=try AutoLedgerTasks.loadChecked(expectExisting:true) }
        try Data("broken".utf8).write(to:file)
        reject { _=try AutoLedgerTasks.loadChecked() }
        reject { try AutoLedgerTasks.saveChecked([]) }
        check(try Data(contentsOf:file)==Data("broken".utf8))
        try FileManager.default.removeItem(at:file)
        let task=AutoLedgerTask(id:"source|2030-01-01",title:"Synthetic",amount:1,currency:"CNY",date:Date(),state:.ignored,attempts:0)
        try AutoLedgerTasks.saveChecked([task]);check(try AutoLedgerTasks.loadChecked().first?.state == .ignored)
        let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601;try encoder.encode([task,task]).write(to:file)
        reject { _=try AutoLedgerTasks.loadChecked() }
        print("Monthly task authority safety passed (isolated).")
    }
}
