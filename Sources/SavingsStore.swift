import Combine
import Darwin
import Foundation
#if !SMOKE_TEST
import AppKit
import WidgetKit
#endif

/// 数据层主文件：只保留存储属性、init、snapshot()/apply()（含迁移链）与初始数据。
/// 方法按域拆分在同模块的 extension 文件中（均为 @MainActor 同类型扩展，无 API 变化）：
/// - StorePersistence.swift  保存/加载/迁移备份/恢复/小组件快照
/// - StoreLedger.swift       账本、账户、预算与周期自动记账
/// - StoreGoals.swift        攒钱目标与积蓄记录
/// - StoreBattle.swift       战斗属性（HeroStatsCalculator 薄封装）与自动战斗循环
/// - StoreGameSystems.swift  装备/技能/祈愿/宠物等游戏系统
@MainActor
final class SavingsStore: ObservableObject {
    /// 存档 schema 版本。V23：财务金额 Decimal 化（JSON 仍为 Double 字面量，结构兼容）、
    /// 新增周期自动记账规则与积蓄记录冗余币种；迁移见 apply() 的 v22→v23 段。
    static let currentSchemaVersion = 23
    static let maximumTechniqueSlots = 12
    static let maximumPetSlots = GameProgression.maximumEquippedPets
    @Published var goals: [SavingsGoal] = []
    @Published var records: [SavingsRecord] = []
    @Published var accounts: [LedgerAccount] = []
    @Published var ledgerEntries: [LedgerEntry] = []
    @Published var budgets: [BudgetPlan] = []
    /// 周期自动记账规则（V2.3 新增）。
    @Published var recurringRules: [RecurringRule] = []
    @Published var adventure = AdventureState(
        level: 1, experience: 0, stardust: 0, tickets: 10, insight: 0,
        monsterIndex: 0, monsterHP: 100, defeatedMonsters: 0, pityCount: 0,
        equippedWeaponID: nil, equippedArmorID: nil, equippedCharmID: nil,
        equippedItems: [:], equippedTechniqueIDs: [], coins: nil
    )
    @Published var equipment: [OwnedEquipment] = []
    @Published var techniques: [TechniqueProgress] = []
    @Published var pets: [OwnedPet] = []
    @Published var equippedPetIDs: [String] = []
    @Published var rewardEvents: [RewardEvent] = []
    @Published var drawHistory: [DrawHistoryEntry] = []
    @Published var battleOutcome: BattleOutcome?
    @Published var drawReveals: [DrawReveal] = []
    @Published var latestPetHatch: PetHatch?
    @Published var notice: String?
    @Published var lastPlayerDamage = 0
    @Published var lastEnemyDamage = 0
    @Published var lastHitCritical = false

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    /// 存档防抖间隔（秒）。间隔内多次 save() 只落盘一次；设为 0 时恢复同步立即写（测试用）。
    var saveDebounceInterval: TimeInterval = 8
    @Published private(set) var loadFailed = false
    func setLoadFailed(_ value: Bool) { loadFailed = value }
    /// 小组件快照统计币种。本版本默认 CNY，可由外部设置。
    var widgetCurrencyCode: String = "CNY"
    /// 财务数据脏标记：只有财务口径变化才需要重算并重写小组件快照。
    var financesDirty = true
    var saveIsDirty = false
    var pendingSaveWorkItem: DispatchWorkItem?

    @Published var lastLedgerAccountID: String?

    init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        load()
        #if !SMOKE_TEST
        // 退出前把防抖窗口内未落盘的脏数据同步写盘。
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushSave() }
        }
        #endif
    }

    // MARK: - Snapshot and migration

    func snapshot() -> SavingsLibrary {
        .init(lastLedgerAccountID: lastLedgerAccountID, version: Self.currentSchemaVersion, goals: goals, records: records, adventure: adventure, equipment: equipment, techniques: techniques,
              rewardEvents: rewardEvents, drawHistory: drawHistory, accounts: accounts, ledgerEntries: ledgerEntries, budgets: budgets,
              pets: pets, equippedPetIDs: equippedPetIDs, recurringRules: recurringRules)
    }

    func apply(_ library: SavingsLibrary) {
        backupLibraryBeforeMigration(fromVersion: library.version)
        lastLedgerAccountID = library.lastLedgerAccountID
        financesDirty = true
        goals = library.goals; records = library.records.sorted { $0.date > $1.date }
        accounts = library.accounts ?? Self.starterAccounts(); ledgerEntries = (library.ledgerEntries ?? []).sorted { $0.date > $1.date }; budgets = library.budgets ?? []
        recurringRules = library.recurringRules ?? []
        adventure = library.adventure
        adventure.lastBattleMessage = adventure.lastBattleMessage.map(normalizeSkillWording)
        equipment = library.equipment.map {
            var owned = $0
            owned.enhancementLevel = min(GameProgression.maximumEquipmentEnhancement, max(0, owned.enhancementLevel ?? 0))
            return owned
        }
        techniques = library.techniques
        removeDuplicateTechniques()
        pets = normalizedPets(library.pets ?? [])
        var seenPetIDs = Set<String>()
        equippedPetIDs = Array((library.equippedPetIDs ?? []).filter {
            seenPetIDs.insert($0).inserted && petStars($0) > 0 && SavingsCatalog.pet($0) != nil
        }.prefix(Self.maximumPetSlots))
        latestPetHatch = nil
        rewardEvents = library.rewardEvents.map {
            var event = $0
            event.title = normalizeSkillWording(event.title)
            event.detail = normalizeSkillWording(event.detail)
            return event
        }.sorted { $0.date > $1.date }
        drawHistory = library.drawHistory.map {
            var entry = $0
            entry.title = normalizeSkillWording(entry.title)
            entry.detail = normalizeSkillWording(entry.detail)
            return entry
        }.sorted { $0.date > $1.date }
        migrateAdventureLoadout()
        if library.version < 3 {
            adventure.coins = max(10_000, adventure.coins ?? 0)
            adventure.tickets = max(10_000, adventure.tickets)
            adventure.insight = max(10_000, adventure.insight)
            adventure.stardust = max(10_000, adventure.stardust)
            addMigrationEvent(title: "旧版测试补给", detail: "金币、星券、悟性与星尘均已补足至至少 10,000。", symbol: "wrench.and.screwdriver.fill")
        } else if adventure.coins == nil { adventure.coins = 0 }
        adventure.monsterIndex = max(0, adventure.monsterIndex)
        if library.version < 4 {
            adventure.monsterHP = currentMonsterMaxHP
            adventure.heroHP = heroMaxHP
            adventure.battleAttempts = 0
            adventure.attackCount = 0
            adventure.lastBattleMessage = "V0.4 自动战斗已启动"
            addMigrationEvent(title: "V0.4 无限冒险", detail: "战斗改为每秒自动进行；失败会在原关重开，十种像素怪物循环且强度持续上涨。", symbol: "forward.fill")
        } else {
            adventure.monsterHP = min(max(1, adventure.monsterHP), currentMonsterMaxHP)
            adventure.heroHP = min(max(1, adventure.heroHP ?? heroMaxHP), heroMaxHP)
            adventure.battleAttempts = max(0, adventure.battleAttempts ?? 0)
            adventure.attackCount = max(0, adventure.attackCount ?? 0)
        }
        if library.version < 5 {
            addMigrationEvent(title: "V0.5 战利品更新", detail: "旧技能残页与重复条目已清理；击杀现在是经验的唯一来源，并有概率掉落装备或技能。", symbol: "shippingbox.fill")
        }
        if library.version < 10 {
            rewardEvents = rewardEvents.map {
                var event = $0
                event.detail = "旧版历史结算（规则已停用）· " + event.detail
                return event
            }
            drawHistory = drawHistory.map {
                var entry = $0
                entry.detail = "旧版记录 · " + entry.detail
                return entry
            }
            adventure.equipmentPityCount = adventure.equipmentPityCount ?? adventure.pityCount
            adventure.techniquePityCount = adventure.techniquePityCount ?? adventure.pityCount
            addMigrationEvent(title: "V1.0 战力与强化", detail: "装备等级已改为 +0 至 +10 强化；装备、技能、角色和怪物均已接入战力评估，祈愿池与货币来源也已重构。", symbol: "bolt.shield.fill")
        }
        if library.version < 11 {
            addMigrationEvent(title: "V1.1 装备整理", detail: "一键出售已支持史诗品质；一键装备会按每个部位的未强化初始战力选择最强装备。", symbol: "wand.and.stars")
        }
        if library.version < 12 {
            adventure.monsterHP = min(max(1, adventure.monsterHP), currentMonsterMaxHP)
            adventure.heroHP = min(max(1, adventure.heroHP ?? heroMaxHP), heroMaxHP)
            addMigrationEvent(title: "V1.2 数值重制", detail: "重算角色、装备、技能与怪物战力，限制异常回复和减伤叠加，并让双方战力差直接校准实战伤害。", symbol: "scalemass.fill")
        }
        if library.version < 13 {
            let equipmentRare = adventure.equipmentPityCount ?? adventure.pityCount
            let techniqueRare = adventure.techniquePityCount ?? adventure.pityCount
            adventure.equipmentPityCounters = migratedPityCounters(for: .equipment, rareCount: equipmentRare)
            adventure.techniquePityCounters = migratedPityCounters(for: .technique, rareCount: techniqueRare)
            addMigrationEvent(title: "V1.3 阶梯保底", detail: "装备池与技能池分别累计：10 抽稀有、30 抽史诗、150 抽传说、500 抽神话、2000 抽绝世。", symbol: "shield.checkered")
        }
        if library.version < 14 {
            addMigrationEvent(title: "V1.4 技能整理", detail: "新增普通至传说五档一键遗忘；已装配技能会保留，并按品质及参悟投入返还悟性。", symbol: "brain.head.profile")
        }
        if library.version < 15 {
            addMigrationEvent(title: "V1.5 九十九重成长", detail: "装备强化与技能参悟上限提升至 99，后期每级属性和战力增量会逐步提高。", symbol: "chart.line.uptrend.xyaxis")
        }
        if library.version < 16 {
            addMigrationEvent(title: "V1.6 账户联动与宠物", detail: "积蓄记录现在同步生成账户转账；新增 12 种三形态宠物、4 个上阵位、99 星成长与宠物商店。", symbol: "pawprint.fill")
        }
        if library.version < 17 {
            addMigrationEvent(title: "V1.7 紧凑流水表", detail: "日常记账和积蓄记录改用紧凑表格展示，让日期、账户、分类、备注与金额在同一行快速浏览。", symbol: "list.bullet.rectangle.fill")
        }
        if library.version < 18 {
            addMigrationEvent(title: "V1.8 桌面小组件", detail: "新增月度每日收支与积蓄日历、净资产小组件；财务总览同步展示日历统计，账户速览按净资产贡献从高到低排列。", symbol: "rectangle.on.rectangle.angled")
        }
        if library.version < 22 {
            // V22 数据层性能与持久化改造：存档结构无变化，仅推进 schema 版本，无迁移事件。
        }
        if library.version < 23 {
            // V23 财务口径升级：回填积蓄记录冗余币种（优先目标币种，其次存钱罐/资金账户币种）。
            // 周期记账规则为新增可选字段，旧档解码即为空数组；与 V22 一致不追加迁移事件。
            records = records.map { record in
                var record = record
                if record.currency.isEmpty { record.currency = backfilledRecordCurrency(for: record) }
                return record
            }
        }
        setPityCounters(pityCounters(for: .equipment), for: .equipment)
        setPityCounters(pityCounters(for: .technique), for: .technique)
    }

    // MARK: - Starter data

    static func starterAccounts() -> [LedgerAccount] {
        [
            .init(id: UUID().uuidString, name: "现金", type: .cash, currency: .CNY, openingBalance: 0, symbol: LedgerAccountType.cash.symbol, colorKey: "green", includeInNetWorth: true, isArchived: false, createdAt: Date()),
            .init(id: UUID().uuidString, name: "银行卡", type: .bank, currency: .CNY, openingBalance: 0, symbol: LedgerAccountType.bank.symbol, colorKey: "blue", includeInNetWorth: true, isArchived: false, createdAt: Date().addingTimeInterval(1))
        ]
    }

    static func starterLibrary() -> SavingsLibrary {
        let goal = SavingsGoal(id: UUID().uuidString, title: "第一桶金", targetAmount: 10_000, startingAmount: 0, currency: .CNY,
                               deadline: Calendar.current.date(byAdding: .month, value: 6, to: Date()) ?? Date(), symbol: "flag.checkered",
                               colorKey: "blue", notes: "从第一笔目标分配开始，让勇者陪你抵达目标。", status: .active, createdAt: Date(), completedAt: nil)
        return .init(version: Self.currentSchemaVersion, goals: [goal], records: [],
                     adventure: .init(level: 1, experience: 0, stardust: 10_000, tickets: 10_000, insight: 10_000,
                                      monsterIndex: 0, monsterHP: SavingsCatalog.monsters[0].maxHP, defeatedMonsters: 0, pityCount: 0,
                                      equippedWeaponID: "wood-sword", equippedArmorID: "cloth-vest", equippedCharmID: nil,
                                      equippedItems: [EquipmentSlot.mainHand.rawValue: "wood-sword", EquipmentSlot.chest.rawValue: "cloth-vest"],
                                      equippedTechniqueIDs: ["steady-heart"], coins: 10_000, heroHP: nil, battleAttempts: 0, attackCount: 0,
                                      lastBattleMessage: "每秒自动战斗，失败会在原关重开"),
                     equipment: [.init(definitionID: "wood-sword", count: 1), .init(definitionID: "cloth-vest", count: 1)],
                     techniques: [.init(techniqueID: "steady-heart", level: 1)],
                     rewardEvents: [.init(id: UUID().uuidString, date: Date(), title: "冒险开始", detail: "记账整理生活，给目标分配积蓄，勇者便会随你成长。", symbol: "sparkles")],
                     drawHistory: [], accounts: starterAccounts(), ledgerEntries: [], budgets: [], pets: [], equippedPetIDs: [])
    }
}

enum SavingsStoreError: LocalizedError {
    case unsupportedVersion
    var errorDescription: String? { "该备份来自更高版本的搞积蓄，当前版本暂时无法恢复。" }
}
