import Foundation
import SwiftUI

/// 流水 CSV 导入（V2.3）。
/// 解析与导入计划均为纯函数，便于冒烟测试；真正写入只走 SavingsStore 现有
/// saveAccount / saveLedgerEntry 接口，不触碰 store 内部。
///
/// 兼容口径：
/// - 自家导出格式：UTF-8 BOM、CRLF/LF、RFC 4180 引号转义（含字段内换行与 ""）。
/// - 日期："yyyy-MM-dd HH:mm" 与 "yyyy-MM-dd"（后者按当天 00:00）。
/// - 类型：收入/支出/转账 与 income/expense/transfer（大小写不敏感）。
/// - 金额：允许千分位逗号——按 RFC 4180，带千分位的金额在规范 CSV 中必被引号包裹，
///   因此先按引号规则切分字段，再剔除金额内的 ","。
/// - 去重：与现有流水按（日期到分钟 + 类型 + 账户 + 金额 + 备注）匹配跳过；
///   同一文件内的重复行也只导入一次。
enum LedgerCSVImporter {
    struct ParsedRow: Hashable {
        var date: Date
        var kind: LedgerEntryKind
        var accountName: String
        var targetAccountName: String
        var categoryName: String
        var note: String
        var amount: Decimal
        var currencyCode: String
    }

    struct ParseOutcome {
        var rows: [ParsedRow]
        /// 无法解析（缺列、日期/类型/金额非法、缺账户名）而跳过的数据行数。
        var skippedLines: Int
    }

    /// 已解析账户/分类的一行，等待写入。
    struct ResolvedRow: Hashable {
        var kind: LedgerEntryKind
        var accountName: String
        var targetAccountName: String
        var amount: Decimal
        var categoryID: String
        var date: Date
        var note: String
        var currency: SavingsCurrency
    }

    struct ImportPlan {
        var toImport: [ResolvedRow]
        var duplicatesSkipped: Int
        /// 需要自动新建的现金账户（按名称去重）。
        var newAccounts: [(name: String, currency: SavingsCurrency)]
    }

    // MARK: - 解析

    static func parse(_ text: String) -> ParseOutcome {
        let stripped = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let records = tokenize(stripped)
        var rows: [ParsedRow] = []
        var skipped = 0
        for (index, fields) in records.enumerated() {
            // 全空行（ trailing newline 产生的空记录）直接忽略，不计入跳过。
            if fields.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            // 表头：首个字段是「日期」的记录跳过（自家导出第一行）。
            if index == 0, fields.first?.trimmingCharacters(in: .whitespaces) == "日期" { continue }
            guard let row = parseRow(fields) else { skipped += 1; continue }
            rows.append(row)
        }
        return ParseOutcome(rows: rows, skippedLines: skipped)
    }

    /// 8 列：日期,类型,账户,目标账户,分类,备注,金额,币种。
    private static func parseRow(_ fields: [String]) -> ParsedRow? {
        guard fields.count >= 8 else { return nil }
        let cleaned = fields.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let date = parseDate(cleaned[0]), let kind = parseKind(cleaned[1]) else { return nil }
        guard !cleaned[2].isEmpty else { return nil }
        guard let amount = parseAmount(cleaned[6]), amount > 0 else { return nil }
        let currencyCode = cleaned[7].uppercased()
        return ParsedRow(
            date: date,
            kind: kind,
            accountName: cleaned[2],
            targetAccountName: cleaned[3],
            categoryName: cleaned[4],
            note: cleaned[5],
            amount: amount,
            currencyCode: currencyCode
        )
    }

    static func parseDate(_ text: String) -> Date? {
        if let date = minuteFormatter.date(from: text) { return date }
        return dayFormatter.date(from: text)
    }

    static func parseKind(_ text: String) -> LedgerEntryKind? {
        switch text.lowercased() {
        case "收入", "income": return .income
        case "支出", "expense": return .expense
        case "转账", "transfer": return .transfer
        default: return nil
        }
    }

    /// 金额允许千分位逗号与货币符号空白；必须为正有限数。
    static func parseAmount(_ text: String) -> Decimal? {
        let cleaned = text
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "¥", with: "")
            .replacingOccurrences(of: "$", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return MoneyValue.normalize(value)
    }

    /// RFC 4180 记录切分：支持 CRLF/LF/CR、引号包裹、"" 转义与字段内换行。
    /// 注意：必须按 unicodeScalars 遍历——Swift 中 "\r\n" 是单个 Character，
    /// 按 Character 遍历永远匹配不到单独的 CR。
    static func tokenize(_ text: String) -> [[String]] {
        let scalars = Array(text.unicodeScalars)
        let quote = Unicode.Scalar(34)   // "
        let comma = Unicode.Scalar(44)   // ,
        let cr = Unicode.Scalar(13)      // \r
        let lf = Unicode.Scalar(10)      // \n
        var records: [[String]] = []
        var fields: [String] = []
        var field = ""
        var inQuotes = false
        var index = 0
        func endField() { fields.append(field); field = "" }
        func endRecord() { endField(); records.append(fields); fields = [] }
        while index < scalars.count {
            let scalar = scalars[index]
            if inQuotes {
                if scalar == quote {
                    if index + 1 < scalars.count && scalars[index + 1] == quote {
                        field.append("\"")
                        index += 2
                        continue
                    }
                    inQuotes = false
                    index += 1
                    continue
                }
                field.unicodeScalars.append(scalar)
                index += 1
                continue
            }
            if scalar == quote {
                // 仅在字段开头（空字段）进入引号模式；字段中间的引号按字面保留（容错）。
                if field.isEmpty { inQuotes = true } else { field.append("\"") }
                index += 1
            } else if scalar == comma {
                endField()
                index += 1
            } else if scalar == cr {
                endRecord()
                index += (index + 1 < scalars.count && scalars[index + 1] == lf) ? 2 : 1
            } else if scalar == lf {
                endRecord()
                index += 1
            } else {
                field.unicodeScalars.append(scalar)
                index += 1
            }
        }
        // 文件不以换行结尾时收尾最后一条记录。
        if !field.isEmpty || !fields.isEmpty { endRecord() }
        return records
    }

    // MARK: - 导入计划

    /// 去重键：日期向下取整到分钟（导出 CSV 只保留到分钟，回导时与库内流水可比），
    /// 加上类型、账户、金额（2dp 归一化）与备注。
    private struct DedupKey: Hashable {
        var minute: TimeInterval
        var kind: LedgerEntryKind
        var accountID: String
        var amount: Decimal
        var note: String
    }

    private static func dedupKey(kind: LedgerEntryKind, accountID: String, amount: Decimal, note: String, date: Date) -> DedupKey {
        DedupKey(minute: (date.timeIntervalSince1970 / 60).rounded(.down) * 60,
                 kind: kind, accountID: accountID, amount: MoneyValue.normalize(amount), note: note)
    }

    /// 生成导入计划：解析账户/分类、去重。不读写任何持久状态。
    /// - 账户按名称匹配（仅使用中账户；归档账户视为未知，导入时重建活跃账户）。
    /// - 未知账户名列入 newAccounts，导入时自动创建现金账户（币种取 CSV 行内币种，无法识别则 CNY）。
    /// - 未知分类归入该类型的第一个分类；转账固定 account-transfer。
    static func plan(rows: [ParsedRow], accounts: [LedgerAccount], existingEntries: [LedgerEntry]) -> ImportPlan {
        let activeByName = Dictionary(accounts.filter { !$0.isArchived }.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set(existingEntries.map {
            dedupKey(kind: $0.kind, accountID: $0.accountID, amount: $0.amountValue, note: $0.note, date: $0.date)
        })
        var toImport: [ResolvedRow] = []
        var duplicates = 0
        var newAccounts: [(name: String, currency: SavingsCurrency)] = []
        var newAccountNames = Set<String>()

        for row in rows {
            // 未知账户名登记为待新建（同一次导入中按名称去重）。
            if activeByName[row.accountName] == nil, !newAccountNames.contains(row.accountName) {
                newAccountNames.insert(row.accountName)
                newAccounts.append((row.accountName, SavingsCurrency(rawValue: row.currencyCode) ?? .CNY))
            }
            // 去重键中的账户身份用名称即可（账户在导入前不会被重命名）。
            let identity = activeByName[row.accountName]?.id ?? "new:\(row.accountName)"
            let key = dedupKey(kind: row.kind, accountID: identity, amount: row.amount, note: row.note, date: row.date)
            if seen.contains(key) {
                duplicates += 1
                continue
            }
            seen.insert(key)
            let categoryID: String
            if row.kind == .transfer {
                categoryID = "account-transfer"
            } else if row.categoryName == "余额调整" || row.categoryName == LedgerEntry.balanceAdjustmentCategoryID {
                categoryID = LedgerEntry.balanceAdjustmentCategoryID
            } else if let matched = SavingsCatalog.ledgerCategories.first(where: { $0.kind == row.kind && $0.name == row.categoryName }) {
                categoryID = matched.id
            } else {
                categoryID = SavingsCatalog.ledgerCategories.first { $0.kind == row.kind }?.id ?? row.categoryName
            }
            // 转账的目标账户同样按名称解析；未知则登记新建。
            var targetName = ""
            if row.kind == .transfer {
                targetName = row.targetAccountName
                if !targetName.isEmpty, activeByName[targetName] == nil, !newAccountNames.contains(targetName) {
                    newAccountNames.insert(targetName)
                    newAccounts.append((targetName, SavingsCurrency(rawValue: row.currencyCode) ?? .CNY))
                }
            }
            toImport.append(ResolvedRow(
                kind: row.kind,
                accountName: row.accountName,
                targetAccountName: targetName,
                amount: row.amount,
                categoryID: categoryID,
                date: row.date,
                note: row.note,
                currency: SavingsCurrency(rawValue: row.currencyCode) ?? activeByName[row.accountName]?.currency ?? .CNY
            ))
        }
        return ImportPlan(toImport: toImport, duplicatesSkipped: duplicates, newAccounts: newAccounts)
    }

    // MARK: - 写入

    /// 执行导入计划：先建缺失账户，再逐条写入流水。返回实际写入条数。
    /// 只调用 SavingsStore 公开接口（saveAccount / saveLedgerEntry）。
    @MainActor
    @discardableResult
    static func apply(_ plan: ImportPlan, to store: SavingsStore) -> Int {
        for account in plan.newAccounts {
            store.saveAccount(existingID: nil, name: account.name, type: .cash, currency: account.currency,
                              balance: 0, includeInNetWorth: true, colorKey: "teal")
        }
        var written = 0
        for row in plan.toImport {
            guard let source = store.accounts.first(where: { $0.name == row.accountName && !$0.isArchived }) else { continue }
            var targetID: String?
            var targetAmount: Double?
            if row.kind == .transfer {
                guard !row.targetAccountName.isEmpty,
                      let target = store.accounts.first(where: { $0.name == row.targetAccountName && !$0.isArchived }),
                      target.id != source.id else { continue }
                targetID = target.id
                // 自家导出不含转入侧金额；跨币种转账按 1:1 占位，导入后可在编辑器里改实际转入金额。
                targetAmount = MoneyValue.double(row.amount)
            }
            store.saveLedgerEntry(existingID: nil, kind: row.kind, accountID: source.id, targetAccountID: targetID,
                                  amount: MoneyValue.double(row.amount), targetAmount: targetAmount,
                                  categoryID: row.categoryID, date: row.date, note: row.note)
            written += 1
        }
        return written
    }

    // MARK: - 格式化器

    private static let minuteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

// MARK: - 导入预览 sheet

struct CSVImportContext: Identifiable {
    let id = UUID()
    let fileName: String
    let plan: LedgerCSVImporter.ImportPlan
    let parseSkipped: Int
}

struct CSVImportPreviewView: View {
    @EnvironmentObject private var store: SavingsStore
    @Environment(\.dismiss) private var dismiss
    let context: CSVImportContext

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("导入流水预览").font(.title2.weight(.semibold))
                    Text(context.fileName).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("取消") { dismiss() }
                Button("确认导入 \(context.plan.toImport.count) 条") { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(context.plan.toImport.isEmpty)
            }
            .padding(22)
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    SavingsStatTile(value: "\(context.plan.toImport.count)", label: "将导入", symbol: "square.and.arrow.down.fill", color: SavingsTheme.green)
                    SavingsStatTile(value: "\(context.plan.duplicatesSkipped)", label: "跳过重复", symbol: "doc.on.doc.fill", color: SavingsTheme.orange)
                    SavingsStatTile(value: "\(context.parseSkipped)", label: "无法解析", symbol: "exclamationmark.triangle.fill", color: context.parseSkipped > 0 ? SavingsTheme.red : SavingsTheme.blue)
                }
                if !context.plan.newAccounts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("将自动新建 \(context.plan.newAccounts.count) 个现金账户", systemImage: "wallet.pass.fill")
                            .font(.callout.weight(.medium))
                        ForEach(context.plan.newAccounts, id: \.name) { account in
                            Text("· \(account.name)（\(account.currency.rawValue)）")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SavingsTheme.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("前 5 行预览").font(.headline)
                    if context.plan.toImport.isEmpty {
                        Text("没有可导入的新流水。").font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(context.plan.toImport.prefix(5).enumerated()), id: \.offset) { _, row in
                            HStack(spacing: 10) {
                                Text(SavingsFormatters.shortDay.string(from: row.date))
                                    .foregroundStyle(.secondary)
                                Text(row.kind.title)
                                    .foregroundStyle(row.kind == .income ? SavingsTheme.green : row.kind == .expense ? SavingsTheme.red : SavingsTheme.blue)
                                Text(row.targetAccountName.isEmpty ? row.accountName : "\(row.accountName) → \(row.targetAccountName)")
                                    .lineLimit(1)
                                Spacer()
                                Text(SavingsFormatters.money(row.amount, currency: row.currency))
                                    .monospacedDigit()
                            }
                            .font(.callout)
                        }
                        if context.plan.toImport.count > 5 {
                            Text("… 以及另外 \(context.plan.toImport.count - 5) 条").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .savingsPanel()
                Text("跨币种转账的 CSV 不含实际转入金额，将按 1:1 占位，导入后可在流水编辑器中修正。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
        }
        .frame(width: 560, height: 560)
    }

    private func confirm() {
        let written = LedgerCSVImporter.apply(context.plan, to: store)
        store.notice = "导入完成：新增 \(written) 条流水，跳过重复 \(context.plan.duplicatesSkipped) 条"
            + (context.plan.newAccounts.isEmpty ? "。" : "，新建账户 \(context.plan.newAccounts.count) 个。")
        dismiss()
    }
}
