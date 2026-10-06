import Foundation

/// P0-2 修复：月供自动记账的持久化任务表。
/// 旧实现把事件放进仅内存的 pendingQueue 后立即在偏好里标「已记账」——
/// 用户没打开搞积蓄就退出，队列消失且永不重试（永久漏记）；接收端无可用账户时静默跳过。
/// 新实现：任务表落盘（应用支持目录/auto-ledger-tasks.json），状态 pending/done/failed，
/// 只有流水成功落盘（接收端回执 recorded/duplicate）才标 done；
/// 无匹配币种账户保持 pending 并在搞积蓄界面可见，由用户选账户入账，绝不自动落到不同币种账户。
/// 重启后 AutoLedger.run() 会重新投递全部 pending 任务。
struct AutoLedgerTask: Codable, Equatable, Identifiable {
    var id: String        // paymentID（月供侧唯一键 subscriptionID|yyyy-MM-dd）
    var title: String
    var amount: Double
    var currency: String
    var date: Date
    var state: State
    var attempts: Int
    var lastError: String?

    enum State: String, Codable {
        case pending   // 待处理（含「无匹配账户，等待用户选择」）
        case done      // 流水已成功落盘
        case failed    // 数据无效等不可自动恢复（界面可见，不自动重试）
        case ignored   // 用户主动忽略（对账表可见，可撤销回 pending）
    }
}

/// 任务表读写（原子写；主 app 与 Savings 模块同进程共用，Savings 侧有一份同格式读写副本）。
/// 标 nonisolated 之外不加锁：调用方均在主线程（AutoLedger.deliver / Savings 界面）。
enum AutoLedgerTasks {
    static var fileURL: URL {
        // 测试/验收可用环境变量隔离路径，不碰真实任务表。
        if let override = ProcessInfo.processInfo.environment["GQNS_AUTOLEDGER_TASKS_FILE"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GaoSeries/Savings/auto-ledger-tasks.json")
    }

    /// done 历史只保留最近 200 条，pending/failed 永远不自动清。
    private static let maxDone = 200

    static func load() -> [AutoLedgerTask] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([AutoLedgerTask].self, from: data)) ?? []
    }

    static func save(_ tasks: [AutoLedgerTask]) {
        do { try saveChecked(tasks) } catch {
            NotificationCenter.default.post(name:Notification.Name("GaoSeries.dataError"),object:nil,userInfo:["message":"自动记账任务保存失败：\(error.localizedDescription)"])
        }
    }
    static func saveChecked(_ tasks: [AutoLedgerTask]) throws {
        // Refuse to replace an unreadable existing task file.
        if FileManager.default.fileExists(atPath:fileURL.path) {
            let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
            _ = try decoder.decode([AutoLedgerTask].self,from:Data(contentsOf:fileURL))
        }
        let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at:fileURL.deletingLastPathComponent(),withIntermediateDirectories:true)
        try encoder.encode(tasks).write(to:fileURL,options:.atomic)
    }

    static func isDone(_ id: String) -> Bool {
        load().contains { $0.id == id && $0.state == .done }
    }

    static func pending() -> [AutoLedgerTask] {
        load().filter { $0.state == .pending }
    }

    /// 新到期账单登记为 pending（幂等：已存在同 id 任务不重复登记）。
    static func upsertPending(id: String, title: String, amount: Double, currency: String, date: Date) {
        var tasks = load()
        guard !tasks.contains(where: { $0.id == id }) else { return }
        tasks.append(AutoLedgerTask(id: id, title: title, amount: amount, currency: currency,
                                    date: date, state: .pending, attempts: 0, lastError: nil))
        save(tasks)
    }

    static func markDone(_ id: String) {
        update(id) { $0.state = .done; $0.lastError = nil }
    }

    static func markFailed(_ id: String, reason: String) {
        update(id) { $0.state = .failed; $0.lastError = reason }
    }

    /// 用户主动忽略（对账表可见，可撤销）。
    static func markIgnored(_ id: String) {
        update(id) { $0.state = .ignored }
    }

    /// 撤销忽略：回到待处理，下一轮投递/界面选择继续。
    static func markPending(_ id: String) {
        update(id) { $0.state = .pending; $0.lastError = nil }
    }

    /// 投递/尝试计数与最近一次未成功原因（保持 pending）。
    static func noteAttempt(_ id: String, error: String?) {
        update(id) { $0.attempts += 1; $0.lastError = error }
    }

    private static func update(_ id: String, _ mutate: (inout AutoLedgerTask) -> Void) {
        var tasks = load()
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        mutate(&tasks[index])
        save(tasks)
    }
}
