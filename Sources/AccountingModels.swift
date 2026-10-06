import Foundation

enum LedgerAccountType: String, Codable, CaseIterable, Identifiable {
    case cash, bank, ewallet, credit, investment, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cash: tS("现金", "Cash")
        case .bank: tS("银行卡", "Bank Card")
        case .ewallet: tS("电子钱包", "E-Wallet")
        case .credit: tS("信用账户", "Credit")
        case .investment: tS("投资账户", "Investment")
        case .other: tS("其他账户", "Other")
        }
    }
    var symbol: String {
        switch self {
        case .cash: "banknote.fill"
        case .bank: "building.columns.fill"
        case .ewallet: "wallet.pass.fill"
        case .credit: "creditcard.fill"
        case .investment: "chart.line.uptrend.xyaxis"
        case .other: "tray.full.fill"
        }
    }
    var isLiability: Bool { self == .credit }
}

struct LedgerAccount: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var type: LedgerAccountType
    var currency: SavingsCurrency
    var openingBalance: Double
    var symbol: String
    var colorKey: String
    var includeInNetWorth: Bool
    var isArchived: Bool
    var createdAt: Date
}

enum LedgerEntryKind: String, Codable, CaseIterable, Identifiable {
    case expense, income, transfer
    var id: String { rawValue }
    var title: String {
        switch self {
        case .expense: tS("支出", "Expense")
        case .income: tS("收入", "Income")
        case .transfer: tS("转账", "Transfer")
        }
    }
    var symbol: String {
        switch self {
        case .expense: "arrow.up.right.circle.fill"
        case .income: "arrow.down.left.circle.fill"
        case .transfer: "arrow.left.arrow.right.circle.fill"
        }
    }
}

struct LedgerEntry: Codable, Identifiable, Hashable {
    static let balanceAdjustmentCategoryID = "balance-adjustment"
    var id: String
    var kind: LedgerEntryKind
    var accountID: String
    var targetAccountID: String?
    /// 存储口径：Decimal（2dp 归一化）。JSON 仍以 Double 数字读写，文件格式与 V2.2 完全一致。
    var amountValue: Decimal
    /// 跨币种转账的实际转入金额（目标币种）。
    var targetAmountValue: Decimal?
    var categoryID: String
    var date: Date
    var note: String
    var createdAt: Date
    /// 周期自动记账来源规则（V2.3 新增）。旧 JSON 缺该字段时解码为 nil。
    var recurringRuleID: UUID? = nil
    var isBalanceAdjustment: Bool { categoryID == Self.balanceAdjustmentCategoryID }

    /// 兼容层：视图与既有 API 仍按 Double 读写，写回时按 2dp 归一化。
    var amount: Double {
        get { MoneyValue.double(amountValue) }
        set { amountValue = MoneyValue.normalize(newValue) }
    }
    var targetAmount: Double? {
        get { targetAmountValue.map(MoneyValue.double) }
        set { targetAmountValue = newValue.map(MoneyValue.normalize) }
    }

    init(id: String, kind: LedgerEntryKind, accountID: String, targetAccountID: String?, amount: Double,
         targetAmount: Double?, categoryID: String, date: Date, note: String, createdAt: Date,
         recurringRuleID: UUID? = nil) {
        self.id = id
        self.kind = kind
        self.accountID = accountID
        self.targetAccountID = targetAccountID
        self.amountValue = MoneyValue.normalize(amount)
        self.targetAmountValue = targetAmount.map(MoneyValue.normalize)
        self.categoryID = categoryID
        self.date = date
        self.note = note
        self.createdAt = createdAt
        self.recurringRuleID = recurringRuleID
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, accountID, targetAccountID, amount, targetAmount, categoryID, date, note, createdAt, recurringRuleID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(LedgerEntryKind.self, forKey: .kind)
        accountID = try container.decode(String.self, forKey: .accountID)
        targetAccountID = try container.decodeIfPresent(String.self, forKey: .targetAccountID)
        // 旧 JSON 是 Double 字面量：先按 Double 读，再归一化消除二进制浮点噪声（88.1 → 88.0999…）。
        amountValue = MoneyValue.normalize(try container.decode(Double.self, forKey: .amount))
        targetAmountValue = try container.decodeIfPresent(Double.self, forKey: .targetAmount).map(MoneyValue.normalize)
        categoryID = try container.decode(String.self, forKey: .categoryID)
        date = try container.decode(Date.self, forKey: .date)
        note = try container.decode(String.self, forKey: .note)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        recurringRuleID = try container.decodeIfPresent(UUID.self, forKey: .recurringRuleID)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(accountID, forKey: .accountID)
        try container.encodeIfPresent(targetAccountID, forKey: .targetAccountID)
        try container.encode(MoneyValue.double(amountValue), forKey: .amount)
        try container.encodeIfPresent(targetAmountValue.map(MoneyValue.double), forKey: .targetAmount)
        try container.encode(categoryID, forKey: .categoryID)
        try container.encode(date, forKey: .date)
        try container.encode(note, forKey: .note)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(recurringRuleID, forKey: .recurringRuleID)
    }
}

struct LedgerCategoryDefinition: Identifiable, Hashable {
    let id: String
    let name: String
    let kind: LedgerEntryKind
    let symbol: String
    let colorKey: String
}

struct BudgetPlan: Codable, Identifiable, Hashable {
    var id: String
    var monthKey: String
    var categoryID: String
    var currency: SavingsCurrency
    /// 存储口径：Decimal（2dp 归一化），JSON 仍以 Double 数字读写。
    var amountValue: Decimal

    /// 兼容层：视图与既有 API 仍按 Double 读写。
    var amount: Double {
        get { MoneyValue.double(amountValue) }
        set { amountValue = MoneyValue.normalize(newValue) }
    }

    init(id: String, monthKey: String, categoryID: String, currency: SavingsCurrency, amount: Double) {
        self.id = id
        self.monthKey = monthKey
        self.categoryID = categoryID
        self.currency = currency
        self.amountValue = MoneyValue.normalize(amount)
    }

    private enum CodingKeys: String, CodingKey { case id, monthKey, categoryID, currency, amount }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        monthKey = try container.decode(String.self, forKey: .monthKey)
        categoryID = try container.decode(String.self, forKey: .categoryID)
        currency = try container.decode(SavingsCurrency.self, forKey: .currency)
        amountValue = MoneyValue.normalize(try container.decode(Double.self, forKey: .amount))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(monthKey, forKey: .monthKey)
        try container.encode(categoryID, forKey: .categoryID)
        try container.encode(currency, forKey: .currency)
        try container.encode(MoneyValue.double(amountValue), forKey: .amount)
    }
}
