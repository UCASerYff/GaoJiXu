import Foundation

/// Gregorian accounting months use the user's local time zone, independent of display language/calendar.
enum FixedIncomePeriod {
    static func calendar(_ zone: TimeZone = .autoupdatingCurrent) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    static func key(_ date: Date, zone: TimeZone = .autoupdatingCurrent) -> String {
        let parts = calendar(zone).dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    static func components(_ key: String) -> (year: Int, month: Int)? {
        let bytes = Array(key.utf8)
        guard bytes.count == 7, bytes[4] == 45,
              bytes.enumerated().allSatisfy({ $0.offset == 4 || (48...57).contains($0.element) }),
              let year = Int(key.prefix(4)), year > 0, let month = Int(key.suffix(2)), (1...12).contains(month) else { return nil }
        return (year, month)
    }

    static func scheduledDate(month: String, day: Int, zone: TimeZone = .autoupdatingCurrent) -> Date? {
        let cal = calendar(zone)
        guard let ym = components(month), (1...31).contains(day),
              let first = cal.date(from: DateComponents(year: ym.year, month: ym.month, day: 1)),
              let days = cal.range(of: .day, in: .month, for: first) else { return nil }
        return cal.date(from: DateComponents(year: ym.year, month: ym.month, day: min(day, days.count)))
    }
}

enum FixedIncomeCategory: String, Codable, CaseIterable {
    case other = "other-income", salary = "salary-income", bonus = "bonus-income", side = "side-income"
    case investment = "investment-income", gift = "gift-income"
}

struct FixedIncomePlan: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var amount: Decimal
    var currency: SavingsCurrency
    var category: FixedIncomeCategory
    var dayOfMonth: Int
    /// First eligible accounting month. Editing the amount does not rewrite past receipts.
    let startMonth: String
    var isEnabled: Bool

    var isValid: Bool {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !clean.isEmpty && clean == name && clean.count <= 120 && Self.validAmount(amount, currency: currency)
            && (1...31).contains(dayOfMonth) && FixedIncomePeriod.components(startMonth) != nil
    }

    static func validAmount(_ amount: Decimal, currency: SavingsCurrency) -> Bool {
        guard !amount.isNaN, amount > 0, amount <= Decimal(999_999_999_999 as Int64) + Decimal(99) / 100 else { return false }
        var input = amount, rounded = Decimal()
        NSDecimalRound(&rounded, &input, currency.fractionDigits, .plain)
        return amount == rounded
    }

    static func parseAmount(_ input: String, currency: SavingsCurrency) -> Decimal? {
        let clean = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = currency.fractionDigits == 0 ? #"\A[0-9]{1,12}\z"# : #"\A[0-9]{1,12}(?:\.[0-9]{1,2})?\z"#
        guard clean.range(of: pattern, options: .regularExpression) != nil,
              let amount = Decimal(string: clean, locale: Locale(identifier: "en_US_POSIX")), validAmount(amount, currency: currency) else { return nil }
        return amount
    }

    func ledgerID(month: String) -> String { "fixed-income|\(id.uuidString.lowercased())|\(month)" }
    func predicted(on month: String) -> Bool { isEnabled && FixedIncomePeriod.components(month) != nil && month >= startMonth }
}

/// Historical evidence of the explicit receipt. Intentionally survives deletion of its personal ledger row.
struct FixedIncomeReceipt: Identifiable, Codable, Hashable {
    let planID: UUID
    let month: String
    let name: String
    let amount: Decimal
    let currency: SavingsCurrency
    let category: FixedIncomeCategory
    let accountID: String
    let accountName: String
    let receivedOn: Date
    let confirmedAt: Date
    var id: String { "fixed-income|\(planID.uuidString.lowercased())|\(month)" }
}

// Invalid stored fields must fail decoding of the business library, rather than entering a forecast or being silently discarded.
extension FixedIncomePlan {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                  amount: try c.decode(Decimal.self, forKey: .amount), currency: try c.decode(SavingsCurrency.self, forKey: .currency),
                  category: try c.decode(FixedIncomeCategory.self, forKey: .category), dayOfMonth: try c.decode(Int.self, forKey: .dayOfMonth),
                  startMonth: try c.decode(String.self, forKey: .startMonth), isEnabled: try c.decode(Bool.self, forKey: .isEnabled))
        guard isValid else { throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Invalid fixed-income plan") }
    }
}

extension FixedIncomeReceipt {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(planID: try c.decode(UUID.self, forKey: .planID), month: try c.decode(String.self, forKey: .month),
                  name: try c.decode(String.self, forKey: .name), amount: try c.decode(Decimal.self, forKey: .amount),
                  currency: try c.decode(SavingsCurrency.self, forKey: .currency), category: try c.decode(FixedIncomeCategory.self, forKey: .category),
                  accountID: try c.decode(String.self, forKey: .accountID), accountName: try c.decode(String.self, forKey: .accountName),
                  receivedOn: try c.decode(Date.self, forKey: .receivedOn), confirmedAt: try c.decode(Date.self, forKey: .confirmedAt))
        guard FixedIncomePeriod.components(month) != nil, FixedIncomePlan.validAmount(amount, currency: currency),
              !name.isEmpty, !accountID.isEmpty, receivedOn.timeIntervalSince1970.isFinite, confirmedAt.timeIntervalSince1970.isFinite
        else { throw DecodingError.dataCorruptedError(forKey: .planID, in: c, debugDescription: "Invalid fixed-income receipt") }
    }
}

enum FixedIncomeResult: Equatable { case posted, alreadyConfirmed }

enum FixedIncomeError: LocalizedError, Equatable {
    case protected, invalidPlan, startInPast, stalePlan, invalidMonth, outsidePeriod, disabled, notConfirmed, account, invalidDate, conflict, persistence
    var errorDescription: String? {
        switch self {
        case .protected: return "资料库处于保护状态，不能修改固定收入。"
        case .invalidPlan: return "请填写收入名称、有效的正数金额和每月 1 至 31 日的预计到账日。"
        case .startInPast: return "新计划的起始月份不能早于本月。"
        case .stalePlan: return "这项计划已发生变化，请关闭表单后重新选择。"
        case .invalidMonth: return "请选择有效的所属月份。"
        case .outsidePeriod: return "只能确认从计划起始月到本月的收入。"
        case .disabled: return "计划已停用，不能确认新的到账。"
        case .notConfirmed: return "请先确认这笔款项已经实际到账。"
        case .account: return "请选择一个仍在使用、且与计划同币种的收款账户。"
        case .invalidDate: return "实际到账日期不能早于计划起始月，也不能是未来日期。"
        case .conflict: return "该月的流水或回执存在冲突；没有创建新的收入。请先核对原记录。"
        case .persistence: return "固定收入未能保存，已撤回本次改动。请检查资料目录后重试。"
        }
    }
}
