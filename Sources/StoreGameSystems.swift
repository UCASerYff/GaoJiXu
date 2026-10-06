import Foundation

/// 游戏系统域：装备、技能、祈愿、宠物与资源兑换，以及勇者属性计算的输入聚合。
extension SavingsStore {
    var coins: Int { adventure.coins ?? 0 }
    var equippedTechniqueIDs: [String] { adventure.equippedTechniqueIDs ?? [] }

    // MARK: - Hero stat inputs（供 HeroStatsCalculator 使用）

    var equippedDefinitions: [EquipmentDefinition] {
        EquipmentSlot.allCases.compactMap { SavingsCatalog.equipment(equippedItemID(for: $0)) }
    }

    var equippedPetPairs: [(PetDefinition, Int)] {
        equippedPetIDs.compactMap { id in
            guard let definition = SavingsCatalog.pet(id), let owned = pets.first(where: { $0.petID == id }) else { return nil }
            return (definition, min(GameProgression.maximumPetStars, max(1, owned.stars)))
        }
    }

    /// 装备聚合贡献：与 equipmentIntTotal/equipmentDoubleTotal 相同的强化后逐件累加。
    var equipmentContributions: HeroStatContributions {
        var contributions = HeroStatContributions()
        for definition in equippedDefinitions {
            contributions.attack += enhanced(definition.attack, for: definition)
            contributions.defense += enhanced(definition.defense, for: definition)
            contributions.vitality += enhanced(definition.vitality, for: definition)
            contributions.speed += enhanced(definition.speed, for: definition)
            contributions.fortune += enhanced(definition.fortune, for: definition)
            contributions.physicalDamage += enhanced(definition.physicalDamage, for: definition)
            contributions.magicDamage += enhanced(definition.magicDamage, for: definition)
            contributions.trueDamage += enhanced(definition.trueDamage, for: definition)
            contributions.shield += enhanced(definition.shield, for: definition)
            contributions.physicalResistance += enhanced(definition.physicalResistance, for: definition)
            contributions.magicResistance += enhanced(definition.magicResistance, for: definition)
            contributions.critical += enhanced(definition.critical, for: definition)
            contributions.criticalDamage += enhanced(definition.criticalDamage, for: definition)
            contributions.lifesteal += enhanced(definition.lifesteal, for: definition)
            contributions.damageReduction += enhanced(definition.damageReduction, for: definition)
        }
        return contributions
    }

    /// 宠物聚合贡献：与 petIntTotal 相同的星级缩放后逐只累加。
    var petContributions: HeroStatContributions {
        var contributions = HeroStatContributions()
        for pair in equippedPetPairs {
            let multiplier = GameProgression.petMultiplier(stars: pair.1)
            contributions.attack += Int((Double(pair.0.attack) * multiplier).rounded())
            contributions.defense += Int((Double(pair.0.defense) * multiplier).rounded())
            contributions.vitality += Int((Double(pair.0.vitality) * multiplier).rounded())
            contributions.speed += Int((Double(pair.0.speed) * multiplier).rounded())
            contributions.fortune += Int((Double(pair.0.fortune) * multiplier).rounded())
            contributions.physicalDamage += Int((Double(pair.0.physicalDamage) * multiplier).rounded())
            contributions.magicDamage += Int((Double(pair.0.magicDamage) * multiplier).rounded())
            contributions.shield += Int((Double(pair.0.shield) * multiplier).rounded())
        }
        return contributions
    }

    /// 已装配技能按效果聚合的加成表：与逐个 techniqueBonus(_:) 求值等价。
    var techniqueBonusMap: [TechniqueEffect: Double] {
        var map: [TechniqueEffect: Double] = [:]
        for id in equippedTechniqueIDs {
            guard let definition = SavingsCatalog.technique(id) else { continue }
            map[definition.effect, default: 0] += definition.effectPerLevel * GameProgression.techniqueScale(level: techniqueLevel(id))
        }
        return map
    }

    func enhancementLevel(for definitionID: String) -> Int {
        min(GameProgression.maximumEquipmentEnhancement, max(0, equipment.first(where: { $0.definitionID == definitionID })?.enhancementLevel ?? 0))
    }

    func enhancementMultiplier(for definitionID: String) -> Double {
        GameProgression.equipmentMultiplier(level: enhancementLevel(for: definitionID))
    }

    func enhanced(_ value: Int, for definition: EquipmentDefinition) -> Int {
        max(0, Int((Double(value) * enhancementMultiplier(for: definition.id)).rounded()))
    }

    func enhanced(_ value: Double, for definition: EquipmentDefinition) -> Double {
        max(0, value * enhancementMultiplier(for: definition.id))
    }

    func equipmentBattlePower(_ definition: EquipmentDefinition) -> Int {
        max(1, Int((Double(definition.baseBattlePower) * enhancementMultiplier(for: definition.id)).rounded()))
    }

    func techniqueBattlePower(_ definition: TechniqueDefinition, level requestedLevel: Int? = nil) -> Int {
        let level = min(GameProgression.maximumTechniqueLevel, max(1, requestedLevel ?? techniqueLevel(definition.id)))
        let levelScale = GameProgression.techniqueScale(level: level)
        let value = definition.effectPerLevel * levelScale
        let effectPower: Int
        switch definition.effect {
        case .attack: effectPower = Int(value * Double(BattleStatWeights.attack))
        case .defense: effectPower = Int(value * Double(BattleStatWeights.defense))
        case .vitality: effectPower = Int(value * Double(BattleStatWeights.vitality))
        case .critical: effectPower = Int(value * BattleStatWeights.critical)
        case .criticalDamage: effectPower = Int(value * BattleStatWeights.criticalDamage)
        case .lifesteal: effectPower = Int(value * BattleStatWeights.lifesteal)
        case .speed: effectPower = Int(value * Double(BattleStatWeights.speed))
        case .physicalResistance, .magicResistance: effectPower = Int(value * Double(BattleStatWeights.resistance))
        case .physicalDamage: effectPower = Int(value * Double(BattleStatWeights.physicalDamage))
        case .magicDamage: effectPower = Int(value * Double(BattleStatWeights.magicDamage))
        case .trueDamage: effectPower = Int(value * Double(BattleStatWeights.trueDamage))
        case .damageReduction: effectPower = Int(value * BattleStatWeights.damageReduction)
        case .shield: effectPower = Int(value * BattleStatWeights.shield)
        case .bossDamage: effectPower = Int(value * 2_000)
        case .experience, .stardust: effectPower = Int(value * 400)
        case .depositPower: effectPower = Int(value * 100 * Double(BattleStatWeights.trueDamage))
        case .streakPower: effectPower = Int(value * 100 * Double(BattleStatWeights.speed))
        case .budgetPower: effectPower = Int(value * 100 * Double(BattleStatWeights.defense))
        case .incomePower: effectPower = Int(value * 100 * Double(BattleStatWeights.attack))
        case .expenseGuard: effectPower = Int(value * 100 * BattleStatWeights.shield)
        case .fortune: effectPower = Int(value * Double(BattleStatWeights.fortune))
        }
        let signaturePower = Int(definition.signaturePowerPerLevel * levelScale * definition.signatureSkill.battlePowerWeight)
        return max(1, definition.rarity.rawValue * 100 + effectPower + signaturePower)
    }

    func baseTechniqueBattlePower(_ definition: TechniqueDefinition) -> Int {
        techniqueBattlePower(definition, level: 1)
    }

    // MARK: - Pets

    func ownedPet(_ id: String) -> OwnedPet? { pets.first { $0.petID == id } }
    func petStars(_ id: String) -> Int { ownedPet(id)?.stars ?? 0 }
    func petBattlePower(_ definition: PetDefinition) -> Int { definition.battlePower(stars: max(1, petStars(definition.id))) }
    func petLifeStage(_ definition: PetDefinition) -> PetLifeStage { PetLifeStage.stage(for: max(1, petStars(definition.id))) }
    func isPetEquipped(_ id: String) -> Bool { equippedPetIDs.contains(id) }

    @discardableResult
    func grantPetReward(_ definition: PetDefinition) -> String {
        if let index = pets.firstIndex(where: { $0.petID == definition.id }) {
            if pets[index].stars >= GameProgression.maximumPetStars {
                adventure.coins = coins + GameProgression.petEggCost
                return "已满 99 星 · 转化为 \(GameProgression.petEggCost.formatted()) 金币"
            }
            pets[index].stars = min(GameProgression.maximumPetStars, pets[index].stars + 1)
            return "升至 \(pets[index].stars) 星 · \(PetLifeStage.stage(for: pets[index].stars).title)"
        }
        pets.append(.init(petID: definition.id, stars: 1))
        return "首次获得 · 1 星幼年体"
    }

    func hatchPetEgg() {
        guard coins >= GameProgression.petEggCost else { notice = "金币不足，宠物蛋需要 \(GameProgression.petEggCost.formatted()) 金币。"; return }
        guard let definition = SavingsCatalog.pets.randomElement() else { return }
        adventure.coins = coins - GameProgression.petEggCost
        let result = grantPetReward(definition)
        latestPetHatch = .init(petID: definition.id, stars: petStars(definition.id), result: result)
        addEvent(title: "宠物蛋孵化", detail: "孵化出“\(definition.name)”：\(result)。", symbol: "pawprint.fill")
        save()
    }

    func equipPet(_ definition: PetDefinition) {
        guard petStars(definition.id) > 0 else { notice = "需要先孵化这只宠物。"; return }
        guard !equippedPetIDs.contains(definition.id) else { return }
        guard equippedPetIDs.count < Self.maximumPetSlots else { notice = "最多同时上阵 \(Self.maximumPetSlots) 只宠物。"; return }
        equippedPetIDs.append(definition.id)
        addEvent(title: "宠物上阵", detail: "“\(definition.name)”已加入冒险队伍。", symbol: "pawprint.fill")
        save()
    }

    func unequipPet(_ definition: PetDefinition) {
        equippedPetIDs.removeAll { $0 == definition.id }
        save()
    }

    func equipBestPets() {
        let selected = pets.compactMap { owned -> PetDefinition? in
            guard owned.stars > 0 else { return nil }
            return SavingsCatalog.pet(owned.petID)
        }.sorted { lhs, rhs in
            let lhsPower = petBattlePower(lhs), rhsPower = petBattlePower(rhs)
            if lhsPower != rhsPower { return lhsPower > rhsPower }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }.prefix(Self.maximumPetSlots).map(\.id)
        guard !selected.isEmpty else { notice = "宠物背包里还没有伙伴。"; return }
        equippedPetIDs = Array(selected)
        addEvent(title: "宠物一键上阵", detail: "已按当前星级战力选出最强的 \(selected.count) 只宠物。", symbol: "pawprint.fill")
        notice = "一键上阵完成：已按当前战力选择 \(selected.count) 只宠物。"
        save()
    }

    // MARK: - Equipment and techniques

    func ownedCount(of definitionID: String) -> Int { equipment.first(where: { $0.definitionID == definitionID })?.count ?? 0 }
    func techniqueProgress(_ id: String) -> TechniqueProgress { techniques.first(where: { $0.techniqueID == id }) ?? .init(techniqueID: id, level: 0) }
    func techniqueLevel(_ id: String) -> Int { techniqueProgress(id).level }
    func equippedItemID(for slot: EquipmentSlot) -> String? { adventure.equippedItems?[slot.rawValue] }

    func equip(_ definition: EquipmentDefinition) {
        guard ownedCount(of: definition.id) > 0 else { return }
        var items = adventure.equippedItems ?? [:]; items[definition.slot.rawValue] = definition.id; adventure.equippedItems = items
        addEvent(title: "更换装备", detail: "已将“\(definition.name)”装备至\(definition.slot.title)。", symbol: definition.symbol); save()
    }

    func unequip(_ slot: EquipmentSlot) {
        var items = adventure.equippedItems ?? [:]; items.removeValue(forKey: slot.rawValue); adventure.equippedItems = items; save()
    }

    func equipBestByBasePower() {
        let ownedDefinitions = equipment.compactMap { owned -> EquipmentDefinition? in
            guard owned.count > 0 else { return nil }
            return SavingsCatalog.equipment(owned.definitionID)
        }
        var selected: [String: String] = [:]
        for slot in EquipmentSlot.allCases {
            let best = ownedDefinitions.filter { $0.slot == slot }.max { lhs, rhs in
                if lhs.baseBattlePower != rhs.baseBattlePower { return lhs.baseBattlePower < rhs.baseBattlePower }
                if lhs.rarity != rhs.rarity { return lhs.rarity.rawValue < rhs.rarity.rawValue }
                return lhs.name.localizedCompare(rhs.name) == .orderedDescending
            }
            if let best { selected[slot.rawValue] = best.id }
        }
        guard !selected.isEmpty else { notice = "背包里还没有可以装备的物品。"; return }
        adventure.equippedItems = selected
        addEvent(title: "一键装备", detail: "已按未强化的初始战力，为 \(selected.count) 个装备位换上当前最强装备。", symbol: "wand.and.stars")
        notice = "一键装备完成：已按初始战力选择 \(selected.count) 个部位；强化加成未参与比较。"
        save()
    }

    func equipBestTechniquesByBasePower() {
        let learned = techniques.compactMap { progress -> TechniqueDefinition? in
            guard progress.level > 0 else { return nil }
            return SavingsCatalog.technique(progress.techniqueID)
        }
        let selected = learned.sorted { lhs, rhs in
            let lhsPower = baseTechniqueBattlePower(lhs), rhsPower = baseTechniqueBattlePower(rhs)
            if lhsPower != rhsPower { return lhsPower > rhsPower }
            if lhs.rarity != rhs.rarity { return lhs.rarity.rawValue > rhs.rarity.rawValue }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }.prefix(Self.maximumTechniqueSlots).map(\.id)
        guard !selected.isEmpty else { notice = "还没有已学技能可以装配。"; return }
        adventure.equippedTechniqueIDs = Array(selected)
        addEvent(title: "技能一键装配", detail: "已按未参悟的 1 重初始战力，装配当前最强的 \(selected.count) 门技能。", symbol: "books.vertical.fill")
        notice = "技能一键装配完成：比较的是 1 重初始战力，当前参悟等级未参与选择。"
        save()
    }

    func techniqueForgetInsight(_ definition: TechniqueDefinition, level requestedLevel: Int? = nil) -> Int {
        let level = min(GameProgression.maximumTechniqueLevel, max(1, requestedLevel ?? techniqueLevel(definition.id)))
        let rarity = definition.rarity.rawValue
        let baseReturn = rarity * rarity * 40
        let investedInsight = level > 1 ? (1..<level).reduce(0) {
            $0 + GameProgression.techniqueUpgradeCost(rarity: definition.rarity, currentLevel: $1)
        } : 0
        return baseReturn + investedInsight
    }

    func forgetTechniques(upTo maximumRarity: ItemRarity) {
        let equippedIDs = Set(equippedTechniqueIDs)
        var forgottenCount = 0
        var returnedInsight = 0
        for index in techniques.indices.reversed() {
            let progress = techniques[index]
            guard progress.level > 0,
                  !equippedIDs.contains(progress.techniqueID),
                  let definition = SavingsCatalog.technique(progress.techniqueID),
                  definition.rarity.rawValue <= maximumRarity.rawValue else { continue }
            forgottenCount += 1
            returnedInsight += techniqueForgetInsight(definition, level: progress.level)
            techniques.remove(at: index)
        }
        guard forgottenCount > 0 else {
            notice = "没有可遗忘的\(maximumRarity.title)及以下未装配技能。"
            return
        }
        adventure.insight += returnedInsight
        addEvent(title: "一键遗忘", detail: "遗忘 \(forgottenCount) 门\(maximumRarity.title)及以下未装配技能，返还 \(returnedInsight) 悟性。", symbol: "brain.head.profile")
        notice = "一键遗忘完成：\(forgottenCount) 门技能返还 \(returnedInsight) 悟性。"
        save()
    }

    func equipmentSaleStardust(_ definition: EquipmentDefinition) -> Int {
        let base = definition.rarity.rawValue * definition.rarity.rawValue * 40
            + enhancementLevel(for: definition.id) * definition.rarity.rawValue * 20
        return max(1, Int((Double(base) * (1 + techniqueBonus(.stardust))).rounded()))
    }

    func equipmentEnhancementCost(_ definition: EquipmentDefinition) -> Int {
        let current = enhancementLevel(for: definition.id)
        guard current < GameProgression.maximumEquipmentEnhancement else { return 0 }
        return GameProgression.equipmentUpgradeCost(rarity: definition.rarity, nextLevel: current + 1)
    }

    func enhanceEquipment(_ definition: EquipmentDefinition) {
        guard let index = equipment.firstIndex(where: { $0.definitionID == definition.id }) else {
            notice = "背包中没有这件装备。"
            return
        }
        let current = enhancementLevel(for: definition.id)
        guard current < GameProgression.maximumEquipmentEnhancement else { notice = "这件装备已经强化至 +\(GameProgression.maximumEquipmentEnhancement)。"; return }
        let cost = equipmentEnhancementCost(definition)
        guard adventure.stardust >= cost else { notice = "星尘不足，本次强化需要 \(cost) 星尘。"; return }
        adventure.stardust -= cost
        equipment[index].enhancementLevel = current + 1
        addEvent(title: "装备强化", detail: "消耗 \(cost) 星尘，将“\(definition.name)”强化至 +\(current + 1)，战力提升至 \(equipmentBattlePower(definition))。", symbol: "sparkles")
        save()
    }

    func sellEquipment(_ definition: EquipmentDefinition, count requestedCount: Int = 1) {
        guard equippedItemID(for: definition.slot) != definition.id else { notice = "已装备的物品不能出售，请先卸下。"; return }
        guard let index = equipment.firstIndex(where: { $0.definitionID == definition.id }) else { notice = "背包中没有这件装备。"; return }
        let count = min(max(1, requestedCount), equipment[index].count)
        let earned = equipmentSaleStardust(definition) * count
        equipment[index].count -= count
        if equipment[index].count <= 0 { equipment.remove(at: index) }
        adventure.stardust += earned
        addEvent(title: "出售装备", detail: "出售 \(count) 件“\(definition.name)”，获得 \(earned) 星尘。", symbol: "sparkles")
        notice = "出售成功，获得 \(earned) 星尘。"
        save()
    }

    func sellUnusedDuplicates() {
        let equippedIDs = Set((adventure.equippedItems ?? [:]).values)
        var soldCount = 0, earned = 0
        for index in equipment.indices.reversed() {
            guard let definition = SavingsCatalog.equipment(equipment[index].definitionID) else { continue }
            let protectedCopies = equippedIDs.contains(definition.id) ? 1 : 0
            let removable = max(0, equipment[index].count - max(1, protectedCopies))
            guard removable > 0 else { continue }
            equipment[index].count -= removable
            soldCount += removable
            earned += equipmentSaleStardust(definition) * removable
        }
        guard soldCount > 0 else { notice = "没有可清理的重复装备；每种装备会保留 1 件。"; return }
        adventure.stardust += earned
        addEvent(title: "清理重复装备", detail: "出售 \(soldCount) 件重复装备，获得 \(earned) 星尘。", symbol: "shippingbox.and.arrow.backward.fill")
        notice = "已保留每种装备 1 件，出售 \(soldCount) 件并获得 \(earned) 星尘。"
        save()
    }

    func sellEquipment(upTo maximumRarity: ItemRarity) {
        let equippedIDs = Set((adventure.equippedItems ?? [:]).values)
        var soldCount = 0, earned = 0
        for index in equipment.indices.reversed() {
            guard let definition = SavingsCatalog.equipment(equipment[index].definitionID),
                  definition.rarity.rawValue <= maximumRarity.rawValue else { continue }
            let kept = equippedIDs.contains(definition.id) ? 1 : 0
            let removable = max(0, equipment[index].count - kept)
            guard removable > 0 else { continue }
            soldCount += removable
            earned += equipmentSaleStardust(definition) * removable
            equipment[index].count -= removable
            if equipment[index].count <= 0 { equipment.remove(at: index) }
        }
        guard soldCount > 0 else {
            notice = "没有可出售的\(maximumRarity.title)及以下未装备物品。"
            return
        }
        adventure.stardust += earned
        addEvent(title: "一键出售", detail: "出售 \(soldCount) 件\(maximumRarity.title)及以下未装备物品，获得 \(earned) 星尘。", symbol: "trash.slash.fill")
        notice = "一键出售完成：\(soldCount) 件装备转化为 \(earned) 星尘。"
        save()
    }

    func exchangeCoinsForTicket() {
        let cost = 500
        guard coins >= cost else { notice = "金币不足，需要 \(cost) 金币。"; return }
        adventure.coins = coins - cost
        adventure.tickets += 1
        addEvent(title: "兑换星券", detail: "消耗 \(cost) 金币兑换 1 张免费星券。", symbol: "ticket.fill")
        save()
    }

    func exchangeCoinsForInsight() {
        exchangeCoins(cost: 500, amount: 50, resource: "悟性") { adventure.insight += $0 }
    }

    func exchangeCoinsForStardust() {
        exchangeCoins(cost: 500, amount: 50, resource: "星尘") { adventure.stardust += $0 }
    }

    private func exchangeCoins(cost: Int, amount: Int, resource: String, apply: (Int) -> Void) {
        guard coins >= cost else { notice = "金币不足，需要 \(cost) 金币。"; return }
        adventure.coins = coins - cost
        apply(amount)
        addEvent(title: "冒险商店", detail: "消耗 \(cost) 金币购买 \(amount) \(resource)。", symbol: "cart.fill")
        save()
    }

    func isTechniqueEquipped(_ id: String) -> Bool { equippedTechniqueIDs.contains(id) }

    func toggleTechnique(_ definition: TechniqueDefinition) {
        guard techniqueLevel(definition.id) > 0 else { notice = "需要先获得这门技能。"; return }
        var ids = equippedTechniqueIDs
        if let index = ids.firstIndex(of: definition.id) { ids.remove(at: index) }
        else {
            guard ids.count < Self.maximumTechniqueSlots else {
                notice = "最多同时装配 \(Self.maximumTechniqueSlots) 门技能，请先卸下一门。"
                return
            }
            ids.append(definition.id)
        }
        adventure.equippedTechniqueIDs = ids; save()
    }

    func techniqueBonus(_ effect: TechniqueEffect) -> Double {
        equippedTechniqueIDs.reduce(0) { partial, id in
            guard let definition = SavingsCatalog.technique(id) else { return partial }
            return definition.effect == effect ? partial + definition.effectPerLevel * GameProgression.techniqueScale(level: techniqueLevel(id)) : partial
        }
    }

    func combatSkillPower(_ skill: CombatSkill) -> Double {
        let equipmentPower = equippedDefinitions.reduce(0.0) { partial, definition in
            let base = definition.uniqueAffixes.filter { $0.skill == skill }.reduce(0.0) { $0 + $1.power }
            let enhancementScale = 1 + (enhancementMultiplier(for: definition.id) - 1) * 0.5
            return partial + base * enhancementScale
        }
        let techniquePower = equippedTechniqueIDs.reduce(0.0) { partial, id in
            guard let definition = SavingsCatalog.technique(id), definition.signatureSkill == skill else { return partial }
            return partial + definition.signaturePowerPerLevel * GameProgression.techniqueScale(level: techniqueLevel(id))
        }
        return min(skill.maximumPower, equipmentPower + techniquePower)
    }

    // MARK: - Draw and pity

    func pityCount(for pool: DrawPool, rarity: ItemRarity = .rare) -> Int {
        pityCounters(for: pool).count(for: rarity)
    }

    func drawsUntilGuarantee(for pool: DrawPool, rarity: ItemRarity) -> Int {
        guard let threshold = rarity.guaranteeDraws else { return 0 }
        return max(1, threshold - pityCount(for: pool, rarity: rarity))
    }

    func pityCounters(for pool: DrawPool) -> PityCounters {
        switch pool {
        case .equipment:
            return adventure.equipmentPityCounters
                ?? PityCounters(rare: adventure.equipmentPityCount ?? adventure.pityCount)
        case .technique:
            return adventure.techniquePityCounters
                ?? PityCounters(rare: adventure.techniquePityCount ?? adventure.pityCount)
        }
    }

    func setPityCounters(_ counters: PityCounters, for pool: DrawPool) {
        let safeCounters = counters.clamped()
        switch pool {
        case .equipment:
            adventure.equipmentPityCounters = safeCounters
            adventure.equipmentPityCount = safeCounters.count(for: .rare)
        case .technique:
            adventure.techniquePityCounters = safeCounters
            adventure.techniquePityCount = safeCounters.count(for: .rare)
        }
    }

    private func guaranteedMinimumRarity(for pool: DrawPool) -> ItemRarity? {
        ItemRarity.guaranteedTiers.reversed().first { rarity in
            guard let threshold = rarity.guaranteeDraws else { return false }
            return pityCount(for: pool, rarity: rarity) >= threshold - 1
        }
    }

    private func recordPityDraw(_ rarity: ItemRarity, for pool: DrawPool) {
        var counters = pityCounters(for: pool)
        counters.record(rarity)
        setPityCounters(counters, for: pool)
    }

    func draw(count: Int, pool drawPool: DrawPool = .equipment) {
        guard count == 1 || count == 10 || count == 100 else {
            notice = "祈愿次数只支持 1、10 或 100 连，本次未扣券。"
            return
        }
        let actualCount = count
        guard adventure.tickets >= actualCount else { notice = "星券不足。每积蓄 1 个货币单位获得 1 张星券，也可使用金币购买。"; return }
        adventure.tickets -= actualCount
        var reveals: [DrawReveal] = []
        for _ in 0..<actualCount {
            let rarity = rollRarity(minimumRarity: guaranteedMinimumRarity(for: drawPool))
            switch drawPool {
            case .technique:
                if let definition = SavingsCatalog.randomTechnique(rarity: rarity) {
                    let subtitle = grantTechniqueReward(definition)
                    reveals.append(.init(title: definition.name, subtitle: "技能池 · \(subtitle)", symbol: definition.symbol, rarity: rarity))
                }
            case .equipment:
                if let definition = SavingsCatalog.randomEquipment(rarity: rarity) {
                    let subtitle = grantEquipmentReward(definition)
                    reveals.append(.init(title: definition.name, subtitle: "装备池 · \(subtitle)", symbol: definition.symbol, rarity: rarity))
                }
            }
            recordPityDraw(rarity, for: drawPool)
        }
        reveals.sort {
            if $0.rarity != $1.rarity { return $0.rarity.rawValue > $1.rarity.rawValue }
            return $0.title.localizedCompare($1.title) == .orderedAscending
        }
        drawReveals = reveals
        let drawnAt = Date()
        let entries = reveals.enumerated().map { index, reveal in
            DrawHistoryEntry(id: UUID().uuidString, date: drawnAt.addingTimeInterval(Double(-index) * 0.001),
                             title: reveal.title, detail: reveal.subtitle, symbol: reveal.symbol, rarity: reveal.rarity)
        }
        drawHistory = Array((entries + drawHistory).prefix(200)); save()
    }

    func techniqueUpgradeCost(_ definition: TechniqueDefinition) -> Int {
        let progress = techniqueProgress(definition.id)
        guard progress.level > 0, progress.level < GameProgression.maximumTechniqueLevel else { return 0 }
        return GameProgression.techniqueUpgradeCost(rarity: definition.rarity, currentLevel: progress.level)
    }

    func upgradeTechnique(_ definition: TechniqueDefinition) {
        guard let index = techniques.firstIndex(where: { $0.techniqueID == definition.id }), techniques[index].level > 0 else { notice = "需要先获得这门技能。"; return }
        let level = techniques[index].level
        guard level < GameProgression.maximumTechniqueLevel else { notice = "这门技能已经修炼至 \(GameProgression.maximumTechniqueLevel) 重。"; return }
        let cost = techniqueUpgradeCost(definition)
        guard adventure.insight >= cost else { notice = "悟性不足，本次参悟需要 \(cost) 点。"; return }
        adventure.insight -= cost; techniques[index].level += 1
        addEvent(title: "技能参悟", detail: "消耗 \(cost) 点悟性，将“\(definition.name)”修炼至 \(level + 1) 重。", symbol: definition.symbol); save()
    }

    // MARK: - Grants and rarity rolls

    private func addEquipment(_ id: String) {
        if let index = equipment.firstIndex(where: { $0.definitionID == id }) { equipment[index].count += 1 }
        else { equipment.append(.init(definitionID: id, count: 1)) }
    }

    @discardableResult
    func grantEquipmentReward(_ definition: EquipmentDefinition) -> String {
        if ownedCount(of: definition.id) > 0 {
            let converted = equipmentSaleStardust(definition) * max(2, definition.rarity.rawValue)
            adventure.stardust += converted
            return "重复转化 · +\(converted) 星尘"
        }
        addEquipment(definition.id)
        return "\(definition.slot.title) · \(definition.rarity.title)"
    }

    @discardableResult
    func grantTechniqueReward(_ definition: TechniqueDefinition) -> String {
        if techniqueLevel(definition.id) > 0 {
            let converted = definition.rarity.rawValue * definition.rarity.rawValue * 40
            adventure.insight += converted
            return "重复转化 · +\(converted) 悟性"
        }
        techniques.append(.init(techniqueID: definition.id, level: 1))
        return "技能 · \(definition.rarity.title) · \(definition.effect.title)"
    }

    func rollRarity(minimumRarity: ItemRarity?, fortune: Int? = nil) -> ItemRarity {
        let fortune = fortune ?? equippedFortune
        let ultraRoll = Int.random(in: 1...1_000_000)
        let rolled: ItemRarity
        if ultraRoll == 1 { rolled = .peerless }
        else if ultraRoll <= 101 { rolled = .mythic }
        else {
            let roll = max(1, Int.random(in: 1...1000) - min(180, fortune * 2))
            if roll <= 10 { rolled = .legendary }
            else if roll <= 60 { rolled = .epic }
            else if roll <= 200 { rolled = .rare }
            else if roll <= 520 { rolled = .fine }
            else { rolled = .common }
        }
        guard let minimumRarity, rolled.rawValue < minimumRarity.rawValue else { return rolled }
        return minimumRarity
    }

    // MARK: - Migration helpers（供 apply() 调用）

    func migrateAdventureLoadout() {
        if adventure.equippedItems == nil || adventure.equippedItems?.isEmpty == true {
            var items: [String: String] = [:]
            if let id = adventure.equippedWeaponID { items[EquipmentSlot.mainHand.rawValue] = id }
            if let id = adventure.equippedArmorID { items[EquipmentSlot.chest.rawValue] = id }
            if let id = adventure.equippedCharmID { items[EquipmentSlot.relic.rawValue] = id }
            adventure.equippedItems = items
        }
        if adventure.equippedTechniqueIDs == nil {
            adventure.equippedTechniqueIDs = Array(techniques.filter { $0.level > 0 }.prefix(Self.maximumTechniqueSlots).map(\.techniqueID))
        }
        var seen = Set<String>()
        adventure.equippedTechniqueIDs = Array((adventure.equippedTechniqueIDs ?? []).filter {
            seen.insert($0).inserted && techniqueLevel($0) > 0
        }.prefix(Self.maximumTechniqueSlots))
    }

    func removeDuplicateTechniques() {
        var order: [String] = []
        var best: [String: TechniqueProgress] = [:]
        for progress in techniques where progress.level > 0 {
            if best[progress.techniqueID] == nil { order.append(progress.techniqueID) }
            let highestLevel = min(GameProgression.maximumTechniqueLevel, max(best[progress.techniqueID]?.level ?? 0, progress.level))
            best[progress.techniqueID] = .init(techniqueID: progress.techniqueID, level: highestLevel)
        }
        techniques = order.compactMap { best[$0] }
    }

    func normalizedPets(_ source: [OwnedPet]) -> [OwnedPet] {
        var order: [String] = []
        var bestStars: [String: Int] = [:]
        for pet in source where SavingsCatalog.pet(pet.petID) != nil {
            if bestStars[pet.petID] == nil { order.append(pet.petID) }
            bestStars[pet.petID] = max(bestStars[pet.petID] ?? 0, min(GameProgression.maximumPetStars, max(1, pet.stars)))
        }
        return order.compactMap { id in bestStars[id].map { .init(petID: id, stars: $0) } }
    }

    func migratedPityCounters(for pool: DrawPool, rareCount: Int) -> PityCounters {
        var counters = PityCounters(rare: rareCount)
        let poolHistory = drawHistory.sorted { $0.date > $1.date }.filter { $0.detail.contains(pool.title) }
        for tier in ItemRarity.guaranteedTiers where tier != .rare {
            let maximum = max(0, (tier.guaranteeDraws ?? 1) - 1)
            var recentMisses = 0
            for entry in poolHistory {
                if entry.rarity.rawValue >= tier.rawValue { break }
                recentMisses += 1
                if recentMisses >= maximum { break }
            }
            counters.set(recentMisses, for: tier)
        }
        return counters.clamped()
    }
}
