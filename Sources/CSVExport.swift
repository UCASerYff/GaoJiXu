import Foundation

/// 流水 CSV 导出。纯函数实现，便于冒烟测试与复用。
/// 输出遵循 RFC 4180（含逗号/双引号/换行的字段用双引号包裹、内部双引号成对转义），
/// 并在文件开头加 UTF-8 BOM，保证 Excel 打开时中文不乱码。
enum LedgerCSVExporter {
    /// 生成完整 CSV 文本（含 BOM、表头与全部流水行）。
    /// - 顺序与 App 内流水列表一致（按日期倒序，最新在前）。
    /// - 金额：按「源账户币种」的小数位输出正数，收支方向由「类型」列表达。
    /// - 跨币种转账：金额/币种记录转出侧；转入侧的折算金额（targetAmount）不单独占列。
    static func makeCSV(entries: [LedgerEntry], accounts: [LedgerAccount]) -> String {
        let accountsByID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var lines = ["日期,类型,账户,目标账户,分类,备注,金额,币种"]
        for entry in entries {
            let source = accountsByID[entry.accountID]
            let currency = source?.currency ?? .CNY
            let fields = [
                dateFormatter.string(from: entry.date),
                entry.kind.title,
                source?.name ?? "已归档账户",
                entry.targetAccountID.flatMap { accountsByID[$0] }?.name ?? "",
                entry.isBalanceAdjustment ? "余额调整" : SavingsCatalog.ledgerCategory(entry.categoryID)?.name ?? entry.categoryID,
                entry.note,
                String(format: "%.\(currency.fractionDigits)f", entry.amount),
                currency.rawValue,
            ]
            lines.append(fields.map(escape).joined(separator: ","))
        }
        return "\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n"
    }

    /// RFC 4180 字段转义：字段含逗号、双引号或换行时用双引号包裹，并把内部双引号替换为两个。
    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
