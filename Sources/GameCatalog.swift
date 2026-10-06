import Foundation

enum SavingsCatalog {
    static let ledgerCategories: [LedgerCategoryDefinition] = [
        .init(id: "food", name: "餐饮", kind: .expense, symbol: "fork.knife", colorKey: "orange"),
        .init(id: "groceries", name: "日用购物", kind: .expense, symbol: "cart.fill", colorKey: "teal"),
        .init(id: "housing", name: "住房", kind: .expense, symbol: "house.fill", colorKey: "blue"),
        .init(id: "transport", name: "交通", kind: .expense, symbol: "car.fill", colorKey: "purple"),
        .init(id: "utilities", name: "水电通讯", kind: .expense, symbol: "bolt.fill", colorKey: "orange"),
        .init(id: "health", name: "医疗健康", kind: .expense, symbol: "cross.case.fill", colorKey: "red"),
        .init(id: "education", name: "学习成长", kind: .expense, symbol: "graduationcap.fill", colorKey: "blue"),
        .init(id: "entertainment", name: "休闲娱乐", kind: .expense, symbol: "gamecontroller.fill", colorKey: "purple"),
        .init(id: "family", name: "家庭人情", kind: .expense, symbol: "person.2.fill", colorKey: "red"),
        .init(id: "subscription", name: "订阅服务", kind: .expense, symbol: "repeat.circle.fill", colorKey: "purple"),
        .init(id: "pet", name: "宠物", kind: .expense, symbol: "pawprint.fill", colorKey: "teal"),
        .init(id: "other-expense", name: "其他支出", kind: .expense, symbol: "ellipsis.circle.fill", colorKey: "blue"),
        .init(id: "salary-income", name: "工资", kind: .income, symbol: "briefcase.fill", colorKey: "blue"),
        .init(id: "bonus-income", name: "奖金", kind: .income, symbol: "star.fill", colorKey: "orange"),
        .init(id: "side-income", name: "副业", kind: .income, symbol: "hammer.fill", colorKey: "teal"),
        .init(id: "investment-income", name: "投资收益", kind: .income, symbol: "chart.line.uptrend.xyaxis", colorKey: "purple"),
        .init(id: "gift-income", name: "红包礼金", kind: .income, symbol: "gift.fill", colorKey: "red"),
        .init(id: "other-income", name: "其他收入", kind: .income, symbol: "plus.circle.fill", colorKey: "green"),
        .init(id: "account-transfer", name: "账户互转", kind: .transfer, symbol: "arrow.left.arrow.right.circle.fill", colorKey: "blue"),
        .init(id: "savings-goal-transfer", name: "积蓄计划转账", kind: .transfer, symbol: "target", colorKey: "teal")
    ]

    private static let legacyEquipment: [EquipmentDefinition] = [
        .init(id: "wood-sword", name: "存钱木剑", slot: .mainHand, rarity: .common, powerSeed: 1, attack: 4, defense: 0, vitality: 0, critical: 0, fortune: 0, symbol: "bolt.fill", setName: "启程", flavor: "第一笔积蓄削成的练习剑。"),
        .init(id: "coin-dagger", name: "零钱短刃", slot: .mainHand, rarity: .fine, powerSeed: 3, attack: 9, defense: 0, vitality: 0, critical: 0.02, fortune: 1, symbol: "bolt.fill", setName: "零钱", flavor: "把零散选择磨成锋芒。"),
        .init(id: "budget-blade", name: "预算长锋", slot: .mainHand, rarity: .rare, powerSeed: 7, attack: 18, defense: 2, vitality: 0, critical: 0.04, fortune: 1, symbol: "bolt.fill", setName: "守序", flavor: "每一格预算都是清晰的刃纹。"),
        .init(id: "compound-sabre", name: "复利星刀", slot: .mainHand, rarity: .epic, powerSeed: 12, attack: 30, defense: 2, vitality: 5, critical: 0.06, fortune: 3, symbol: "bolt.fill", setName: "星辉", flavor: "微小增长在刀背上汇成星河。"),
        .init(id: "future-edge", name: "未来之锋", slot: .mainHand, rarity: .legendary, powerSeed: 20, attack: 48, defense: 6, vitality: 10, critical: 0.09, fortune: 5, symbol: "bolt.fill", setName: "永恒", flavor: "为尚未抵达的明天而锻造。"),
        .init(id: "cloth-vest", name: "朴素布甲", slot: .chest, rarity: .common, powerSeed: 1, attack: 0, defense: 4, vitality: 8, critical: 0, fortune: 0, symbol: "tshirt.fill", setName: "启程", flavor: "不耀眼，但能挡住第一次冲动。"),
        .init(id: "budget-mail", name: "预算锁甲", slot: .chest, rarity: .fine, powerSeed: 4, attack: 1, defense: 10, vitality: 18, critical: 0, fortune: 0, symbol: "tshirt.fill", setName: "守序", flavor: "由一条条消费边界编成。"),
        .init(id: "emergency-armor", name: "应急壁垒", slot: .chest, rarity: .rare, powerSeed: 8, attack: 2, defense: 20, vitality: 36, critical: 0, fortune: 1, symbol: "shield.fill", setName: "安稳", flavor: "风雨来时，储备就是盔甲。"),
        .init(id: "discipline-armor", name: "自律重铠", slot: .chest, rarity: .epic, powerSeed: 13, attack: 4, defense: 33, vitality: 58, critical: 0, fortune: 2, symbol: "shield.fill", setName: "守序", flavor: "长期习惯凝成的坚实轮廓。"),
        .init(id: "future-armor", name: "远景圣铠", slot: .chest, rarity: .legendary, powerSeed: 21, attack: 8, defense: 50, vitality: 92, critical: 0.02, fortune: 4, symbol: "shield.fill", setName: "永恒", flavor: "替未来的自己守住今天。"),
        .init(id: "coin-charm", name: "零钱护符", slot: .relic, rarity: .common, powerSeed: 2, attack: 1, defense: 1, vitality: 3, critical: 0.01, fortune: 1, symbol: "sparkles", setName: "零钱", flavor: "提醒你别忽略一枚小钱的方向。"),
        .init(id: "habit-charm", name: "习惯刻印", slot: .relic, rarity: .fine, powerSeed: 5, attack: 3, defense: 3, vitality: 6, critical: 0.02, fortune: 2, symbol: "sparkles", setName: "守序", flavor: "重复的好选择留下温热刻痕。"),
        .init(id: "goal-charm", name: "目标罗盘", slot: .relic, rarity: .rare, powerSeed: 9, attack: 6, defense: 5, vitality: 10, critical: 0.03, fortune: 3, symbol: "scope", setName: "远行", flavor: "指针永远朝向最重要的目标。"),
        .init(id: "streak-charm", name: "连存星核", slot: .relic, rarity: .epic, powerSeed: 14, attack: 10, defense: 8, vitality: 18, critical: 0.05, fortune: 5, symbol: "sparkles", setName: "星辉", flavor: "连续的日子在其中亮成星团。"),
        .init(id: "freedom-charm", name: "自由秘宝", slot: .relic, rarity: .legendary, powerSeed: 22, attack: 16, defense: 13, vitality: 28, critical: 0.08, fortune: 8, symbol: "sun.max.fill", setName: "永恒", flavor: "财富不是终点，自主选择才是。")
    ]

    private static let materialThemes = ["青铜", "黑铁", "白银", "秘银", "晶骨", "太虚", "圣堂", "符文", "荒原", "星辉"]
    private static let epithets = ["守序", "远行", "破晓", "永恒"]

    private static var generatedEquipment: [EquipmentDefinition] {
        EquipmentSlot.allCases.flatMap { slot in
            (0..<40).map { index in
                let tier = min(4, index / 8)
                let rarity = ItemRarity(rawValue: tier + 1) ?? .common
                let material = materialThemes[(index + EquipmentSlot.allCases.firstIndex(of: slot)!) % materialThemes.count]
                let epithet = epithets[(index / 10) % epithets.count]
                let power = index + 2 + tier * 4
                let offensive = slot == .mainHand || slot == .hands || slot == .ringLeft || slot == .ringRight
                let defensive = [.offHand, .head, .shoulders, .chest, .waist, .legs, .feet].contains(slot)
                return EquipmentDefinition(
                    id: "v02-\(slot.rawValue)-\(String(format: "%02d", index + 1))",
                    name: "\(epithet)·\(material)\(slot.itemNoun)", slot: slot, rarity: rarity,
                    powerSeed: 1 + index / 2,
                    attack: offensive ? power + tier * 3 : max(0, power / 3),
                    defense: defensive ? power + tier * 4 : max(0, power / 4),
                    vitality: defensive ? power * 2 : power / 2,
                    critical: offensive ? Double(tier + 1) * 0.008 + Double(index % 4) * 0.003 : Double(tier) * 0.003,
                    fortune: slot == .relic || slot == .necklace || slot == .cloak ? tier + index % 3 : max(0, tier - 1),
                    symbol: slot.symbol, setName: "\(epithet)套装",
                    flavor: "\(material)工艺与\(epithet)铭文共同锻成，适合第 \(index + 1) 阶冒险。"
                )
            }
        }
    }

    private static let v05Materials = ["绯曜", "天衡", "苍穹", "万象", "虹光", "寰宇", "无极", "永昼", "七曜", "星海", "时轮", "彼岸"]

    private static var generatedV05Equipment: [EquipmentDefinition] {
        EquipmentSlot.allCases.flatMap { slot in
            (0..<12).map { index in
                let rarity: ItemRarity = index < 8 ? .mythic : .peerless
                let slotIndex = EquipmentSlot.allCases.firstIndex(of: slot) ?? 0
                let power = 78 + index * 7 + slotIndex * 2
                let offensive = [.mainHand, .hands, .ringLeft, .ringRight, .relic].contains(slot)
                let defensive = [.offHand, .head, .shoulders, .chest, .waist, .legs, .feet, .cloak].contains(slot)
                return EquipmentDefinition(
                    id: "v05-\(slot.rawValue)-\(String(format: "%02d", index + 1))",
                    name: "\(v05Materials[index])·\(slot.itemNoun)", slot: slot, rarity: rarity,
                    powerSeed: 32 + index * 3,
                    attack: offensive ? power : max(12, power / 3),
                    defense: defensive ? power + 18 : max(10, power / 4),
                    vitality: defensive ? power * 3 : power,
                    critical: offensive ? 0.10 + Double(index) * 0.006 : 0.025 + Double(index) * 0.002,
                    fortune: (rarity == .peerless ? 18 : 10) + index,
                    symbol: slot.symbol, setName: rarity == .peerless ? "绝世·万象套装" : "神话·绯曜套装",
                    flavor: "高阶锻造产物，拥有更多独特词条，并强化全部战斗维度。"
                )
            }
        }
    }

    static let equipment: [EquipmentDefinition] = legacyEquipment + generatedEquipment + generatedV05Equipment

    private static let legacyTechniques: [TechniqueDefinition] = [
        .init(id: "steady-heart", name: "定心诀", school: "内功", culture: "东方", symbol: "heart.fill", description: "在每一次取舍前停一拍，提高暴击概率。", effect: .critical, effectPerLevel: 0.02, rarity: .fine),
        .init(id: "rainy-day", name: "未雨心法", school: "守御", culture: "东方", symbol: "umbrella.fill", description: "先为未知留下余地，提高防御。", effect: .defense, effectPerLevel: 5, rarity: .fine),
        .init(id: "accumulate", name: "聚沙真经", school: "内功", culture: "华夏玄门", symbol: "circle.grid.cross.fill", description: "细小积累也能汇成稳定攻势。", effect: .depositPower, effectPerLevel: 0.06, rarity: .rare),
        .init(id: "small-steps", name: "寸进步法", school: "身法", culture: "东方", symbol: "figure.walk", description: "一步不必很大，只需保持前进。", effect: .experience, effectPerLevel: 0.05, rarity: .rare),
        .init(id: "long-view", name: "远望秘典", school: "星界", culture: "西方奇幻", symbol: "scope", description: "把目光越过眼前诱惑，强化首领伤害。", effect: .bossDamage, effectPerLevel: 0.08, rarity: .epic),
        .init(id: "consistent", name: "恒行术", school: "骑士", culture: "西方奇幻", symbol: "flame.fill", description: "守住日常节奏，提升星尘收益。", effect: .stardust, effectPerLevel: 0.05, rarity: .rare)
    ]

    private struct SchoolSeed {
        let name: String
        let culture: String
        let symbol: String
    }

    private static let schools: [SchoolSeed] = [
        .init(name: "炼体", culture: "东方武学", symbol: "figure.strengthtraining.traditional"),
        .init(name: "剑道", culture: "东方武学", symbol: "bolt.fill"),
        .init(name: "刀意", culture: "东方武学", symbol: "flame.fill"),
        .init(name: "枪诀", culture: "东方武学", symbol: "scope"),
        .init(name: "拳经", culture: "东方武学", symbol: "hand.raised.fill"),
        .init(name: "掌法", culture: "东方武学", symbol: "hand.wave.fill"),
        .init(name: "身法", culture: "东方武学", symbol: "figure.run"),
        .init(name: "内功", culture: "东方武学", symbol: "heart.fill"),
        .init(name: "道法", culture: "华夏玄门", symbol: "circle.hexagongrid.fill"),
        .init(name: "佛门", culture: "华夏玄门", symbol: "sun.max.fill"),
        .init(name: "符箓", culture: "华夏玄门", symbol: "scroll.fill"),
        .init(name: "阵法", culture: "华夏玄门", symbol: "circle.grid.cross.fill"),
        .init(name: "奥术", culture: "西方奇幻", symbol: "wand.and.stars"),
        .init(name: "元素", culture: "西方奇幻", symbol: "aqi.medium"),
        .init(name: "骑士", culture: "西方奇幻", symbol: "shield.fill"),
        .init(name: "德鲁伊", culture: "凯尔特灵感", symbol: "leaf.fill"),
        .init(name: "炼金", culture: "赫尔墨斯灵感", symbol: "flask.fill"),
        .init(name: "符文", culture: "北境神话灵感", symbol: "snowflake"),
        .init(name: "萨满", culture: "草原灵性灵感", symbol: "bird.fill"),
        .init(name: "星界", culture: "世界神话灵感", symbol: "sparkles")
    ]
    private static let roots = ["太初", "归元", "玄冥", "曜金", "青木", "沧海", "赤炎", "厚土", "风痕", "月影"]
    private static let forms = ["入门篇", "流转诀", "镇守式", "破阵章", "星辉卷", "无上典"]

    private static var generatedTechniques: [TechniqueDefinition] {
        var result: [TechniqueDefinition] = []
        for (schoolIndex, school) in schools.enumerated() {
            for (rootIndex, root) in roots.enumerated() {
                for (formIndex, form) in forms.enumerated() {
                    let effect = TechniqueEffect.allCases[(schoolIndex + rootIndex * 2 + formIndex) % TechniqueEffect.allCases.count]
                    let rarity = ItemRarity(rawValue: min(5, 1 + formIndex)) ?? .legendary
                    result.append(TechniqueDefinition(
                        id: "v02-tech-\(schoolIndex)-\(rootIndex)-\(formIndex)",
                        name: "\(root)\(school.name)·\(form)", school: school.name, culture: school.culture,
                        symbol: school.symbol,
                        description: "以\(root)为意象的\(school.name)分支；\(effect.baseDescription)。",
                        effect: effect, effectPerLevel: effectValue(effect, tier: formIndex + 1), rarity: rarity
                    ))
                }
            }
        }
        return result
    }

    private static let v05Forms = ["神话真篇", "绝世终章"]

    private static var generatedV05Techniques: [TechniqueDefinition] {
        var result: [TechniqueDefinition] = []
        for (schoolIndex, school) in schools.enumerated() {
            for (rootIndex, root) in roots.enumerated() {
                for formIndex in 0..<v05Forms.count {
                    let rarity: ItemRarity = formIndex == 0 ? .mythic : .peerless
                    let effect = TechniqueEffect.allCases[(schoolIndex * 3 + rootIndex + formIndex * 7) % TechniqueEffect.allCases.count]
                    result.append(TechniqueDefinition(
                        id: "v05-tech-\(schoolIndex)-\(rootIndex)-\(formIndex)",
                        name: "\(root)\(school.name)·\(v05Forms[formIndex])", school: school.name, culture: school.culture,
                        symbol: school.symbol,
                        description: "\(root)一脉的高阶\(school.name)传承；\(effect.baseDescription)，并附带独门绝技。",
                        effect: effect, effectPerLevel: effectValue(effect, tier: formIndex == 0 ? 9 : 12), rarity: rarity
                    ))
                }
            }
        }
        return result
    }

    static let techniques: [TechniqueDefinition] = legacyTechniques + generatedTechniques + generatedV05Techniques

    static let pets: [PetDefinition] = [
        .init(id: "fortune-cat", name: "招财橘猫", role: "物理输出", flavor: "把每一枚硬币都变成轻快爪击。", spriteIndex: 0,
              attack: 42, defense: 8, vitality: 18, speed: 18, fortune: 8, physicalDamage: 24, magicDamage: 0, shield: 0),
        .init(id: "guardian-dog", name: "守护金毛", role: "均衡守护", flavor: "忠诚守在存钱罐旁，攻守都很可靠。", spriteIndex: 1,
              attack: 24, defense: 30, vitality: 42, speed: 10, fortune: 5, physicalDamage: 10, magicDamage: 0, shield: 30),
        .init(id: "laurel-rabbit", name: "月桂白兔", role: "高速突击", flavor: "每次跳跃都比冲动消费更快一步。", spriteIndex: 2,
              attack: 30, defense: 8, vitality: 20, speed: 42, fortune: 6, physicalDamage: 16, magicDamage: 4, shield: 0),
        .init(id: "ledger-owl", name: "智账猫头鹰", role: "魔法输出", flavor: "能从账本数字里看见最稳妥的路线。", spriteIndex: 3,
              attack: 16, defense: 12, vitality: 24, speed: 14, fortune: 8, physicalDamage: 0, magicDamage: 38, shield: 8),
        .init(id: "steady-turtle", name: "稳健陆龟", role: "护盾防御", flavor: "慢一点没关系，稳稳守住每一笔积蓄。", spriteIndex: 4,
              attack: 10, defense: 42, vitality: 48, speed: 4, fortune: 3, physicalDamage: 4, magicDamage: 0, shield: 52),
        .init(id: "granary-hamster", name: "储粮仓鼠", role: "幸运寻宝", flavor: "擅长把零散收获藏进鼓鼓的口袋。", spriteIndex: 5,
              attack: 18, defense: 12, vitality: 24, speed: 20, fortune: 32, physicalDamage: 8, magicDamage: 6, shield: 6),
        .init(id: "sunset-fox", name: "赤霞灵狐", role: "暴烈输出", flavor: "赤霞般的尾焰化作锐利攻势。", spriteIndex: 6,
              attack: 46, defense: 8, vitality: 20, speed: 28, fortune: 6, physicalDamage: 28, magicDamage: 10, shield: 0),
        .init(id: "ripple-otter", name: "涟漪水獭", role: "魔法护盾", flavor: "抱着贝壳，让水光同时化为锋芒与屏障。", spriteIndex: 7,
              attack: 16, defense: 18, vitality: 30, speed: 18, fortune: 7, physicalDamage: 4, magicDamage: 28, shield: 34),
        .init(id: "bamboo-panda", name: "墨竹熊猫", role: "生命防御", flavor: "沉稳如竹林，越久越显可靠。", spriteIndex: 8,
              attack: 18, defense: 34, vitality: 58, speed: 7, fortune: 4, physicalDamage: 8, magicDamage: 0, shield: 32),
        .init(id: "snow-penguin", name: "星雪企鹅", role: "灵巧法术", flavor: "踏着星雪滑行，洒下清亮的魔法。", spriteIndex: 9,
              attack: 20, defense: 16, vitality: 28, speed: 34, fortune: 7, physicalDamage: 4, magicDamage: 30, shield: 10),
        .init(id: "spring-capybara", name: "暖泉水豚", role: "生命回复", flavor: "从容的气场让队伍始终保持安定。", spriteIndex: 10,
              attack: 12, defense: 28, vitality: 64, speed: 6, fortune: 5, physicalDamage: 2, magicDamage: 10, shield: 38),
        .init(id: "pine-squirrel", name: "松果灵鼠", role: "高速寻宝", flavor: "眼疾手快，从不会漏掉一枚闪亮收获。", spriteIndex: 11,
              attack: 28, defense: 10, vitality: 22, speed: 36, fortune: 24, physicalDamage: 18, magicDamage: 2, shield: 0)
    ]

    static let monsters: [MonsterDefinition] = [
        .init(id: "coin-slime", name: "存钱软泥", chapter: "零钱草地", maxHP: 100, rewardXP: 36, rewardTickets: 1, rewardInsight: 8, symbol: "drop.fill", spriteIndex: 0, trait: "均衡型"),
        .init(id: "impulse-moth", name: "冲动购物蛾", chapter: "橱窗小径", maxHP: 100, rewardXP: 40, rewardTickets: 1, rewardInsight: 9, symbol: "leaf.fill", spriteIndex: 1, trait: "攻击稍快"),
        .init(id: "budget-robot", name: "预算石机", chapter: "计划工坊", maxHP: 100, rewardXP: 44, rewardTickets: 1, rewardInsight: 10, symbol: "gearshape.fill", spriteIndex: 2, trait: "物理抗性"),
        .init(id: "receipt-ball", name: "账单纸团", chapter: "收据街角", maxHP: 100, rewardXP: 48, rewardTickets: 1, rewardInsight: 11, symbol: "doc.text.fill", spriteIndex: 3, trait: "魔法抗性"),
        .init(id: "snack-box", name: "零食纸箱怪", chapter: "随手消费站", maxHP: 100, rewardXP: 52, rewardTickets: 1, rewardInsight: 12, symbol: "shippingbox.fill", spriteIndex: 4, trait: "生命旺盛"),
        .init(id: "subscription-spider", name: "订阅蜘蛛", chapter: "续费角落", maxHP: 100, rewardXP: 56, rewardTickets: 1, rewardInsight: 13, symbol: "repeat.circle.fill", spriteIndex: 5, trait: "持续扣血"),
        .init(id: "price-caterpillar", name: "比价毛毛虫", chapter: "标签长廊", maxHP: 100, rewardXP: 60, rewardTickets: 1, rewardInsight: 14, symbol: "tag.fill", spriteIndex: 6, trait: "灵活闪避"),
        .init(id: "anxiety-puff", name: "焦虑眼团", chapter: "情绪广场", maxHP: 100, rewardXP: 64, rewardTickets: 1, rewardInsight: 15, symbol: "eye.fill", spriteIndex: 7, trait: "魔法攻击"),
        .init(id: "shopping-pile", name: "购物袋堆", chapter: "囤积仓库", maxHP: 100, rewardXP: 68, rewardTickets: 1, rewardInsight: 16, symbol: "bag.fill", spriteIndex: 8, trait: "高额护甲"),
        .init(id: "delay-snail", name: "拖延蜗牛", chapter: "明日钟庭", maxHP: 100, rewardXP: 72, rewardTickets: 2, rewardInsight: 18, symbol: "clock.fill", spriteIndex: 9, trait: "回合护盾")
    ]

    static func equipment(_ id: String?) -> EquipmentDefinition? {
        guard let id else { return nil }
        return equipment.first { $0.id == id }
    }

    static func technique(_ id: String?) -> TechniqueDefinition? {
        guard let id else { return nil }
        return techniques.first { $0.id == id }
    }

    static func pet(_ id: String?) -> PetDefinition? {
        guard let id else { return nil }
        return pets.first { $0.id == id }
    }

    static func ledgerCategory(_ id: String) -> LedgerCategoryDefinition? {
        ledgerCategories.first { $0.id == id }
    }

    private static func effectValue(_ effect: TechniqueEffect, tier: Int) -> Double {
        switch effect {
        case .attack, .defense, .physicalDamage, .magicDamage, .physicalResistance, .magicResistance: Double(2 + tier)
        case .vitality, .shield: Double(4 + tier * 2)
        case .trueDamage: Double(1 + tier / 2)
        case .speed: Double(1 + tier)
        case .critical: 0.004 + Double(tier) * 0.002
        case .criticalDamage: 0.008 + Double(tier) * 0.004
        case .lifesteal, .damageReduction: 0.002 + Double(tier) * 0.0015
        case .bossDamage, .experience, .stardust, .depositPower, .streakPower, .budgetPower, .incomePower, .expenseGuard: 0.01 + Double(tier) * 0.006
        case .fortune: Double(tier)
        }
    }
}
