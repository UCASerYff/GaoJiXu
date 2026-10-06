import Foundation

/// 战斗域：怪物数值、勇者属性（HeroStatsCalculator 薄封装）、战力评估与自动战斗循环。
extension SavingsStore {
    // MARK: - Monster and stage

    var currentMonster: MonsterDefinition {
        SavingsCatalog.monsters[max(0, adventure.monsterIndex) % SavingsCatalog.monsters.count]
    }

    var currentStage: Int { adventure.monsterIndex >= Int.max - 1 ? Int.max : max(1, adventure.monsterIndex + 1) }
    var currentMonsterMaxHP: Int { stageScaled(base: currentMonster.maxHP, growth: 1.11) }
    var currentMonsterAttack: Int {
        let traitMultiplier: Double = [1, 5, 7].contains(currentMonster.spriteIndex) ? 1.12 : 1
        return max(1, Int(Double(stageScaled(base: 9, growth: 1.088)) * traitMultiplier))
    }
    var currentMonsterPhysicalResistance: Int {
        let traitBonus = [2, 8, 9].contains(currentMonster.spriteIndex) ? 24 : 7
        return traitBonus + min(100_000, currentStage) * 2
    }
    var currentMonsterMagicResistance: Int {
        let traitBonus = [3, 7, 9].contains(currentMonster.spriteIndex) ? 24 : 7
        return traitBonus + min(100_000, currentStage) * 2
    }

    private func stageScaled(base: Int, growth: Double) -> Int {
        let safeBase = max(1, base)
        let maximum = Double(Int.max / 8)
        let step = Double(min(100_000, max(0, currentStage - 1)))
        let exponent = min(step * log(growth), log(maximum / Double(safeBase)))
        return max(safeBase, Int((Double(safeBase) * exp(exponent)).rounded()))
    }

    // MARK: - Hero stats（HeroStatsCalculator 薄封装，数值与原公式逐行等价）

    private var levelGrowth: Int { max(0, adventure.level - 1) }
    var baseAttack: Int { 12 + levelGrowth * 3 }
    var baseDefense: Int { 6 + levelGrowth * 2 }
    var baseVitality: Int { 24 + levelGrowth * 4 }
    var baseSpeed: Int { 10 + levelGrowth / 3 }
    var basePhysicalResistance: Int { 6 + levelGrowth / 3 }
    var baseMagicResistance: Int { 6 + levelGrowth / 3 }

    /// 全部勇者属性的一次性快照；各 equipped* 属性只是它的薄封装。
    private var heroStats: HeroStats {
        HeroStatsCalculator.stats(level: adventure.level, equipment: equipmentContributions, pets: petContributions,
                                  techniqueBonuses: techniqueBonusMap, fortificationPower: combatSkillPower(.fortification))
    }

    var equippedAttack: Int { heroStats.attack }
    var equippedDefense: Int { heroStats.defense }
    var equippedVitality: Int { heroStats.vitality }
    var equippedCritical: Double { heroStats.critical }
    var equippedFortune: Int { heroStats.fortune }
    var equippedPhysicalDamage: Int { heroStats.physicalDamage }
    var equippedMagicDamage: Int { heroStats.magicDamage }
    var equippedTrueDamage: Int { heroStats.trueDamage }
    var equippedCriticalDamage: Double { heroStats.criticalDamage }
    var equippedLifesteal: Double { heroStats.lifesteal }
    var equippedSpeed: Int { heroStats.speed }
    var equippedPhysicalResistance: Int { heroStats.physicalResistance }
    var equippedMagicResistance: Int { heroStats.magicResistance }
    var equippedDamageReduction: Double { heroStats.damageReduction }
    var equippedShield: Int { heroStats.shield }
    var heroMaxHP: Int { heroStats.maxHP }
    var heroHP: Int { min(heroMaxHP, max(0, adventure.heroHP ?? heroMaxHP)) }
    var battleAttempts: Int { adventure.battleAttempts ?? 0 }
    var lastBattleMessage: String { adventure.lastBattleMessage ?? "自动战斗准备就绪" }

    var experienceNeeded: Int { experienceNeeded(for: adventure.level) }
    private func experienceNeeded(for level: Int) -> Int { 90 + max(0, level - 1) * 35 }

    var activeCombatSkills: [(skill: CombatSkill, power: Double)] {
        CombatSkill.allCases.compactMap { skill in
            let power = combatSkillPower(skill)
            return power > 0 ? (skill, power) : nil
        }
    }

    // MARK: - Battle power

    var equippedEquipmentPower: Int { equippedDefinitions.reduce(0) { $0 + equipmentBattlePower($1) } }
    var equippedTechniquePower: Int {
        equippedTechniqueIDs.compactMap { SavingsCatalog.technique($0) }.reduce(0) { $0 + techniqueBattlePower($1) }
    }
    var equippedPetPower: Int { equippedPetPairs.reduce(0) { $0 + $1.0.battlePower(stars: $1.1) } }
    var baseCharacterPower: Int {
        baseAttack * BattleStatWeights.attack + baseDefense * BattleStatWeights.defense
            + baseVitality * BattleStatWeights.vitality + baseSpeed * BattleStatWeights.speed
            + basePhysicalResistance * BattleStatWeights.resistance + baseMagicResistance * BattleStatWeights.resistance
            + adventure.level * BattleStatWeights.levelPower
    }
    var heroBattlePower: Int { baseCharacterPower + equippedEquipmentPower + equippedTechniquePower + equippedPetPower }
    var monsterBattlePower: Int {
        max(1, currentMonsterMaxHP / BattleStatWeights.monsterHPPerPower + currentMonsterAttack * BattleStatWeights.monsterAttack
            + currentMonsterPhysicalResistance * BattleStatWeights.monsterResistance
            + currentMonsterMagicResistance * BattleStatWeights.monsterResistance)
    }

    func battlePowerModifiers(heroPower: Int, monsterPower: Int) -> (outgoing: Double, incoming: Double) {
        let ratio = min(20, max(0.05, Double(max(1, heroPower)) / Double(max(1, monsterPower))))
        return (
            outgoing: min(1.80, max(0.20, pow(ratio, 0.90))),
            incoming: min(4.00, max(0.55, pow(1 / ratio, 0.90)))
        )
    }

    var currentBattlePowerModifiers: (outgoing: Double, incoming: Double) {
        battlePowerModifiers(heroPower: heroBattlePower, monsterPower: monsterBattlePower)
    }

    func minimumIncomingDamage(heroPower: Int, monsterPower: Int, heroMaxHP: Int) -> Int {
        let ratio = Double(max(1, heroPower)) / Double(max(1, monsterPower))
        let pressureRatio = ratio < 1 ? min(0.12, (1 - ratio) * 0.10) : 0
        return max(1, Int(Double(max(1, heroMaxHP)) * pressureRatio))
    }

    func maximumHealingPerTick(heroMaxHP: Int) -> Int {
        max(0, Int(Double(max(1, heroMaxHP)) * 0.04))
    }

    // MARK: - Auto battle

    func performAutoBattleTick() {
        guard !loadFailed, !SavingsCatalog.monsters.isEmpty else { return }
        // 本 tick 内不会变化的 computed 属性先读入局部常量，避免同一 tick 反复重算。
        let monster = currentMonster
        let maxMonsterHP = currentMonsterMaxHP
        let stage = currentStage
        let fortune = equippedFortune
        let maxHeroHP = heroMaxHP
        let heroPower = heroBattlePower
        let monsterPower = monsterBattlePower
        let oldMonsterHP = min(maxMonsterHP, max(1, adventure.monsterHP))
        let attackNumber = (adventure.attackCount ?? 0) + 1
        adventure.attackCount = attackNumber

        let powerModifiers = battlePowerModifiers(heroPower: heroPower, monsterPower: monsterPower)
        let penetration = combatSkillPower(.armorPierce)
        let physicalResistance = Double(currentMonsterPhysicalResistance) * (1 - penetration)
        let magicResistance = Double(currentMonsterMagicResistance) * (1 - penetration)
        let physicalBase = equippedAttack + equippedPhysicalDamage
        let magicBase = equippedMagicDamage
        let physicalAfterResistance = Double(physicalBase) * 100 / (100 + max(0, physicalResistance))
        let magicBoost = 1 + combatSkillPower(.arcaneSurge)
        let magicAfterResistance = Double(magicBase) * magicBoost * 100 / (100 + max(0, magicResistance))
        let critical = Double.random(in: 0..<1) < equippedCritical
        let speedMultiplier = 1 + min(0.8, Double(equippedSpeed) / 220)
        var damage = (physicalAfterResistance + magicAfterResistance) * speedMultiplier + Double(equippedTrueDamage)
        damage *= 1 + combatSkillPower(.haste)
        if stage.isMultiple(of: 10) { damage *= 1 + techniqueBonus(.bossDamage) }
        if critical { damage *= equippedCriticalDamage }
        if attackNumber.isMultiple(of: 5) { damage *= 1 + combatSkillPower(.echoStrike) }
        if Double(oldMonsterHP) / Double(maxMonsterHP) <= 0.2 { damage *= 1 + combatSkillPower(.execution) }
        if monster.spriteIndex == 6 { damage *= 0.9 }
        if monster.spriteIndex == 9 && oldMonsterHP == maxMonsterHP { damage *= 0.8 }
        damage *= powerModifiers.outgoing
        let dealt = max(1, Int(damage.rounded()))
        adventure.monsterHP = oldMonsterHP - dealt
        lastPlayerDamage = dealt
        lastHitCritical = critical
        lastEnemyDamage = 0

        if adventure.monsterHP <= 0 {
            adventure.defeatedMonsters += 1
            let rewardMultiplier = 1 + combatSkillPower(.luckyFind) + min(0.5, Double(fortune) / 200)
            let earnedCoins = max(20, Int(Double(25 + min(2_000, stage) * 5) * rewardMultiplier))
            let earnedInsight = max(1, Int(Double(monster.rewardInsight + min(500, stage / 3)) * rewardMultiplier))
            let earnedXP = max(1, Int(Double(monster.rewardXP + min(2_000, stage * 3)) * (1 + techniqueBonus(.experience))))
            adventure.coins = coins + earnedCoins
            adventure.insight += earnedInsight
            adventure.experience += earnedXP
            _ = resolveLevelUps()
            var lootDetail = ""
            let dropChance = min(75, 30 + fortune)
            if Int.random(in: 1...100) <= dropChance {
                let rarity = rollRarity(minimumRarity: nil, fortune: fortune)
                if Int.random(in: 1...100) <= 35 {
                    if let definition = SavingsCatalog.randomTechnique(rarity: rarity) {
                        lootDetail = "；掉落“\(definition.name)”（\(grantTechniqueReward(definition))）"
                    }
                } else {
                    if let definition = SavingsCatalog.randomEquipment(rarity: rarity) {
                        lootDetail = "；掉落“\(definition.name)”（\(grantEquipmentReward(definition))）"
                    }
                }
            }
            let clearedStage = stage
            let clearedName = monster.name
            if adventure.monsterIndex < Int.max - 2 { adventure.monsterIndex += 1 }
            // 击杀后关卡与等级都可能变化：怪物血量与勇者生命需读取最新值。
            adventure.monsterHP = currentMonsterMaxHP
            adventure.heroHP = heroMaxHP
            adventure.battleAttempts = 0
            adventure.lastBattleMessage = "第 \(clearedStage) 关通过，正在挑战第 \(currentStage) 关"
            addEvent(title: "第 \(clearedStage) 关通过", detail: "击败\(clearedName)，获得 \(earnedXP) 经验、\(earnedCoins) 金币和 \(earnedInsight) 悟性\(lootDetail)。", symbol: "forward.fill")
            save()
            return
        }

        if monster.spriteIndex == 4 {
            adventure.monsterHP = min(maxMonsterHP, adventure.monsterHP + max(1, maxMonsterHP / 100))
        }
        var incoming = Double(currentMonsterAttack)
        if monster.spriteIndex == 7 {
            incoming *= 100 / (100 + Double(equippedMagicResistance))
        } else {
            incoming = max(1, incoming - Double(equippedDefense) * 0.18)
            incoming *= 100 / (100 + Double(equippedPhysicalResistance))
        }
        if monster.spriteIndex == 5 { incoming += Double(max(1, stage / 8)) }
        incoming *= 1 - equippedDamageReduction
        incoming *= powerModifiers.incoming
        let pressureDamage = minimumIncomingDamage(heroPower: heroPower, monsterPower: monsterPower, heroMaxHP: maxHeroHP)
        let received = max(pressureDamage, max(1, Int(incoming.rounded())))
        lastEnemyDamage = received
        let rawHealing = Int(Double(dealt) * equippedLifesteal) + Int(Double(maxHeroHP) * combatSkillPower(.regeneration))
        let healing = min(maximumHealingPerTick(heroMaxHP: maxHeroHP), rawHealing)
        let beforeHit = min(maxHeroHP, heroHP + healing)
        adventure.heroHP = beforeHit - received

        if (adventure.heroHP ?? 0) <= 0 {
            let attempts = (adventure.battleAttempts ?? 0) + 1
            adventure.battleAttempts = attempts
            adventure.monsterHP = maxMonsterHP
            adventure.heroHP = maxHeroHP
            adventure.lastBattleMessage = "第 \(stage) 关未通过，已在原关第 \(attempts) 次重开"
            if attempts == 1 || attempts.isMultiple(of: 10) {
                addEvent(title: "原关重开", detail: "第 \(stage) 关暂未通过；怪物和勇者已恢复，变强后会自动继续尝试。", symbol: "arrow.counterclockwise")
            }
        } else {
            adventure.lastBattleMessage = critical ? "暴击 \(dealt) 点，承受 \(received) 点伤害" : "自动攻击 \(dealt) 点，承受 \(received) 点伤害"
        }
        save()
    }

    @discardableResult
    private func resolveLevelUps() -> Bool {
        var leveledUp = false
        while adventure.experience >= experienceNeeded(for: adventure.level) {
            adventure.experience -= experienceNeeded(for: adventure.level)
            adventure.level += 1
            adventure.insight += 5
            leveledUp = true
        }
        return leveledUp
    }
}
