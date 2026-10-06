import Foundation
import Savings

/// Confirmed monthly payments are authoritative. Reconcile across restarts and past dates.
enum AutoLedger {
    static let notificationName = "gaojixu.autoLedgerEntry"
    static let resultNotificationName = "gaojixu.autoLedgerResult"
    static let recordedKey = "gqns.autoLedger.recorded"
    private static var timer: Timer?
    private static var running = false
    private static var started = false
    private struct Payment: Codable {
        let id: String; let title: String; let amount: Double; let currency: String; let date: Date
    }
    @MainActor static func start() {
        guard !started, ProcessInfo.processInfo.environment["GAOQINIANSAN_INTEGRATION_TEST"] == nil else { return }
        started = true
        NotificationCenter.default.addObserver(forName: Notification.Name(resultNotificationName),object:nil,queue:.main) { note in
            guard let id=note.userInfo?["paymentID"] as? String,let outcome=note.userInfo?["outcome"] as? String else { return }
            if outcome == "recorded" || outcome == "duplicate" { AutoLedgerTasks.markDone(id) }
            else { AutoLedgerTasks.noteAttempt(id,error:note.userInfo?["reason"] as? String) }
        }
        DistributedNotificationCenter.default().addObserver(forName:Notification.Name("GaoSeries.monthly.changed"),object:nil,queue:.main) { _ in
            Task { @MainActor in run() }
        }
        run()
        timer=Timer.scheduledTimer(withTimeInterval:60,repeats:true) { _ in Task { @MainActor in run() } }
    }
    @MainActor static func run() {
        guard !running else { return }; running=true
        DispatchQueue.global(qos:.utility).async {
            let payments=confirmedPayments()
            Task { @MainActor in
                defer { running=false }
                // Unavailable/corrupt source never means an empty account.
                guard let payments else { return }
                do {
                    let data=try JSONEncoder().encode(payments)
                    let ignored=Set(AutoLedgerTasks.load().filter { $0.state == .ignored }.map(\.id))
                    let results=try SavingsModuleRuntime.reconcileMonthly(data,ignored:ignored)
                    let old=Dictionary(AutoLedgerTasks.load().map { ($0.id,$0) },uniquingKeysWith: { a,_ in a })
                    let tasks=payments.map { p in
                        AutoLedgerTask(id:p.id,title:p.title,amount:p.amount,currency:p.currency,date:p.date,
                                       state:results[p.id] == "done" ? .done : (ignored.contains(p.id) ? .ignored : .pending),
                                       attempts:old[p.id]?.attempts ?? 0,lastError:results[p.id] == "done" ? nil : "请选择或检查订阅的同币种扣款账户")
                    }
                    try AutoLedgerTasks.saveChecked(tasks)
                    NotificationCenter.default.post(name:Notification.Name(resultNotificationName),object:nil)
                } catch {
                    NotificationCenter.default.post(name:Notification.Name("GaoSeries.dataError"),object:nil,userInfo:["message":"月供对账未完成：\(error.localizedDescription)"])
                }
            }
        }
    }
    private static func confirmedPayments() -> [Payment]? {
        guard let url=MonthlySource.group?.appendingPathComponent("Monthly/monthly.sqlite"),
              let data=MonthlySource.readStateBlob(url),
              let state=try? JSONDecoder().decode(MonthlySource.State.self,from:data) else { return nil }
        let names=Dictionary(state.subscriptions.map { ($0.id,$0.name) },uniquingKeysWith:{a,_ in a})
        return state.payments.filter { !($0.skipped ?? false) && $0.amount.isFinite && $0.amount > 0 }.map {
            Payment(id:$0.id,title:$0.subscriptionID.flatMap { names[$0] } ?? "已确认支付",amount:$0.amount,currency:$0.currency,date:$0.paidAt)
        }
    }
}
