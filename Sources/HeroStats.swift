import Foundation

/// 装备/宠物对勇者属性的聚合贡献（强化倍率与星级缩放已在 store 侧应用后传入）。
/// 宠物没有抗性/百分比类字段，对应分量保持 0。
struct HeroStatContributions {
    var attack = 0
    var defense = 0
    var vitality = 0
    var speed = 0
    var fortune = 0
    var physicalDamage = 0
    var magicDamage = 0
    var trueDamage = 0
    var shield = 0
    var physicalResistance = 0
    var magicResistance = 0
    var critical = 0.0
    var criticalDamage = 0.0
    var lifesteal = 0.0
    var damageReduction = 0.0
}

/// 勇者战斗属性快照。字段与 SavingsStore 的 equipped*/heroMaxHP 一一对应。
struct HeroStats {
    var attack = 0
    var defense = 0
    var vitality = 0
    var speed = 0
    var fortune = 0
    var physicalDamage = 0
    var magicDamage = 0
    var trueDamage = 0
    var shield = 0
    var physicalResistance = 0
    var magicResistance = 0
    var critical = 0.0
    var criticalDamage = 0.0
    var lifesteal = 0.0
    var damageReduction = 0.0
    var maxHP = 0
}

/// 纯函数勇者属性计算器（V2.3 抽自 SavingsStore）：输入等级、装备/宠物聚合贡献、技能加成与
/// 磐壁战力，输出全部战斗属性。公式与原 store 计算属性逐行等价，数值不得漂移。
enum HeroStatsCalculator {
    static func stats(level: Int, equipment: HeroStatContributions, pets: HeroStatContributions,
                      techniqueBonuses: [TechniqueEffect: Double], fortificationPower: Double) -> HeroStats {
        let growth = max(0, level - 1)
        func bonus(_ effect: TechniqueEffect) -> Double { techniqueBonuses[effect] ?? 0 }
        var stats = HeroStats()
        stats.attack = 12 + growth * 3 + equipment.attack + pets.attack + Int(bonus(.attack)) + Int(bonus(.incomePower) * 100)
        stats.defense = 6 + growth * 2 + equipment.defense + pets.defense + Int(bonus(.defense)) + Int(bonus(.budgetPower) * 100)
        stats.vitality = 24 + growth * 4 + equipment.vitality + pets.vitality + Int(bonus(.vitality))
        stats.critical = min(0.65, 0.05 + Double(growth) * 0.001 + equipment.critical + bonus(.critical))
        stats.fortune = growth / 10 + equipment.fortune + pets.fortune + Int(bonus(.fortune))
        stats.physicalDamage = 4 + growth + equipment.physicalDamage + pets.physicalDamage + Int(bonus(.physicalDamage))
        stats.magicDamage = 2 + growth / 2 + equipment.magicDamage + pets.magicDamage + Int(bonus(.magicDamage))
        stats.trueDamage = growth / 12 + equipment.trueDamage + Int(bonus(.trueDamage)) + Int(bonus(.depositPower) * 100)
        stats.criticalDamage = 1.5 + Double(growth) * 0.002 + equipment.criticalDamage + bonus(.criticalDamage)
        stats.lifesteal = min(0.20, equipment.lifesteal + bonus(.lifesteal))
        stats.speed = 10 + growth / 3 + equipment.speed + pets.speed + Int(bonus(.speed)) + Int(bonus(.streakPower) * 100)
        stats.physicalResistance = 6 + growth / 3 + equipment.physicalResistance + Int(bonus(.physicalResistance))
        stats.magicResistance = 6 + growth / 3 + equipment.magicResistance + Int(bonus(.magicResistance))
        stats.damageReduction = min(0.50, min(0.05, Double(growth) * 0.0005) + equipment.damageReduction + bonus(.damageReduction))
        stats.shield = growth * 2 + equipment.shield + pets.shield + Int(bonus(.shield)) + Int(bonus(.expenseGuard) * 100)
        stats.maxHP = max(1, Int(Double(100 + stats.vitality * 5 + stats.shield * 2) * (1 + fortificationPower)))
        return stats
    }
}
