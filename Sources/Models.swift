import Foundation
import SwiftUI

/// 侧栏主板块。V2.2 起游戏相关的六个页面收拢为单一 adventure 入口，
/// 由 AdventureHubView 内部的页签承载；rawValue 不参与持久化与小组件快照。
enum SavingsSection: String, CaseIterable, Identifiable {
    case overview, ledger, accounts, budgets, reports
    case goals, records, analytics
    case adventure

    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: tS("财务总览", "Overview")
        case .ledger: tS("日常记账", "Ledger")
        case .accounts: tS("资产账户", "Accounts")
        case .budgets: tS("月度预算", "Budgets")
        case .reports: tS("收支报表", "Reports")
        case .goals: tS("攒钱目标", "Goals")
        case .records: tS("积蓄记录", "Records")
        case .analytics: tS("积蓄趋势", "Trends")
        case .adventure: tS("冒险成长", "Adventure")
        }
    }
    var subtitle: String {
        switch self {
        case .overview: tS("一处看清账户、收支、预算、积蓄目标与成长", "Accounts, cash flow, budgets, goals and progress at a glance")
        case .ledger: tS("记录收入、支出和账户互转，保持真实账户余额", "Track income, expenses and transfers with real balances")
        case .accounts: tS("现金、银行卡、电子钱包、信用账户和投资账户", "Cash, bank, e-wallet, credit and investment accounts")
        case .budgets: tS("按月规划支出分类，对照预算与实际发生额", "Plan spending by category and compare with actuals")
        case .reports: tS("查看收支趋势、分类结构与净现金流", "Trends, category breakdown and net cash flow")
        case .goals: tS("把账户中的钱分配给真正想实现的目标", "Allocate money toward the goals that matter")
        case .records: tS("每笔积蓄同步记为账户转账，不计入日常收支", "Each saving is a transfer, excluded from daily cash flow")
        case .analytics: tS("回看积蓄节奏，估算目标完成时间", "Review your pace and estimate goal completion")
        case .adventure: tS("战斗、装备、技能、宠物、祈愿与成就，全部免费游玩", "Battles, gear, techniques, pets, wishes and achievements — all free")
        }
    }
    var symbol: String {
        switch self {
        case .overview: "rectangle.3.group.fill"
        case .ledger: "square.and.pencil"
        case .accounts: "wallet.pass.fill"
        case .budgets: "gauge.with.dots.needle.67percent"
        case .reports: "chart.bar.xaxis"
        case .goals: "target"
        case .records: "list.bullet.rectangle.portrait.fill"
        case .analytics: "chart.xyaxis.line"
        case .adventure: "map.fill"
        }
    }
}

enum SavingsCurrency: String, Codable, CaseIterable, Identifiable {
    case CNY, USD, EUR, GBP, JPY, HKD, TWD, KRW, SGD, AUD, CAD
    var id: String { rawValue }
    var name: String {
        switch self {
        case .CNY: tS("人民币", "Renminbi")
        case .USD: tS("美元", "US Dollar")
        case .EUR: tS("欧元", "Euro")
        case .GBP: tS("英镑", "British Pound")
        case .JPY: tS("日元", "Japanese Yen")
        case .HKD: tS("港币", "Hong Kong Dollar")
        case .TWD: tS("新台币", "New Taiwan Dollar")
        case .KRW: tS("韩元", "South Korean Won")
        case .SGD: tS("新加坡元", "Singapore Dollar")
        case .AUD: tS("澳元", "Australian Dollar")
        case .CAD: tS("加拿大元", "Canadian Dollar")
        }
    }
    var symbol: String {
        switch self {
        case .CNY, .JPY: "¥"
        case .USD, .HKD, .TWD, .SGD, .AUD, .CAD: "$"
        case .EUR: "€"
        case .GBP: "£"
        case .KRW: "₩"
        }
    }
    var displayName: String { "\(name)（\(rawValue)）" }
    var fractionDigits: Int { self == .JPY || self == .KRW ? 0 : 2 }
}

enum GoalStatus: String, Codable, CaseIterable, Identifiable {
    case active, paused, completed, archived
    var id: String { rawValue }
    var title: String {
        switch self {
        case .active: tS("进行中", "Active")
        case .paused: tS("已暂停", "Paused")
        case .completed: tS("已完成", "Completed")
        case .archived: tS("已归档", "Archived")
        }
    }
}

/// 货币数值口径（V2.3 起）：财务金额在模型层以 Decimal 存储并统一按 2 位小数归一化
/// （四舍五入、半进远离零；2dp 对 JPY/KRW 的 0dp 是超集），消除 Double 二进制浮点噪声
/// （例如旧 JSON 的 88.1 经 NSNumber 转换会变成 88.0999…）。视图与既有公开 API 仍走
/// Double，转换只发生在边界（见各模型的 amount/targetAmount 兼容计算属性）。
enum MoneyValue {
    static let scale = 2

    /// Decimal 归一化到 2 位小数。
    static func normalize(_ value: Decimal) -> Decimal {
        var source = value
        var result = Decimal()
        NSDecimalRound(&result, &source, scale, .plain)
        return result
    }

    /// Double → Decimal 并归一化。非有限值按 0 处理（与旧校验逻辑配合，不会静默写入 NaN）。
    static func normalize(_ value: Double) -> Decimal {
        guard value.isFinite else { return 0 }
        return normalize(Decimal(value))
    }

    /// Decimal → Double 边界转换。
    static func double(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }
}

struct SavingsGoal: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    /// 存储口径：Decimal（2dp 归一化）。JSON 仍以 Double 数字读写，文件格式与 V2.2 完全一致。
    var targetAmountValue: Decimal
    var startingAmountValue: Decimal
    var currency: SavingsCurrency
    var deadline: Date
    var symbol: String
    var colorKey: String
    var notes: String
    var status: GoalStatus
    var createdAt: Date
    var completedAt: Date?
    var savingsAccountID: String? = nil

    /// 兼容层：视图与既有 API 仍按 Double 读写，写回时按 2dp 归一化。
    var targetAmount: Double {
        get { MoneyValue.double(targetAmountValue) }
        set { targetAmountValue = MoneyValue.normalize(newValue) }
    }
    var startingAmount: Double {
        get { MoneyValue.double(startingAmountValue) }
        set { startingAmountValue = MoneyValue.normalize(newValue) }
    }

    init(id: String, title: String, targetAmount: Double, startingAmount: Double, currency: SavingsCurrency,
         deadline: Date, symbol: String, colorKey: String, notes: String, status: GoalStatus,
         createdAt: Date, completedAt: Date?, savingsAccountID: String? = nil) {
        self.id = id
        self.title = title
        self.targetAmountValue = MoneyValue.normalize(targetAmount)
        self.startingAmountValue = MoneyValue.normalize(startingAmount)
        self.currency = currency
        self.deadline = deadline
        self.symbol = symbol
        self.colorKey = colorKey
        self.notes = notes
        self.status = status
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.savingsAccountID = savingsAccountID
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, targetAmount, startingAmount, currency, deadline, symbol, colorKey, notes, status, createdAt, completedAt, savingsAccountID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        // 旧 JSON 是 Double 字面量：先按 Double 读，再归一化消除二进制浮点噪声。
        targetAmountValue = MoneyValue.normalize(try container.decode(Double.self, forKey: .targetAmount))
        startingAmountValue = MoneyValue.normalize(try container.decode(Double.self, forKey: .startingAmount))
        currency = try container.decode(SavingsCurrency.self, forKey: .currency)
        deadline = try container.decode(Date.self, forKey: .deadline)
        symbol = try container.decode(String.self, forKey: .symbol)
        colorKey = try container.decode(String.self, forKey: .colorKey)
        notes = try container.decode(String.self, forKey: .notes)
        status = try container.decode(GoalStatus.self, forKey: .status)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        savingsAccountID = try container.decodeIfPresent(String.self, forKey: .savingsAccountID)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(MoneyValue.double(targetAmountValue), forKey: .targetAmount)
        try container.encode(MoneyValue.double(startingAmountValue), forKey: .startingAmount)
        try container.encode(currency, forKey: .currency)
        try container.encode(deadline, forKey: .deadline)
        try container.encode(symbol, forKey: .symbol)
        try container.encode(colorKey, forKey: .colorKey)
        try container.encode(notes, forKey: .notes)
        try container.encode(status, forKey: .status)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encodeIfPresent(savingsAccountID, forKey: .savingsAccountID)
    }
}

enum SavingsRecordKind: String, Codable, CaseIterable, Identifiable {
    case deposit, withdrawal
    var id: String { rawValue }
    var title: String { self == .deposit ? "分配给目标" : "撤回分配" }
    var shortTitle: String { self == .deposit ? "存入" : "取出" }
    var symbol: String { self == .deposit ? "arrow.down.circle.fill" : "arrow.up.circle.fill" }
}

enum SavingsCategory: String, Codable, CaseIterable, Identifiable {
    case salary, savedExpense, extraIncome, scheduled, gift, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .salary: "工资结余"
        case .savedExpense: "少花一笔"
        case .extraIncome: "额外收入"
        case .scheduled: "固定储蓄"
        case .gift: "红包礼金"
        case .other: "其他"
        }
    }
    var symbol: String {
        switch self {
        case .salary: "briefcase.fill"
        case .savedExpense: "takeoutbag.and.cup.and.straw.fill"
        case .extraIncome: "plus.circle.fill"
        case .scheduled: "calendar.badge.clock"
        case .gift: "gift.fill"
        case .other: "ellipsis.circle.fill"
        }
    }
}

struct SavingsRecord: Codable, Identifiable, Hashable {
    var id: String
    var goalID: String
    var kind: SavingsRecordKind
    /// 存储口径：Decimal（2dp 归一化），JSON 仍以 Double 数字读写。
    var amountValue: Decimal
    var date: Date
    var category: SavingsCategory
    var note: String
    var gameRewardClaimed: Bool
    var createdAt: Date
    var fundingAccountID: String? = nil
    var savingsAccountID: String? = nil
    var ledgerEntryID: String? = nil
    /// 冗余币种（V2.3 新增，如 "CNY"）：新记录创建时写入目标币种；
    /// 旧 JSON 缺该字段时解码为 ""，由 v22→v23 迁移回填。
    var currency: String = ""

    /// 兼容层：视图与既有 API 仍按 Double 读写。
    var amount: Double {
        get { MoneyValue.double(amountValue) }
        set { amountValue = MoneyValue.normalize(newValue) }
    }

    init(id: String, goalID: String, kind: SavingsRecordKind, amount: Double, date: Date, category: SavingsCategory,
         note: String, gameRewardClaimed: Bool, createdAt: Date, fundingAccountID: String? = nil,
         savingsAccountID: String? = nil, ledgerEntryID: String? = nil, currency: String = "") {
        self.id = id
        self.goalID = goalID
        self.kind = kind
        self.amountValue = MoneyValue.normalize(amount)
        self.date = date
        self.category = category
        self.note = note
        self.gameRewardClaimed = gameRewardClaimed
        self.createdAt = createdAt
        self.fundingAccountID = fundingAccountID
        self.savingsAccountID = savingsAccountID
        self.ledgerEntryID = ledgerEntryID
        self.currency = currency
    }

    private enum CodingKeys: String, CodingKey {
        case id, goalID, kind, amount, date, category, note, gameRewardClaimed, createdAt
        case fundingAccountID, savingsAccountID, ledgerEntryID, currency
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        goalID = try container.decode(String.self, forKey: .goalID)
        kind = try container.decode(SavingsRecordKind.self, forKey: .kind)
        amountValue = MoneyValue.normalize(try container.decode(Double.self, forKey: .amount))
        date = try container.decode(Date.self, forKey: .date)
        category = try container.decode(SavingsCategory.self, forKey: .category)
        note = try container.decode(String.self, forKey: .note)
        gameRewardClaimed = try container.decode(Bool.self, forKey: .gameRewardClaimed)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        fundingAccountID = try container.decodeIfPresent(String.self, forKey: .fundingAccountID)
        savingsAccountID = try container.decodeIfPresent(String.self, forKey: .savingsAccountID)
        ledgerEntryID = try container.decodeIfPresent(String.self, forKey: .ledgerEntryID)
        currency = try container.decodeIfPresent(String.self, forKey: .currency) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(goalID, forKey: .goalID)
        try container.encode(kind, forKey: .kind)
        try container.encode(MoneyValue.double(amountValue), forKey: .amount)
        try container.encode(date, forKey: .date)
        try container.encode(category, forKey: .category)
        try container.encode(note, forKey: .note)
        try container.encode(gameRewardClaimed, forKey: .gameRewardClaimed)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(fundingAccountID, forKey: .fundingAccountID)
        try container.encodeIfPresent(savingsAccountID, forKey: .savingsAccountID)
        try container.encodeIfPresent(ledgerEntryID, forKey: .ledgerEntryID)
        try container.encode(currency, forKey: .currency)
    }
}

enum RecurringFrequency: String, Codable, CaseIterable, Identifiable {
    case daily, weekly, monthly, yearly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .daily: "每天"
        case .weekly: "每周"
        case .monthly: "每月"
        case .yearly: "每年"
        }
    }
}

/// 周期自动记账规则（V2.3 新增）。到期由 SavingsStore.materializeRecurringTransactions(asOf:)
/// 物化为普通流水（标记 recurringRuleID，不发放游戏资源），并按月/年保持日号推进 nextDueDate。
struct RecurringRule: Codable, Identifiable, Hashable {
    var id: UUID
    /// 仅支持收入与支出（转账没有分类语义，保存时会被拒绝）。
    var kind: LedgerEntryKind
    /// 存储口径：Decimal（2dp 归一化）。
    var amount: Decimal
    var accountID: String
    var categoryID: String
    var note: String
    var frequency: RecurringFrequency
    var nextDueDate: Date
    var isEnabled: Bool

    init(id: UUID = UUID(), kind: LedgerEntryKind, amount: Decimal, accountID: String, categoryID: String,
         note: String, frequency: RecurringFrequency, nextDueDate: Date, isEnabled: Bool = true) {
        self.id = id
        self.kind = kind
        self.amount = MoneyValue.normalize(amount)
        self.accountID = accountID
        self.categoryID = categoryID
        self.note = note
        self.frequency = frequency
        self.nextDueDate = nextDueDate
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, amount, accountID, categoryID, note, frequency, nextDueDate, isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(LedgerEntryKind.self, forKey: .kind)
        // JSON 以 Double 数字存储；解码后统一 2dp 归一化。
        amount = MoneyValue.normalize(try container.decode(Double.self, forKey: .amount))
        accountID = try container.decode(String.self, forKey: .accountID)
        categoryID = try container.decode(String.self, forKey: .categoryID)
        note = try container.decode(String.self, forKey: .note)
        frequency = try container.decode(RecurringFrequency.self, forKey: .frequency)
        nextDueDate = try container.decode(Date.self, forKey: .nextDueDate)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(MoneyValue.double(amount), forKey: .amount)
        try container.encode(accountID, forKey: .accountID)
        try container.encode(categoryID, forKey: .categoryID)
        try container.encode(note, forKey: .note)
        try container.encode(frequency, forKey: .frequency)
        try container.encode(nextDueDate, forKey: .nextDueDate)
        try container.encode(isEnabled, forKey: .isEnabled)
    }
}

enum EquipmentSlot: String, Codable, CaseIterable, Identifiable {
    case mainHand, offHand, head, shoulders, chest, hands, waist, legs, feet
    case necklace, ringLeft, ringRight, cloak, relic
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mainHand: "主手"
        case .offHand: "副手"
        case .head: "头盔"
        case .shoulders: "肩甲"
        case .chest: "胸甲"
        case .hands: "手套"
        case .waist: "腰带"
        case .legs: "腿甲"
        case .feet: "战靴"
        case .necklace: "项链"
        case .ringLeft: "左戒"
        case .ringRight: "右戒"
        case .cloak: "披风"
        case .relic: "圣物"
        }
    }
    var itemNoun: String {
        switch self {
        case .mainHand: "刃"
        case .offHand: "盾"
        case .head: "冠"
        case .shoulders: "肩铠"
        case .chest: "战甲"
        case .hands: "护手"
        case .waist: "束带"
        case .legs: "胫甲"
        case .feet: "长靴"
        case .necklace: "项坠"
        case .ringLeft, .ringRight: "指环"
        case .cloak: "斗篷"
        case .relic: "秘宝"
        }
    }
    var symbol: String {
        switch self {
        case .mainHand: "bolt.fill"
        case .offHand: "shield.fill"
        case .head: "crown.fill"
        case .shoulders: "person.crop.square.filled.and.at.rectangle"
        case .chest: "tshirt.fill"
        case .hands: "hand.raised.fill"
        case .waist: "circle.dotted"
        case .legs: "figure.walk"
        case .feet: "shoeprints.fill"
        case .necklace: "seal.fill"
        case .ringLeft, .ringRight: "circle.circle.fill"
        case .cloak: "wind"
        case .relic: "sparkles"
        }
    }
}

enum ItemRarity: Int, Codable, CaseIterable, Identifiable {
    case common = 1, fine, rare, epic, legendary, mythic, peerless
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .common: "普通"
        case .fine: "精良"
        case .rare: "稀有"
        case .epic: "史诗"
        case .legendary: "传说"
        case .mythic: "神话"
        case .peerless: "绝世"
        }
    }
    var color: Color {
        switch self {
        case .common: .secondary
        case .fine: SavingsTheme.teal
        case .rare: SavingsTheme.blue
        case .epic: SavingsTheme.purple
        case .legendary: SavingsTheme.orange
        case .mythic: SavingsTheme.red
        case .peerless: .pink
        }
    }

    var gradient: LinearGradient {
        let colors: [Color] = self == .peerless
            ? [.red, .orange, .yellow, .green, .cyan, .blue, .purple]
            : [color, color]
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }

    var guaranteeDraws: Int? {
        switch self {
        case .rare: 10
        case .epic: 30
        case .legendary: 150
        case .mythic: 500
        case .peerless: 2_000
        case .common, .fine: nil
        }
    }

    static let guaranteedTiers: [ItemRarity] = [.rare, .epic, .legendary, .mythic, .peerless]
}

/// V1.2 战力评分权重表：每一点属性按其对伤害或有效生命的期望贡献折算战力。
/// 全库唯一出处；装备、技能、宠物、角色与怪物战力共用，数值是平衡性常量，不可随意调整。
enum BattleStatWeights {
    static let attack = 18
    static let defense = 12
    static let vitality = 5
    static let speed = 6
    static let resistance = 6
    static let physicalDamage = 14
    static let magicDamage = 14
    static let trueDamage = 24
    static let fortune = 5
    static let shield = 2.5
    static let critical = 9_000.0
    static let criticalDamage = 2_500.0
    static let lifesteal = 6_500.0
    static let damageReduction = 9_000.0
    /// 怪物战力：每 2 点生命折 1 战力。
    static let monsterHPPerPower = 2
    static let monsterAttack = 28
    static let monsterResistance = 8
    /// 角色每级附加战力。
    static let levelPower = 60
}

enum GameProgression {
    static let maximumEquipmentEnhancement = 99
    static let maximumTechniqueLevel = 99
    static let maximumPetStars = 99
    static let maximumEquippedPets = 4
    static let petEggCost = 10_000

    static func equipmentMultiplier(level: Int) -> Double {
        let safeLevel = Double(min(maximumEquipmentEnhancement, max(0, level)))
        return 1 + safeLevel * 0.05 + safeLevel * safeLevel * 0.005
    }

    static func techniqueScale(level: Int) -> Double {
        let safeLevel = Double(min(maximumTechniqueLevel, max(1, level)))
        let lateLevel = max(0, safeLevel - 10)
        return safeLevel + lateLevel * lateLevel * 0.025
    }

    static func equipmentUpgradeCost(rarity: ItemRarity, nextLevel: Int) -> Int {
        let level = min(maximumEquipmentEnhancement, max(1, nextLevel))
        return rarity.rawValue * (level * 60 + level * level * 10)
    }

    static func techniqueUpgradeCost(rarity: ItemRarity, currentLevel: Int) -> Int {
        let level = min(maximumTechniqueLevel - 1, max(1, currentLevel))
        let lateLevel = max(0, level - 9)
        return rarity.rawValue * (level * 20 + lateLevel * lateLevel * 3)
    }

    static func petMultiplier(stars: Int) -> Double {
        let extraStars = Double(min(maximumPetStars, max(1, stars)) - 1)
        return 1 + extraStars * 0.15 + extraStars * extraStars * 0.003
    }
}

struct PityCounters: Codable, Hashable {
    var rare: Int = 0
    var epic: Int = 0
    var legendary: Int = 0
    var mythic: Int = 0
    var peerless: Int = 0

    func count(for rarity: ItemRarity) -> Int {
        switch rarity {
        case .rare: rare
        case .epic: epic
        case .legendary: legendary
        case .mythic: mythic
        case .peerless: peerless
        case .common, .fine: 0
        }
    }

    mutating func set(_ value: Int, for rarity: ItemRarity) {
        let maximum = max(0, (rarity.guaranteeDraws ?? 1) - 1)
        let safeValue = min(maximum, max(0, value))
        switch rarity {
        case .rare: rare = safeValue
        case .epic: epic = safeValue
        case .legendary: legendary = safeValue
        case .mythic: mythic = safeValue
        case .peerless: peerless = safeValue
        case .common, .fine: break
        }
    }

    mutating func record(_ obtainedRarity: ItemRarity) {
        for tier in ItemRarity.guaranteedTiers {
            set(obtainedRarity.rawValue >= tier.rawValue ? 0 : count(for: tier) + 1, for: tier)
        }
    }

    func clamped() -> PityCounters {
        var copy = self
        for tier in ItemRarity.guaranteedTiers { copy.set(count(for: tier), for: tier) }
        return copy
    }
}

struct EquipmentDefinition: Identifiable, Hashable {
    let id: String
    let name: String
    let slot: EquipmentSlot
    let rarity: ItemRarity
    let powerSeed: Int
    let attack: Int
    let defense: Int
    let vitality: Int
    let critical: Double
    let fortune: Int
    let symbol: String
    let setName: String
    let flavor: String

    private var stableSeed: Int {
        id.utf8.reduce(17) { (($0 &* 31) &+ Int($1)) & 0x7fffffff }
    }

    var physicalDamage: Int {
        let favored = slot == .mainHand || slot == .hands || slot == .ringLeft
        return max(0, (favored ? attack : attack / 3) + powerSeed / 3 + stableSeed % 4)
    }
    var magicDamage: Int {
        let favored = slot == .relic || slot == .necklace || slot == .ringRight
        return max(0, (favored ? attack : attack / 4) + rarity.rawValue * 2 + stableSeed % 5)
    }
    var trueDamage: Int { rarity.rawValue >= 3 ? max(0, powerSeed / 5 + stableSeed % rarity.rawValue) : 0 }
    var criticalDamage: Double { Double(rarity.rawValue) * 0.025 + Double(stableSeed % 6) * 0.005 }
    var lifesteal: Double {
        let favored = slot == .mainHand || slot == .necklace || slot == .relic
        return favored ? Double(rarity.rawValue + stableSeed % 3) * 0.004 : 0
    }
    var speed: Int {
        let favored = slot == .feet || slot == .cloak || slot == .hands
        return (favored ? rarity.rawValue * 3 : rarity.rawValue) + stableSeed % 4
    }
    var physicalResistance: Int {
        let favored = [.offHand, .head, .shoulders, .chest, .legs].contains(slot)
        return max(0, (favored ? defense / 2 : defense / 5) + rarity.rawValue + stableSeed % 4)
    }
    var magicResistance: Int {
        let favored = slot == .cloak || slot == .necklace || slot == .relic
        return max(0, (favored ? defense / 2 : defense / 6) + rarity.rawValue * 2 + stableSeed % 4)
    }
    var damageReduction: Double {
        let favored = slot == .offHand || slot == .chest || slot == .shoulders
        return favored ? Double(rarity.rawValue + stableSeed % 3) * 0.004 : Double(rarity.rawValue) * 0.001
    }
    var shield: Int {
        let favored = slot == .offHand || slot == .chest || slot == .relic
        return max(0, (favored ? vitality / 2 + defense : vitality / 8) + rarity.rawValue * 2)
    }

    var baseBattlePower: Int {
        // V1.2 combat rating: every point is valued by its expected contribution to
        // damage or effective health. This is also the immutable rating used by auto-equip.
        let flat = attack * BattleStatWeights.attack + defense * BattleStatWeights.defense
            + vitality * BattleStatWeights.vitality + physicalDamage * BattleStatWeights.physicalDamage
            + magicDamage * BattleStatWeights.magicDamage + trueDamage * BattleStatWeights.trueDamage
            + speed * BattleStatWeights.speed + physicalResistance * BattleStatWeights.resistance
            + magicResistance * BattleStatWeights.resistance + Int(Double(shield) * BattleStatWeights.shield)
            + fortune * BattleStatWeights.fortune
        let percent = Int(critical * BattleStatWeights.critical) + Int(criticalDamage * BattleStatWeights.criticalDamage)
            + Int(lifesteal * BattleStatWeights.lifesteal) + Int(damageReduction * BattleStatWeights.damageReduction)
        let affixes = uniqueAffixes.reduce(0) { $0 + Int($1.power * $1.skill.battlePowerWeight) }
        return max(1, flat + percent + affixes)
    }

    var uniqueAffixes: [EquipmentAffix] {
        let count: Int
        switch rarity {
        case .common: count = 0
        case .legendary: count = 2
        case .mythic: count = 3
        case .peerless: count = 4
        default: count = 1
        }
        return (0..<count).map { offset in
            let skill = CombatSkill.allCases[(stableSeed + offset * 3) % CombatSkill.allCases.count]
            let power = Double(rarity.rawValue * 2 + 1 + (stableSeed / (offset + 1)) % 4) / 400
            return EquipmentAffix(name: skill.affixName, detail: skill.detail(power: power), symbol: skill.symbol, skill: skill, power: power)
        }
    }
}

enum CombatSkill: Int, CaseIterable, Identifiable, Hashable {
    case echoStrike, execution, regeneration, fortification, armorPierce, arcaneSurge, haste, luckyFind

    var id: Int { rawValue }
    var affixName: String {
        switch self {
        case .echoStrike: "复击"
        case .execution: "收束"
        case .regeneration: "回春"
        case .fortification: "磐壁"
        case .armorPierce: "穿透"
        case .arcaneSurge: "法涌"
        case .haste: "疾行"
        case .luckyFind: "寻宝"
        }
    }
    var symbol: String {
        switch self {
        case .echoStrike: "arrow.triangle.2.circlepath"
        case .execution: "scope"
        case .regeneration: "heart.fill"
        case .fortification: "shield.fill"
        case .armorPierce: "arrow.right.to.line.compact"
        case .arcaneSurge: "wand.and.stars"
        case .haste: "wind"
        case .luckyFind: "sparkles"
        }
    }
    var maximumPower: Double {
        switch self {
        case .echoStrike: 0.40
        case .execution: 0.35
        case .regeneration: 0.03
        case .fortification: 0.35
        case .armorPierce: 0.30
        case .arcaneSurge: 0.35
        case .haste: 0.30
        case .luckyFind: 0.40
        }
    }
    var battlePowerWeight: Double {
        switch self {
        case .echoStrike: 3_000
        case .execution: 3_500
        case .regeneration: 10_000
        case .fortification: 5_000
        case .armorPierce: 5_500
        case .arcaneSurge: 4_000
        case .haste: 7_000
        case .luckyFind: 1_500
        }
    }
    func detail(power: Double) -> String {
        let percent = max(1, Int((min(power, maximumPower) * 100).rounded()))
        switch self {
        case .echoStrike: return "每第 5 次攻击追加 \(percent)% 伤害"
        case .execution: return "目标低于 20% 生命时伤害 +\(percent)%"
        case .regeneration: return "每次攻击后恢复 \(percent)% 最大生命（同类总上限 3%）"
        case .fortification: return "最大生命 +\(percent)%"
        case .armorPierce: return "忽略怪物 \(percent)% 双抗"
        case .arcaneSurge: return "魔法伤害 +\(percent)%"
        case .haste: return "全部伤害 +\(percent)%"
        case .luckyFind: return "过关金币与悟性 +\(percent)%"
        }
    }
}

struct EquipmentAffix: Identifiable, Hashable {
    var id: String { "\(skill.rawValue)-\(name)-\(power)" }
    let name: String
    let detail: String
    let symbol: String
    let skill: CombatSkill
    let power: Double
}

struct OwnedEquipment: Codable, Identifiable, Hashable {
    var id: String { definitionID }
    var definitionID: String
    var count: Int
    var enhancementLevel: Int? = nil
}

enum DrawPool: String, Codable, CaseIterable, Identifiable {
    case equipment, technique
    var id: String { rawValue }
    var title: String { self == .equipment ? "装备池" : "技能池" }
    var shortTitle: String { self == .equipment ? "装备" : "技能" }
    var symbol: String { self == .equipment ? "shield.fill" : "scroll.fill" }
}

enum TechniqueEffect: String, CaseIterable, Identifiable {
    case attack, defense, vitality, critical, criticalDamage, lifesteal, speed
    case physicalResistance, magicResistance, physicalDamage, magicDamage, trueDamage, damageReduction, shield
    case bossDamage, experience, stardust
    case depositPower, streakPower, budgetPower, incomePower, expenseGuard, fortune
    var id: String { rawValue }
    var title: String {
        switch self {
        case .attack: "攻击强化"
        case .defense: "防御强化"
        case .vitality: "生命锻炼"
        case .critical: "暴击修炼"
        case .criticalDamage: "暴伤增幅"
        case .lifesteal: "吸血转化"
        case .speed: "速度精进"
        case .physicalResistance: "物抗淬炼"
        case .magicResistance: "魔抗淬炼"
        case .physicalDamage: "物伤强化"
        case .magicDamage: "魔伤强化"
        case .trueDamage: "真伤领悟"
        case .damageReduction: "减伤心法"
        case .shield: "护盾凝聚"
        case .bossDamage: "首领克制"
        case .experience: "经验增幅"
        case .stardust: "星尘增幅"
        case .depositPower: "积蓄真意"
        case .streakPower: "连战疾行"
        case .budgetPower: "预算壁垒"
        case .incomePower: "进取锋芒"
        case .expenseGuard: "节制护盾"
        case .fortune: "寻宝运势"
        }
    }
    var symbol: String {
        switch self {
        case .attack: "bolt.fill"
        case .defense: "shield.fill"
        case .vitality: "heart.fill"
        case .critical: "burst.fill"
        case .criticalDamage: "sparkles"
        case .lifesteal: "drop.fill"
        case .speed: "wind"
        case .physicalResistance: "shield.lefthalf.filled"
        case .magicResistance: "wand.and.stars.inverse"
        case .physicalDamage: "hammer.fill"
        case .magicDamage: "wand.and.stars"
        case .trueDamage: "scope"
        case .damageReduction: "checkmark.shield.fill"
        case .shield: "hexagon.fill"
        case .bossDamage: "scope"
        case .experience: "arrow.up.circle.fill"
        case .stardust: "sparkles"
        case .depositPower: "banknote.fill"
        case .streakPower: "flame.fill"
        case .budgetPower: "gauge.with.dots.needle.67percent"
        case .incomePower: "arrow.down.left.circle.fill"
        case .expenseGuard: "eye.fill"
        case .fortune: "star.circle.fill"
        }
    }
    var baseDescription: String {
        switch self {
        case .attack: "每级提高自动攻击伤害"
        case .defense: "每级提高角色防御"
        case .vitality: "每级提高角色生命"
        case .critical: "每级提高暴击概率"
        case .criticalDamage: "每级提高暴击伤害"
        case .lifesteal: "每级提高攻击吸血"
        case .speed: "每级提高自动战斗速度"
        case .physicalResistance: "每级提高物理抗性"
        case .magicResistance: "每级提高魔法抗性"
        case .physicalDamage: "每级提高物理伤害"
        case .magicDamage: "每级提高魔法伤害"
        case .trueDamage: "每级提高无视防御的真实伤害"
        case .damageReduction: "每级提高最终伤害减免"
        case .shield: "每级提高战斗护盾"
        case .bossDamage: "每级提高对首领伤害"
        case .experience: "每级提高冒险经验"
        case .stardust: "每级提高星尘收益"
        case .depositPower: "每级提高真实伤害"
        case .streakPower: "每级提高战斗速度"
        case .budgetPower: "每级提高角色防御"
        case .incomePower: "每级提高角色攻击"
        case .expenseGuard: "每级提高战斗护盾"
        case .fortune: "每级提高高稀有度掉落倾向"
        }
    }

    func formattedBonus(_ value: Double) -> String {
        switch self {
        case .critical, .criticalDamage, .lifesteal, .damageReduction, .bossDamage, .experience, .stardust:
            return "+\(max(1, Int((value * 100).rounded())))%"
        case .depositPower, .streakPower, .budgetPower, .incomePower, .expenseGuard:
            return "+\(max(1, Int((value * 100).rounded())))"
        default:
            return "+\(max(1, Int(value.rounded())))"
        }
    }
}

struct TechniqueDefinition: Identifiable, Hashable {
    let id: String
    let name: String
    let school: String
    let culture: String
    let symbol: String
    let description: String
    let effect: TechniqueEffect
    let effectPerLevel: Double
    let rarity: ItemRarity

    private var stableSeed: Int {
        id.utf8.reduce(23) { (($0 &* 37) &+ Int($1)) & 0x7fffffff }
    }
    var signatureSkill: CombatSkill { CombatSkill.allCases[stableSeed % CombatSkill.allCases.count] }
    var signaturePowerPerLevel: Double { Double(rarity.rawValue + 1 + stableSeed % 3) / 1_000 }
    func effectDetail(level: Int) -> String { "\(effect.title) \(effect.formattedBonus(effectPerLevel * GameProgression.techniqueScale(level: level)))" }
    func signatureDetail(level: Int) -> String { signatureSkill.detail(power: signaturePowerPerLevel * GameProgression.techniqueScale(level: level)) }
}

struct TechniqueProgress: Codable, Identifiable, Hashable {
    var id: String { techniqueID }
    var techniqueID: String
    var level: Int
}

enum PetLifeStage: String, CaseIterable, Identifiable {
    case juvenile, adult, complete
    var id: String { rawValue }
    var title: String {
        switch self {
        case .juvenile: "幼年体"
        case .adult: "成年体"
        case .complete: "完全体"
        }
    }
    var spriteColumn: Int {
        switch self {
        case .juvenile: 0
        case .adult: 1
        case .complete: 2
        }
    }
    static func stage(for stars: Int) -> PetLifeStage {
        if stars <= 1 { return .juvenile }
        if stars == 2 { return .adult }
        return .complete
    }
}

struct PetDefinition: Identifiable, Hashable {
    let id: String
    let name: String
    let role: String
    let flavor: String
    let spriteIndex: Int
    let attack: Int
    let defense: Int
    let vitality: Int
    let speed: Int
    let fortune: Int
    let physicalDamage: Int
    let magicDamage: Int
    let shield: Int

    var baseBattlePower: Int {
        max(1, attack * BattleStatWeights.attack + defense * BattleStatWeights.defense
            + vitality * BattleStatWeights.vitality + speed * BattleStatWeights.speed
            + fortune * BattleStatWeights.fortune + physicalDamage * BattleStatWeights.physicalDamage
            + magicDamage * BattleStatWeights.magicDamage + Int(Double(shield) * BattleStatWeights.shield))
    }

    func battlePower(stars: Int) -> Int {
        max(1, Int((Double(baseBattlePower) * GameProgression.petMultiplier(stars: stars)).rounded()))
    }
}

struct OwnedPet: Codable, Identifiable, Hashable {
    var id: String { petID }
    var petID: String
    var stars: Int
}

struct PetHatch: Identifiable {
    let id = UUID()
    let petID: String
    let stars: Int
    let result: String
}

struct MonsterDefinition: Identifiable, Hashable {
    let id: String
    let name: String
    let chapter: String
    let maxHP: Int
    let rewardXP: Int
    let rewardTickets: Int
    let rewardInsight: Int
    let symbol: String
    let spriteIndex: Int
    let trait: String
}

struct AdventureState: Codable, Hashable {
    var level: Int
    var experience: Int
    var stardust: Int
    var tickets: Int
    var insight: Int
    var monsterIndex: Int
    var monsterHP: Int
    var defeatedMonsters: Int
    var pityCount: Int
    var equippedWeaponID: String?
    var equippedArmorID: String?
    var equippedCharmID: String?
    var equippedItems: [String: String]?
    var equippedTechniqueIDs: [String]?
    var coins: Int?
    var heroHP: Int? = nil
    var battleAttempts: Int? = nil
    var attackCount: Int? = nil
    var lastBattleMessage: String? = nil
    var equipmentPityCount: Int? = nil
    var techniquePityCount: Int? = nil
    var equipmentPityCounters: PityCounters? = nil
    var techniquePityCounters: PityCounters? = nil
}

/// 兼容旧存档的游戏事件用语；只转换文案，不改技能 ID、等级与数值。
func normalizeSkillWording(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{529F}\u{6CD5}", with: "技能")
}

struct RewardEvent: Codable, Identifiable, Hashable {
    var id: String
    var date: Date
    var title: String
    var detail: String
    var symbol: String
}

struct DrawHistoryEntry: Codable, Identifiable, Hashable {
    var id: String
    var date: Date
    var title: String
    var detail: String
    var symbol: String
    var rarity: ItemRarity
}

struct SavingsLibrary: Codable {
    var lastLedgerAccountID: String? = nil
    var version: Int
    var goals: [SavingsGoal]
    var records: [SavingsRecord]
    var adventure: AdventureState
    var equipment: [OwnedEquipment]
    var techniques: [TechniqueProgress]
    var rewardEvents: [RewardEvent]
    var drawHistory: [DrawHistoryEntry]
    var accounts: [LedgerAccount]?
    var ledgerEntries: [LedgerEntry]?
    var budgets: [BudgetPlan]?
    var pets: [OwnedPet]? = nil
    var equippedPetIDs: [String]? = nil
    /// 周期自动记账规则（V2.3 新增）。旧档缺失时按空数组处理。
    var recurringRules: [RecurringRule]? = nil
}

struct BattleOutcome: Identifiable {
    let id = UUID()
    let damage: Int
    let experience: Int
    let stardust: Int
    let monsterName: String
    let remainingHP: Int
    let maxHP: Int
    let defeated: Bool
    let leveledUp: Bool
    let goalCompleted: Bool
}

struct DrawReveal: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let symbol: String
    let rarity: ItemRarity
}

/// 格式化器集中缓存。DateFormatter/NumberFormatter 创建昂贵且非线程安全，
/// 约定仅在主线程使用（视图渲染与 SavingsStore 均在 @MainActor 上）。
enum SavingsFormatters {
    static let day: DateFormatter = {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.dateFormat = "yyyy年M月d日"; return formatter
    }()
    static let shortDay: DateFormatter = {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.dateFormat = "M月d日"; return formatter
    }()
    static let month: DateFormatter = {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.dateFormat = "yyyy年M月"; return formatter
    }()
    /// 3.37④：星期表头跟随界面语言（日历可访问性配套）；顺序仍周日开头与网格一致。
    static var weekdaySymbols: [String] {
        let calendar = Calendar.autoupdatingCurrent
        return calendar.veryShortWeekdaySymbols
    }
    private static let monthKeyFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM"; return formatter
    }()
    /// 每个币种一个缓存实例，配置与原先每次新建时完全一致。
    private static var moneyFormatters: [SavingsCurrency: NumberFormatter] = [:]
    private static func moneyFormatter(for currency: SavingsCurrency) -> NumberFormatter {
        if let cached = moneyFormatters[currency] { return cached }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.rawValue
        formatter.currencySymbol = currency.symbol
        formatter.minimumFractionDigits = currency.fractionDigits
        formatter.maximumFractionDigits = currency.fractionDigits
        formatter.locale = Locale(identifier: "zh_CN")
        moneyFormatters[currency] = formatter
        return formatter
    }
    static func money(_ value: Double, currency: SavingsCurrency, signed: Bool = false) -> String {
        let text = moneyFormatter(for: currency).string(from: NSNumber(value: abs(value))) ?? "\(currency.symbol)\(abs(value))"
        guard signed, value != 0 else { return value < 0 ? "−\(text)" : text }
        return value > 0 ? "+\(text)" : "−\(text)"
    }
    /// Decimal 重载：边界转为 Double 后走同一格式化器，输出与 Double 版本一致。
    static func money(_ value: Decimal, currency: SavingsCurrency, signed: Bool = false) -> String {
        money(MoneyValue.double(value), currency: currency, signed: signed)
    }
    static func monthKey(_ date: Date) -> String {
        monthKeyFormatter.string(from: date)
    }
}

/// 祈愿与掉落共用的安全抽取入口：优先在指定品质池内随机，池为空时回退到全图鉴；
/// 图鉴整体为空时返回 nil，由调用方安全处理（不再强制解包）。
extension SavingsCatalog {
    static func randomEquipment(rarity: ItemRarity) -> EquipmentDefinition? {
        let pool = equipment.filter { $0.rarity == rarity }
        return (pool.isEmpty ? equipment : pool).randomElement()
    }

    static func randomTechnique(rarity: ItemRarity) -> TechniqueDefinition? {
        let pool = techniques.filter { $0.rarity == rarity }
        return (pool.isEmpty ? techniques : pool).randomElement()
    }
}
