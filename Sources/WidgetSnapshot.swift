import Foundation

/// Shared, deliberately small data contract between the main app and its macOS widgets.
/// The widget never reads the full financial library; it only receives these derived values.
struct GaoJiXuWidgetSnapshot: Codable {
    static let groupID = "5G96498KGJ.com.gaojixu.savings"

    struct Day: Codable, Identifiable, Hashable {
        let date: Date
        let day: Int
        let expense: Double
        let income: Double
        let saving: Double

        var id: String { "\(day)-\(date.timeIntervalSince1970)" }
    }

    struct Account: Codable, Identifiable, Hashable {
        let id: String
        let name: String
        let balance: Double
        let symbol: String
    }

    let updatedAt: Date
    let monthStart: Date
    let monthTitle: String
    let currencyCode: String
    let currencySymbol: String
    let days: [Day]
    let netWorth: Double
    let accounts: [Account]
    /// 快照统计币种（V2.2 新增）。旧快照没有该字段，解码时默认 "CNY"。
    let currency: String
    /// 本月预算总额（V2.3 新增，快照统计币种口径）。nil 表示当月未设预算。
    let budgetTotal: Double?
    /// 本月预算已执行支出（V2.3 新增，与 budgetTotal 同为 nil 或非 nil）。
    let budgetSpent: Double?

    init(updatedAt: Date, monthStart: Date, monthTitle: String, currencyCode: String, currencySymbol: String,
         days: [Day], netWorth: Double, accounts: [Account], currency: String = "CNY",
         budgetTotal: Double? = nil, budgetSpent: Double? = nil) {
        self.updatedAt = updatedAt
        self.monthStart = monthStart
        self.monthTitle = monthTitle
        self.currencyCode = currencyCode
        self.currencySymbol = currencySymbol
        self.days = days
        self.netWorth = netWorth
        self.accounts = accounts
        self.currency = currency
        self.budgetTotal = budgetTotal
        self.budgetSpent = budgetSpent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        monthStart = try container.decode(Date.self, forKey: .monthStart)
        monthTitle = try container.decode(String.self, forKey: .monthTitle)
        currencyCode = try container.decode(String.self, forKey: .currencyCode)
        currencySymbol = try container.decode(String.self, forKey: .currencySymbol)
        days = try container.decode([Day].self, forKey: .days)
        netWorth = try container.decode(Double.self, forKey: .netWorth)
        accounts = try container.decode([Account].self, forKey: .accounts)
        // 向后兼容：旧版本小组件/旧快照文件中没有 currency 字段时按 CNY 处理。
        currency = try container.decodeIfPresent(String.self, forKey: .currency) ?? "CNY"
        // 向后兼容：V2.3 之前的快照没有预算字段，缺失即「未设预算」。
        budgetTotal = try container.decodeIfPresent(Double.self, forKey: .budgetTotal)
        budgetSpent = try container.decodeIfPresent(Double.self, forKey: .budgetSpent)
    }

    static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("gaojixu-widget.json")
    }

    static var fallbackFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("GaoSeries/Savings", isDirectory: true)
            .appendingPathComponent("gaojixu-widget.json")
    }
}
