import Foundation
import SQLite3
// Only committed monthly payment records are read. This reader cannot write to its source.
enum MonthlySource {
    static var group:URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:"5G96498KGJ.com.gaoseries.GaoYueGong") }
    struct State:Decodable {
        struct Subscription:Decodable {let id:UUID;let name:String}
        struct Payment:Decodable {let id:String;let subscriptionID:UUID?;let paidAt:Date;let amount:Double;let currency:String;let skipped:Bool?}
        let subscriptions:[Subscription];let payments:[Payment]
    }
    static func readStateBlob(_ url:URL)->Data? {
        guard FileManager.default.fileExists(atPath:url.path) else {return nil}
        var db:OpaquePointer?
        guard sqlite3_open_v2(url.path,&db,SQLITE_OPEN_READONLY|SQLITE_OPEN_FULLMUTEX,nil)==SQLITE_OK,let db else {if let db {sqlite3_close(db)};return nil}
        defer {sqlite3_close(db)}
        sqlite3_busy_timeout(db,1000)
        var statement:OpaquePointer?
        guard sqlite3_prepare_v2(db,"SELECT json FROM state WHERE id=1",-1,&statement,nil)==SQLITE_OK else {return nil}
        defer {sqlite3_finalize(statement)}
        guard sqlite3_step(statement)==SQLITE_ROW,let p=sqlite3_column_blob(statement,0) else {return nil}
        return Data(bytes:p,count:Int(sqlite3_column_bytes(statement,0)))
    }
}
