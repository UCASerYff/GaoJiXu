import Foundation
func tS(_ zh:String,_ en:String)->String { zh }
@main struct SavingsSafetyRegression {
 @MainActor static func main() throws {
  let fm=FileManager.default
  let root=fm.temporaryDirectory.appendingPathComponent("gq-safety-"+UUID().uuidString)
  try fm.createDirectory(at:root,withIntermediateDirectories:true)
  setenv("GAOJIXU_DATA_DIR",root.path,1)
  let file=root.appendingPathComponent("library.json"),broken=Data("{unreadable-user-file".utf8)
  try broken.write(to:file)
  let failed=SavingsStore();assert(failed.loadFailed)
  failed.performAutoBattleTick();failed.save();assert(!failed.flushSave())
  let original=try Data(contentsOf:file);assert(original==broken)
  try fm.removeItem(at:file)
  let store=SavingsStore();let account=store.activeAccounts.first { $0.currency == .CNY }!
  let id="test-"+UUID().uuidString+"|2026-01-01"
  assert(store.recordAutoLedgerEntry(paymentID:id,title:"Paid",amount:30,currency:"CNY",date:Date()) == .noAccount)
  assert(store.recordAutoLedgerEntry(paymentID:id,title:"Paid",amount:30,currency:"CNY",date:Date(timeIntervalSince1970:123456),accountOverride:account.id) == .recorded)
  let disk=try JSONDecoder().decode(SavingsLibrary.self,from:Data(contentsOf:file))
  assert(disk.ledgerEntries!.contains { $0.id == "auto-monthly|"+id })
  let p=ConfirmedMonthlyPayment(id:id,title:"Corrected",amount:40,currency:"CNY",date:Date(timeIntervalSince1970:123456))
  _ = try store.reconcileMonthly([p]);assert(store.ledgerEntries.first { $0.id == "auto-monthly|"+id }!.amount==40)
  _ = try store.reconcileMonthly([]);assert(!store.ledgerEntries.contains { $0.id.hasPrefix("auto-monthly|") })
  let before=store.adventure
  for _ in 0..<1000 { store.addEvent(title:"test",detail:"log",symbol:"circle") }
  store.save();assert(store.flushSave());assert(store.rewardEvents.count==300)
  let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
  let oldState=try encoder.encode(before),newState=try encoder.encode(store.adventure);assert(oldState==newState)
  // A failing filesystem write must not acknowledge success or leave an in-memory phantom expense.
  let failureID="test-failed-"+UUID().uuidString
  let beforeEntries=store.ledgerEntries.count
  try fm.removeItem(at:root);try Data("not a directory".utf8).write(to:root)
  assert(store.recordAutoLedgerEntry(paymentID:failureID,title:"failed",amount:10,currency:"CNY",date:Date(),accountOverride:account.id) == .noAccount)
  assert(store.ledgerEntries.count==beforeEntries)
  UserDefaults.standard.removeObject(forKey:"gqns.monthly.account."+String(id.split(separator:"|")[0]))
  try fm.removeItem(at:root)
  print("PASS Savings: corrupt-file lockout; durable receipts; explicit account; corrections and withdrawals; log cap preserves state; failed write rollback")
 }
}
