import CryptoKit
import Foundation

enum CSVReviewDecision: String, Codable { case pending, apply, skip }
enum CSVReviewStatus: String, Codable { case pending, applied, skipped, undone }

struct CSVReviewFields: Codable, Equatable {
    var date = "", kind = "", accountName = "", targetAccountName = "", categoryName = "", note = ""
    var amount = "", currency = "", targetAmount = "", targetCurrency = ""

    static let columns: [WritableKeyPath<Self, String>] = [
        \.date, \.kind, \.accountName, \.targetAccountName, \.categoryName, \.note,
        \.amount, \.currency, \.targetAmount, \.targetCurrency
    ]
}

struct CSVReviewRow: Codable, Identifiable, Equatable {
    let id: String
    let line: Int
    var fields: CSVReviewFields
    var date: Date?
    var timeZoneIdentifier: String?
    var ambiguousTime = false
    var extraCells = false
    var status: CSVReviewStatus = .pending
    var entryID: String?
}

struct CSVReviewBatch: Codable, Identifiable {
    let id: String
    let name: String
    let createdAt: Date
    var rows: [CSVReviewRow]
    var generation = 0
    var entries: [LedgerEntry] = []
    var receipts: [String] = []
    var canUndo: Bool { !entries.isEmpty }
}

struct CSVReviewArchive: Codable {
    var version = 1
    var batches: [CSVReviewBatch] = []

    func validate() throws {
        let allEntryIDs = batches.flatMap { $0.entries.map(\.id) }
        guard version == 1, Set(batches.map(\.id)).count == batches.count,
              Set(allEntryIDs).count == allEntryIDs.count,
              batches.allSatisfy({ batch in
                  let applied = batch.rows.filter { $0.status == .applied }
                  let owned = Set(batch.entries.map(\.id))
                  return batch.generation >= 0 && batch.generation < Int.max &&
                      Set(batch.rows.map(\.id)).count == batch.rows.count &&
                      applied.allSatisfy { $0.entryID != nil } &&
                      Set(applied.compactMap(\.entryID)) == owned
              }) else { throw CSVReviewError.protected }
    }
}

/// Preserve the Windows inbox in a library moved between platforms without decoding its private schema.
enum CSVReviewForeignJSON: Codable {
    case object([String: CSVReviewForeignJSON]), array([CSVReviewForeignJSON])
    case string(String), number(Decimal), boolean(Bool), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode([String: CSVReviewForeignJSON].self) { self = .object(value) }
        else if let value = try? container.decode([CSVReviewForeignJSON].self) { self = .array(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else { self = .number(try container.decode(Decimal.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct CSVReviewRowAssessment: Identifiable {
    let row: CSVReviewRow
    let problems: [String]
    let duplicates: [String]
    let notices: [String]
    var id: String { row.id }
    var canApply: Bool { row.status == .pending && problems.isEmpty }
}

struct CSVReviewPair: Identifiable {
    let expenseID: String
    let incomeID: String
    let sourceName: String
    let targetName: String
    let currency: SavingsCurrency
    let amount: Decimal
    let duplicates: [String]
    var id: String { "\(expenseID):\(incomeID)" }
}

struct CSVReviewDetail {
    let batch: CSVReviewBatch
    let revision: String
    let rows: [CSVReviewRowAssessment]
    let pairs: [CSVReviewPair]
}

enum CSVReviewError: LocalizedError {
    case protected, empty, limit, malformed, header, missingBatch, confirmation, stale, invalidChoice, blocked, duplicate, undoConflict

    var errorDescription: String? {
        switch self {
        case .protected: tS("审核资料受到保护，不能写入。", "The review library is protected and cannot be changed.")
        case .empty: tS("CSV 中没有可审核的流水。", "The CSV contains no rows to review.")
        case .limit: tS("每批最多审核 2,000 行，请拆分 CSV。", "Split this CSV into batches of up to 2,000 rows.")
        case .malformed: tS("CSV 的引号或列格式无法读取。", "The CSV quotation or column format is invalid.")
        case .header: tS("未识别 CSV 列名，请使用流水 CSV 表头。", "The CSV headings are not recognized. Use the transaction CSV headings.")
        case .missingBatch: tS("没有找到此审核批次。", "This review batch was not found.")
        case .confirmation: tS("请先确认审核操作。", "Confirm the review before saving.")
        case .stale: tS("审核内容或账本已更新，请刷新批次后确认。", "The review or ledger changed. Refresh the batch and confirm again.")
        case .invalidChoice: tS("审核选择和当前待审核流水不一致，请刷新后重试。", "The review choices no longer match the pending rows. Refresh and try again.")
        case .blocked: tS("有流水仍缺少必填信息，请修改或留待审核。", "Some rows need details. Correct them or leave them pending.")
        case .duplicate: tS("请逐条确认是否保留疑似重复流水。", "Confirm each suspected duplicate you want to keep.")
        case .undoConflict: tS("本批有流水已修改、删除或关联积蓄记录，未撤销任何流水。", "This batch contains changed, deleted or savings-linked entries. No entries were removed.")
        }
    }
}

private enum CSVReviewParser {
    private static let headings = [
        ["日期", "时间", "交易日期", "date", "datetime", "transaction date"],
        ["类型", "方向", "type", "kind", "direction"],
        ["账户", "转出账户", "account", "account name", "source account"],
        ["目标账户", "转入账户", "target account", "destination account"],
        ["分类", "类别", "category"],
        ["备注", "摘要", "描述", "note", "memo", "description"],
        ["金额", "转出金额", "amount"],
        ["币种", "货币", "currency", "currency code"],
        ["转入金额", "目标金额", "target amount", "destination amount", "received amount"],
        ["转入币种", "目标币种", "target currency", "destination currency", "received currency"]
    ]

    static func parse(_ text: String, calendar: Calendar) throws -> [CSVReviewRow] {
        guard !text.contains("\0") else { throw CSVReviewError.malformed }
        guard text.utf8.count <= 8_000_000, text.count <= 2_000_000 else { throw CSVReviewError.limit }
        let records = try tokenize(text)
        guard let first = records.first else { throw CSVReviewError.empty }
        let mapped = first.fields.map { field in headings.firstIndex { $0.contains(key(field)) } }
        let known = mapped.compactMap { $0 }
        let layout: [Int?], data: ArraySlice<(line: Int, fields: [String])>
        if known.count >= 2 {
            guard Set(known).count == known.count else { throw CSVReviewError.malformed }
            layout = mapped
            data = records.dropFirst()
        } else if first.fields.count >= 8, parseDate(first.fields[0], calendar: calendar).date != nil {
            layout = Array(0..<8).map(Optional.some)
            data = records[...]
        } else { throw CSVReviewError.header }
        guard !data.isEmpty else { throw CSVReviewError.empty }
        guard data.count <= 2_000 else { throw CSVReviewError.limit }
        return data.enumerated().map { index, record in
            var fields = CSVReviewFields()
            for (column, value) in zip(layout, record.fields) {
                if let column { fields[keyPath: CSVReviewFields.columns[column]] = value }
            }
            var row = CSVReviewRow(id: String(index + 1), line: record.line, fields: fields,
                                   extraCells: record.fields.dropFirst(layout.count).contains { !$0.isEmpty })
            stamp(&row, calendar: calendar)
            return row
        }
    }

    static func clean(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    static func key(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping.lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func tokenize(_ text: String) throws -> [(line: Int, fields: [String])] {
        enum Mode: Equatable { case field, quoted, closed }
        let stripped = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let normalized = stripped.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var records: [(Int, [String])] = [], fields: [String] = [], field = ""
        var mode = Mode.field, line = 1, start = 1
        func finishField() {
            fields.append(clean(field)); field = ""; mode = .field
        }
        func finishRecord() throws {
            finishField()
            if fields.contains(where: { !$0.isEmpty }) { records.append((start, fields)) }
            guard records.count <= 2_001, fields.count <= 100 else { throw CSVReviewError.limit }
            fields.removeAll(keepingCapacity: true)
        }
        for scalar in normalized.unicodeScalars {
            switch (mode, scalar) {
            case (.quoted, "\""): mode = .closed
            case (.closed, "\""): field.append("\""); mode = .quoted
            case (.field, "\"") where field.isEmpty: mode = .quoted
            case (.field, "\""): throw CSVReviewError.malformed
            case (.quoted, _): field.unicodeScalars.append(scalar)
            case (_, ","): finishField()
            case (_, "\n"): try finishRecord(); start = line + 1
            case (.closed, _): throw CSVReviewError.malformed
            case (.field, _): field.unicodeScalars.append(scalar)
            }
            if scalar == "\n" { line += 1 }
        }
        guard mode != .quoted else { throw CSVReviewError.malformed }
        if !field.isEmpty || !fields.isEmpty || mode == .closed { try finishRecord() }
        return records
    }

    static func stamp(_ row: inout CSVReviewRow, calendar: Calendar) {
        let result = parseDate(row.fields.date, calendar: calendar)
        row.date = result.date
        row.timeZoneIdentifier = result.local ? calendar.timeZone.identifier : nil
        row.ambiguousTime = result.ambiguous
    }

    private static func parseDate(_ input: String, calendar: Calendar) -> (date: Date?, local: Bool, ambiguous: Bool) {
        let text = clean(input)
        if let offset = text.range(of: #"(Z|[-+]\d{2}:?\d{2})$"#, options: .regularExpression), text.count > 10 {
            let wall = text[..<offset.lowerBound].replacingOccurrences(of: " ", with: "T")
            let offsetText = String(text[offset])
            guard wall.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?$"#,
                             options: .regularExpression) != nil else { return (nil, false, false) }
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(secondsFromGMT: 0)!
            guard let wholeSeconds = wall.split(separator: ".", maxSplits: 1).first,
                  parseDate(String(wholeSeconds), calendar: utc).date != nil else { return (nil, false, false) }
            let iso = wall.count == 16 ? wall + ":00" + offsetText : wall + offsetText
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: iso) { return (date, false, false) }
            formatter.formatOptions = [.withInternetDateTime]
            return (formatter.date(from: iso), false, false)
        }
        guard text.range(of: #"^\d{4}-\d{2}-\d{2}([ T]\d{2}:\d{2}(:\d{2})?)?$"#, options: .regularExpression) != nil else {
            return (nil, false, false)
        }
        let values = text.split(whereSeparator: { "- T:".contains($0) }).compactMap { Int($0) }
        guard values.count >= 3, (1...9999).contains(values[0]), (1...12).contains(values[1]), (1...31).contains(values[2]) else {
            return (nil, true, false)
        }
        let hours = values.count > 3 ? values[3] : 0, minutes = values.count > 4 ? values[4] : 0
        let seconds = values.count > 5 ? values[5] : 0
        guard hours < 24, minutes < 60, seconds < 60 else { return (nil, true, false) }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: values[0], month: values[1], day: values[2], hour: hours, minute: minutes, second: seconds)
        let componentKeys: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        guard let wallTime = utc.date(from: components) else { return (nil, true, false) }
        let roundTrip = utc.dateComponents(componentKeys, from: wallTime)
        guard roundTrip.year == components.year, roundTrip.month == components.month, roundTrip.day == components.day,
              roundTrip.hour == components.hour, roundTrip.minute == components.minute,
              roundTrip.second == components.second else { return (nil, true, false) }
        let zone = calendar.timeZone
        // Try offsets on both sides of a clock change. Keep only instants whose actual offset reconstructs the input wall time.
        let offsets = Set(stride(from: -36, through: 36, by: 6).map { hours in
            zone.secondsFromGMT(for: wallTime.addingTimeInterval(TimeInterval(hours * 3_600)))
        })
        let matches = offsets.compactMap { offset -> Date? in
            let candidate = wallTime.addingTimeInterval(-TimeInterval(offset))
            return zone.secondsFromGMT(for: candidate) == offset ? candidate : nil
        }
        return matches.count > 1 ? (nil, true, true) : (matches.first, true, false)
    }
}

private enum CSVReviewPlanner {
    fileprivate struct Account: Hashable {
        let id: String?
        let name: String
        let currency: SavingsCurrency
        var key: String { id ?? "new:\(name)" }
    }

    fileprivate struct MatchKey: Hashable {
        let day: Date
        let kind: LedgerEntryKind
        let source: String
        let currency: SavingsCurrency?
        let amount: Decimal
        let target: String?
        let targetAmount: Decimal?
    }

    fileprivate struct Transaction {
        let kind: LedgerEntryKind
        let source: Account
        let target: Account?
        let amount: Decimal
        let targetAmount: Decimal?
        let category: String
        let date: Date
        let note: String

        func key(_ calendar: Calendar) -> MatchKey {
            MatchKey(day: calendar.startOfDay(for: date), kind: kind, source: source.key, currency: source.currency,
                     amount: amount, target: target?.key, targetAmount: targetAmount)
        }
    }

    private struct Assessment {
        let row: CSVReviewRow
        let transaction: Transaction?
        let transferLeg: Bool
        let problems: [String]
        let notices: [String]
        var duplicates: [String] = []
    }

    struct Plan {
        let rows: [CSVReviewRowAssessment]
        let pairs: [CSVReviewPair]
        fileprivate let direct: [String: Transaction]
        fileprivate let transfers: [String: Transaction]
    }

    private static func account(named name: String, code: String, target: Bool, current: [LedgerAccount],
                                problems: inout [String], notices: inout [String]) -> Account? {
        guard !name.isEmpty else {
            problems.append(target ? tS("缺少转入账户。", "Destination account is missing.") : tS("缺少转出账户。", "Source account is missing."))
            return nil
        }
        let requested = SavingsCurrency(rawValue: code.uppercased())
        guard code.isEmpty || requested != nil else {
            problems.append(tS("币种无法识别。", "The currency is not recognized."))
            return nil
        }
        let matching = current.filter { $0.name == name }
        guard matching.count <= 1 else {
            problems.append(tS("有多个同名账户，请先核对账户。", "More than one account has this name. Resolve the ambiguity first."))
            return nil
        }
        if let matched = matching.first {
            guard !matched.isArchived else {
                problems.append(tS("账户已归档，请选择其他账户。", "The account is archived. Choose another account."))
                return nil
            }
            guard requested == nil || requested == matched.currency else {
                problems.append(tS("CSV 币种与账户币种不一致。", "The CSV currency differs from the account currency."))
                return nil
            }
            return Account(id: matched.id, name: matched.name, currency: matched.currency)
        }
        guard let requested else {
            problems.append(tS("新账户缺少币种。", "Specify the currency for the new account."))
            return nil
        }
        notices.append(tS("确认入账时会新建现金账户 \(name)（\(requested.rawValue)）。",
                          "Recording this row creates the cash account \(name) (\(requested.rawValue))."))
        return Account(id: nil, name: name, currency: requested)
    }

    private static func amount(_ raw: String, currency: SavingsCurrency?, target: Bool,
                               problems: inout [String]) -> (value: Decimal?, sign: Character?) {
        var value = CSVReviewParser.clean(raw.precomposedStringWithCompatibilityMapping).replacingOccurrences(of: "−", with: "-")
        if value.hasPrefix("("), value.hasSuffix(")") { value = "-" + CSVReviewParser.clean(String(value.dropFirst().dropLast())) }
        var sign: Character?
        func takeSign() {
            if sign == nil, let first = value.first, first == "+" || first == "-" { sign = value.removeFirst() }
        }
        takeSign()
        let symbols: [Character: Set<SavingsCurrency>] = [
            "¥": [.CNY, .JPY], "$": [.USD, .HKD, .TWD, .SGD, .AUD, .CAD],
            "€": [.EUR], "£": [.GBP], "₩": [.KRW]
        ]
        if let first = value.first, let allowed = symbols[first] {
            if let currency, !allowed.contains(currency) {
                problems.append(tS("金额符号与币种不一致。", "The amount symbol does not match the currency."))
                return (nil, sign)
            }
            value = CSVReviewParser.clean(String(value.dropFirst()))
            takeSign()
        }
        guard !raw.isEmpty else {
            problems.append(target ? tS("缺少实际转入金额。", "The actual amount received is missing.") : tS("缺少金额。", "The amount is missing."))
            return (nil, sign)
        }
        guard value.range(of: #"^(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
              !(target && sign == "-") else {
            problems.append(tS("金额格式或符号不正确。", "The amount or sign is invalid."))
            return (nil, sign)
        }
        let digits = currency?.fractionDigits ?? 2
        if let decimalPoint = value.firstIndex(of: "."), value[value.index(after: decimalPoint)...].dropFirst(digits).contains(where: { $0 != "0" }) {
            problems.append(tS("金额超出币种小数精度，请核对原金额。", "The amount exceeds the currency precision. Check the original value."))
            return (nil, sign)
        }
        let wholeAndFraction = value.replacingOccurrences(of: ",", with: "").split(separator: ".", omittingEmptySubsequences: false)
        let fraction = wholeAndFraction.count == 2 && digits > 0 ? "." + String(wholeAndFraction[1].prefix(digits)) : ""
        let significant = String(wholeAndFraction[0]) + fraction
        guard let decimal = Decimal(string: significant, locale: Locale(identifier: "en_US_POSIX")),
              decimal > 0, decimal <= Decimal(999_999_999_999) + Decimal(99) / 100 else {
            problems.append(tS("金额须为有效的正数。", "The amount must be a valid positive number."))
            return (nil, sign)
        }
        return (decimal, sign)
    }

    private static func category(for value: String, kind: LedgerEntryKind, notices: inout [String]) -> String? {
        if kind == .transfer { return "account-transfer" }
        if value == "余额调整" || value == LedgerEntry.balanceAdjustmentCategoryID || CSVReviewParser.key(value) == "balance adjustment" {
            return LedgerEntry.balanceAdjustmentCategoryID
        }
        if let category = SavingsCatalog.ledgerCategories.first(where: {
            $0.kind == kind && (CSVReviewParser.key($0.name) == CSVReviewParser.key(value) || $0.id == value)
        }) { return category.id }
        if let fallback = SavingsCatalog.ledgerCategories.first(where: { $0.kind == kind }) {
            notices.append(tS("确认时采用默认分类 \(fallback.name)。", "The default category \(fallback.name) will be used."))
            return fallback.id
        }
        return nil
    }

    private static func assess(_ row: CSVReviewRow, current: [LedgerAccount]) -> Assessment {
        var problems: [String] = [], notices: [String] = []
        let fields = row.fields
        if row.extraCells { notices.append(tS("原 CSV 有表头之外的值，请核对是否错列。", "The CSV has values beyond its header. Check column alignment.")) }
        if row.date == nil {
            problems.append(row.ambiguousTime ? tS("本地时间有两种可能，请填写 ISO 时间和 UTC 偏移。", "This local time is ambiguous. Specify an ISO timestamp with a UTC offset.") :
                            tS("日期缺失或格式无效，请核对时区和日期。", "The date is missing or invalid. Check the date and time zone."))
        } else if let timezone = row.timeZoneIdentifier {
            notices.append(tS("无偏移时间已按 \(timezone) 解释。", "The time without an offset was interpreted in \(timezone)."))
        }
        let source = account(named: fields.accountName, code: fields.currency, target: false,
                             current: current, problems: &problems, notices: &notices)
        let parsed = amount(fields.amount, currency: source?.currency, target: false, problems: &problems)
        let kindText = CSVReviewParser.key(fields.kind)
        let kind: LedgerEntryKind? = switch kindText {
        case "支出", "expense", "debit": .expense
        case "收入", "income", "credit": .income
        case "转账", "transfer": .transfer
        case "": parsed.sign.map { $0 == "-" ? .expense : .income }
        default: nil
        }
        guard let kind else {
            problems.append(tS("请填写收支方向。", "Specify the transaction direction."))
            return Assessment(row: row, transaction: nil, transferLeg: false, problems: problems, notices: notices)
        }
        if (kind == .income && parsed.sign == "-") || (kind == .expense && parsed.sign == "+") {
            problems.append(tS("金额符号与收支方向冲突。", "The amount sign conflicts with the transaction direction."))
        }
        let transferLabels: Set<String> = ["转账", "划转", "账户互转", "账户转账", "transfer", "account transfer", "account-transfer"]
        let memo = CSVReviewParser.key(fields.note)
        let transferLeg = kind != .transfer && (transferLabels.contains(CSVReviewParser.key(fields.categoryName)) ||
            transferLabels.contains(where: { memo == $0 || memo.hasPrefix($0 + " ") || memo.hasSuffix(" " + $0) }))
        var target: Account?, received: Decimal?
        if kind == .transfer {
            let targetCode = fields.targetCurrency
            target = account(named: fields.targetAccountName, code: targetCode, target: true, current: current,
                             problems: &problems, notices: &notices)
            if let source, let target {
                if target.key == source.key { problems.append(tS("转入和转出账户必须不同。", "The source and destination must be different.")) }
                if source.currency != target.currency || !fields.targetAmount.isEmpty {
                    received = amount(fields.targetAmount, currency: target.currency, target: true, problems: &problems).value
                    if let received, source.currency == target.currency, received != parsed.value {
                        problems.append(tS("同币种转账的转出和转入金额必须相同。", "Both amounts must match for same-currency transfers."))
                    }
                } else { received = parsed.value }
            }
        }
        let categoryID = category(for: fields.categoryName, kind: kind, notices: &notices)
        let transaction: Transaction?
        if let source, let value = parsed.value, let date = row.date, let categoryID {
            transaction = Transaction(kind: kind, source: source, target: target, amount: value, targetAmount: received,
                                      category: categoryID, date: date, note: fields.note)
        } else { transaction = nil }
        return Assessment(row: row, transaction: transaction, transferLeg: transferLeg, problems: problems, notices: notices)
    }

    private static func ledgerDuplicates(_ transaction: Transaction, index: [MatchKey: [LedgerEntry]], calendar: Calendar) -> [String] {
        guard let matches = index[transaction.key(calendar)], !matches.isEmpty else { return [] }
        let exact = matches.contains { entry in
            minute(entry.date) == minute(transaction.date) && entry.categoryID == transaction.category &&
                CSVReviewParser.key(entry.note) == CSVReviewParser.key(transaction.note)
        }
        return [exact ? tS("账本已有同一分钟、同账户、同币种、同金额、同分类和同备注的流水。", "The ledger has a row with the same minute, account, currency, amount, category and note.") :
                    tS("账本同一天已有同账户、方向、币种和金额的流水。", "The ledger has an entry on the same day with the same account, direction, currency and amount.")]
    }

    private static func minute(_ date: Date) -> TimeInterval { (date.timeIntervalSince1970 / 60).rounded(.down) }

    private static func matches(_ proposed: String, name: String) -> Bool { proposed.isEmpty || proposed == name }

    static func analyze(_ batch: CSVReviewBatch, accounts: [LedgerAccount], entries: [LedgerEntry], calendar: Calendar) -> Plan {
        let currencies = Dictionary(accounts.map { ($0.id, $0.currency) }, uniquingKeysWith: { first, _ in first })
        var ledger: [MatchKey: [LedgerEntry]] = [:]
        for entry in entries {
            let key = MatchKey(day: calendar.startOfDay(for: entry.date), kind: entry.kind, source: entry.accountID,
                               currency: currencies[entry.accountID], amount: entry.amountValue, target: entry.targetAccountID,
                               targetAmount: entry.kind == .transfer ? entry.targetAmountValue ?? entry.amountValue : nil)
            ledger[key, default: []].append(entry)
        }
        var rows = batch.rows.map { assess($0, current: accounts) }
        var seen: [MatchKey: [(Int, Transaction)]] = [:]
        var direct: [String: Transaction] = [:]
        for index in rows.indices {
            let item = rows[index]
            guard item.row.status == .pending, item.problems.isEmpty, let transaction = item.transaction else { continue }
            rows[index].duplicates = ledgerDuplicates(transaction, index: ledger, calendar: calendar)
            let key = transaction.key(calendar)
            if let prior = seen[key]?.first(where: { _, other in
                minute(other.date) == minute(transaction.date) && other.category == transaction.category &&
                    CSVReviewParser.key(other.note) == CSVReviewParser.key(transaction.note)
            }) {
                rows[index].duplicates.append(tS("CSV 第 \(prior.0) 行的时间、账户、金额和备注相同。",
                                                 "CSV line \(prior.0) has the same minute, account, amount and note."))
            } else if let prior = seen[key]?.first {
                rows[index].duplicates.append(tS("CSV 第 \(prior.0) 行有同日、同账户、同方向和金额的流水。",
                                                 "CSV line \(prior.0) has the same day, account, direction and amount."))
            }
            seen[key, default: []].append((item.row.line, transaction))
            if !item.transferLeg { direct[item.row.id] = transaction }
        }

        struct PairKey: Hashable { let day: Date; let currency: SavingsCurrency; let amount: Decimal }
        var groups: [PairKey: [Int]] = [:]
        for index in rows.indices {
            let item = rows[index]
            guard item.row.status == .pending, item.transferLeg, item.problems.isEmpty,
                  let transaction = item.transaction, transaction.source.id != nil else { continue }
            let key = PairKey(day: calendar.startOfDay(for: transaction.date), currency: transaction.source.currency, amount: transaction.amount)
            groups[key, default: []].append(index)
        }
        var pairs: [CSVReviewPair] = []
        var transfers: [String: Transaction] = [:]
        for group in groups.values {
            guard group.count == 2,
                  let expenseIndex = group.first(where: { rows[$0].transaction?.kind == .expense }),
                  let incomeIndex = group.first(where: { rows[$0].transaction?.kind == .income }),
                  let expense = rows[expenseIndex].transaction, let income = rows[incomeIndex].transaction,
                  expense.source.key != income.source.key else { continue }
            let outgoing = rows[expenseIndex].row, incoming = rows[incomeIndex].row
            guard matches(outgoing.fields.targetAccountName, name: income.source.name),
                  matches(incoming.fields.targetAccountName, name: expense.source.name),
                  matches(outgoing.fields.targetCurrency.uppercased(), name: income.source.currency.rawValue),
                  matches(incoming.fields.targetCurrency.uppercased(), name: expense.source.currency.rawValue),
                  outgoing.fields.targetAmount.isEmpty, incoming.fields.targetAmount.isEmpty else { continue }
            let note = [expense.note, income.note == expense.note ? "" : income.note].filter { !$0.isEmpty }.joined(separator: " · ")
            let transaction = Transaction(kind: .transfer, source: expense.source, target: income.source,
                                          amount: expense.amount, targetAmount: income.amount, category: "account-transfer",
                                          date: expense.date, note: note)
            var duplicates = ledgerDuplicates(transaction, index: ledger, calendar: calendar)
            if let other = seen[transaction.key(calendar)]?.first {
                duplicates.append(tS("CSV 第 \(other.0) 行已列出同方向和金额的转账。",
                                     "CSV line \(other.0) already lists a transfer with the same direction and amount."))
            }
            let pair = CSVReviewPair(expenseID: outgoing.id, incomeID: incoming.id,
                                     sourceName: expense.source.name, targetName: income.source.name,
                                     currency: expense.source.currency, amount: expense.amount, duplicates: duplicates)
            pairs.append(pair)
            transfers[pair.id] = transaction
        }
        pairs.sort { (Int($0.expenseID) ?? 0) < (Int($1.expenseID) ?? 0) }
        let publicRows = rows.map { item in
            guard item.row.status == .pending else { return CSVReviewRowAssessment(row: item.row, problems: [], duplicates: [], notices: []) }
            let legProblem = tS("此行是单边转账，请选择配对或补齐转账资料。", "This is one side of a transfer. Match it or complete the transfer details.")
            return CSVReviewRowAssessment(row: item.row, problems: item.problems + (item.transferLeg ? [legProblem] : []),
                                          duplicates: item.duplicates, notices: item.notices)
        }
        return Plan(rows: publicRows, pairs: pairs, direct: direct, transfers: transfers)
    }

    private struct Posting {
        let ids: [String]
        let transaction: Transaction
    }

    static func post(_ plan: Plan, batch: inout CSVReviewBatch, decisions: [String: CSVReviewDecision],
                     pairs: Set<String>, overrides: Set<String>, accounts: inout [LedgerAccount],
                     entries: inout [LedgerEntry], lastAccountID: inout String?,
                     calendar: Calendar, now: Date) throws {
        let pending = Set(batch.rows.filter { $0.status == .pending }.map(\.id))
        let assessed = Dictionary(uniqueKeysWithValues: plan.rows.map { ($0.id, $0) })
        guard Set(decisions.keys).isSubset(of: pending), overrides.isSubset(of: pending),
              pairs.isSubset(of: Set(plan.transfers.keys)) else { throw CSVReviewError.invalidChoice }
        var posting: [Posting] = []
        var pairedRows = Set<String>()
        for pair in plan.pairs where pairs.contains(pair.id) {
            let ids = [pair.expenseID, pair.incomeID]
            guard let transaction = plan.transfers[pair.id], ids.allSatisfy({ decisions[$0] == nil || decisions[$0] == .pending }),
                  ids.allSatisfy({ pairedRows.insert($0).inserted }) else { throw CSVReviewError.invalidChoice }
            guard pair.duplicates.isEmpty || ids.allSatisfy({ overrides.contains($0) }) else { throw CSVReviewError.duplicate }
            for id in ids where assessed[id]?.duplicates.isEmpty == false && !overrides.contains(id) {
                throw CSVReviewError.duplicate
            }
            posting.append(Posting(ids: ids, transaction: transaction))
        }
        for row in batch.rows where decisions[row.id] == .apply {
            guard let transaction = plan.direct[row.id] else { throw CSVReviewError.blocked }
            guard assessed[row.id]?.duplicates.isEmpty != false || overrides.contains(row.id) else { throw CSVReviewError.duplicate }
            posting.append(Posting(ids: [row.id], transaction: transaction))
        }
        var postedKeys = Set<MatchKey>()
        var created: [String: LedgerAccount] = [:]
        var result: [String: String] = [:]
        func resolve(_ account: Account) throws -> String {
            if let id = account.id { return id }
            if let existing = created[account.name] {
                guard existing.currency == account.currency else { throw CSVReviewError.blocked }
                return existing.id
            }
            let added = LedgerAccount(id: UUID().uuidString, name: account.name, type: .cash, currency: account.currency,
                                      openingBalance: 0, symbol: LedgerAccountType.cash.symbol,
                                      colorKey: "teal", includeInNetWorth: true, isArchived: false, createdAt: now)
            created[account.name] = added
            accounts.append(added)
            return added.id
        }
        for item in posting {
            let transaction = item.transaction
            if !postedKeys.insert(transaction.key(calendar)).inserted, !item.ids.allSatisfy({ overrides.contains($0) }) {
                throw CSVReviewError.duplicate
            }
            let source = try resolve(transaction.source), target = try transaction.target.map(resolve)
            var entry = LedgerEntry(id: UUID().uuidString, kind: transaction.kind, accountID: source,
                                    targetAccountID: target, amount: 0, targetAmount: nil, categoryID: transaction.category,
                                    date: transaction.date, note: transaction.note, createdAt: now)
            entry.amountValue = transaction.amount
            entry.targetAmountValue = transaction.targetAmount
            entries.append(entry)
            batch.entries.append(entry)
            lastAccountID = source
            for id in item.ids { result[id] = entry.id }
        }
        for index in batch.rows.indices {
            let id = batch.rows[index].id
            if let entryID = result[id] {
                batch.rows[index].status = .applied
                batch.rows[index].entryID = entryID
            } else if decisions[id] == .skip {
                batch.rows[index].status = .skipped
            }
        }
        if !posting.isEmpty { entries.sort { $0.date > $1.date } }
    }
}

private struct CSVReviewRequest: Encodable {
    let action: String
    let revision: String
    var decisions: [String: CSVReviewDecision] = [:]
    var edits: [String: CSVReviewFields] = [:]
    var pairs: [String] = []
    var overrides: [String] = []
}

extension SavingsStore {
    @discardableResult
    func stageCSVReview(text: String, name: String) throws -> CSVReviewDetail {
        try requireCSVReview()
        let calendar = snapshotCalendar()
        let rows = try CSVReviewParser.parse(text, calendar: calendar)
        struct ContentRow: Encodable { let fields: CSVReviewFields; let extraCells: Bool }
        let id = try csvReviewDigest(rows.map { ContentRow(fields: $0.fields, extraCells: $0.extraCells) })
        var archive = csvReviewArchive ?? CSVReviewArchive()
        if let existing = archive.batches.first(where: { $0.id == id }) { return try csvReviewDetail(for: existing, calendar: calendar) }
        let cleanName = String(CSVReviewParser.clean(name).prefix(160))
        let batch = CSVReviewBatch(id: id, name: cleanName.isEmpty ? "CSV" : cleanName, createdAt: snapshotNow(), rows: rows)
        archive.batches.insert(batch, at: 0)
        try commitCSVReview(archive, accounts: accounts, entries: ledgerEntries, lastAccountID: lastLedgerAccountID)
        return try csvReviewDetail(for: batch, calendar: calendar)
    }

    func csvReviewDetail(_ batchID: String) throws -> CSVReviewDetail {
        try requireCSVReview()
        guard let batch = csvReviewBatches.first(where: { $0.id == batchID }) else { throw CSVReviewError.missingBatch }
        return try csvReviewDetail(for: batch, calendar: snapshotCalendar())
    }

    @discardableResult
    func applyCSVReview(batchID: String, revision: String, decisions: [String: CSVReviewDecision],
                        edits: [String: CSVReviewFields] = [:], pairs: Set<String> = [],
                        overrideDuplicates: Set<String> = [], confirmed: Bool) throws -> CSVReviewDetail {
        let request = CSVReviewRequest(action: "apply", revision: revision, decisions: decisions, edits: edits,
                                       pairs: pairs.sorted(), overrides: overrideDuplicates.sorted())
        let (stored, index, receipt, replay, calendar) = try csvReviewOperation(batchID, request: request, confirmed: confirmed)
        var archive = stored
        let original = archive.batches[index]
        if replay { return try csvReviewDetail(for: original, calendar: calendar) }
        var batch = original
        let pending = Set(batch.rows.filter { $0.status == .pending }.map(\.id))
        guard Set(edits.keys).isSubset(of: pending) else { throw CSVReviewError.invalidChoice }
        for rowIndex in batch.rows.indices {
            guard var fields = edits[batch.rows[rowIndex].id] else { continue }
            let previous = batch.rows[rowIndex].fields
            for column in CSVReviewFields.columns {
                let input = CSVReviewParser.clean(fields[keyPath: column])
                guard !input.contains("\0"), input.count <= 2_000 || input == previous[keyPath: column] else {
                    throw CSVReviewError.invalidChoice
                }
                fields[keyPath: column] = input
            }
            batch.rows[rowIndex].fields = fields
            if fields.date != previous.date { CSVReviewParser.stamp(&batch.rows[rowIndex], calendar: calendar) }
        }
        let plan = CSVReviewPlanner.analyze(batch, accounts: accounts, entries: ledgerEntries, calendar: calendar)
        var newAccounts = accounts, newEntries = ledgerEntries, lastAccountID = lastLedgerAccountID
        try CSVReviewPlanner.post(plan, batch: &batch, decisions: decisions, pairs: pairs, overrides: overrideDuplicates,
                                  accounts: &newAccounts, entries: &newEntries, lastAccountID: &lastAccountID,
                                  calendar: calendar, now: snapshotNow())
        if batch.rows == original.rows { return try csvReviewDetail(for: original, calendar: calendar) }
        markCSVReview(&batch, receipt: receipt)
        archive.batches[index] = batch
        try commitCSVReview(archive, accounts: newAccounts, entries: newEntries, lastAccountID: lastAccountID)
        return try csvReviewDetail(for: batch, calendar: calendar)
    }

    @discardableResult
    func undoCSVReview(batchID: String, revision: String, confirmed: Bool) throws -> CSVReviewDetail {
        let request = CSVReviewRequest(action: "undo", revision: revision)
        let (stored, index, receipt, replay, calendar) = try csvReviewOperation(batchID, request: request, confirmed: confirmed)
        var archive = stored
        var batch = archive.batches[index]
        if replay || batch.entries.isEmpty { return try csvReviewDetail(for: batch, calendar: calendar) }
        let current = Dictionary(grouping: ledgerEntries, by: \.id)
        let linked = Set(records.compactMap(\.ledgerEntryID))
        guard batch.entries.allSatisfy({ !linked.contains($0.id) && current[$0.id] == [$0] }) else {
            throw CSVReviewError.undoConflict
        }
        let removed = Set(batch.entries.map(\.id))
        batch.entries.removeAll()
        for rowIndex in batch.rows.indices where batch.rows[rowIndex].status == .applied {
            batch.rows[rowIndex].status = .undone
        }
        markCSVReview(&batch, receipt: receipt)
        archive.batches[index] = batch
        try commitCSVReview(archive, accounts: accounts, entries: ledgerEntries.filter { !removed.contains($0.id) },
                            lastAccountID: lastLedgerAccountID)
        return try csvReviewDetail(for: batch, calendar: calendar)
    }

    private func requireCSVReview() throws {
        guard !loadFailed, hasLoadedValidLibrary else { throw CSVReviewError.protected }
    }

    private func csvReviewDigest(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    private func csvReviewRevision(_ batch: CSVReviewBatch, calendar: Calendar) throws -> String {
        try csvReviewDigest([String(batch.generation), financialFingerprint(), calendar.timeZone.identifier, String(describing: calendar.identifier)])
    }

    private func csvReviewDetail(for batch: CSVReviewBatch, calendar: Calendar) throws -> CSVReviewDetail {
        let plan = CSVReviewPlanner.analyze(batch, accounts: accounts, entries: ledgerEntries, calendar: calendar)
        return CSVReviewDetail(batch: batch, revision: try csvReviewRevision(batch, calendar: calendar), rows: plan.rows, pairs: plan.pairs)
    }

    private func csvReviewOperation(_ batchID: String, request: CSVReviewRequest, confirmed: Bool) throws
        -> (CSVReviewArchive, Int, String, Bool, Calendar) {
        try requireCSVReview()
        guard confirmed else { throw CSVReviewError.confirmation }
        guard let archive = csvReviewArchive, let index = archive.batches.firstIndex(where: { $0.id == batchID }) else {
            throw CSVReviewError.missingBatch
        }
        let calendar = snapshotCalendar()
        let receipt = try csvReviewDigest(request)
        let batch = archive.batches[index]
        if batch.receipts.contains(receipt) { return (archive, index, receipt, true, calendar) }
        guard request.revision == (try csvReviewRevision(batch, calendar: calendar)) else { throw CSVReviewError.stale }
        return (archive, index, receipt, false, calendar)
    }

    private func markCSVReview(_ batch: inout CSVReviewBatch, receipt: String) {
        batch.generation += 1
        batch.receipts = Array((batch.receipts + [receipt]).suffix(256))
    }
}
