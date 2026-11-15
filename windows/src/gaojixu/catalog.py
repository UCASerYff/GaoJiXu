"""与 Mac SavingsCatalog / GameProgression 相同的图鉴和成长公式。

装备、技能 ID 由同一套种子生成，打开 Mac 存档时名称和数值对得上。
"""

from __future__ import annotations

import math

SLOTS = [
    ("mainHand", "主手", "刃", "bolt.fill"),
    ("offHand", "副手", "盾", "shield.fill"),
    ("head", "头盔", "冠", "crown.fill"),
    ("shoulders", "肩甲", "肩铠", "person.crop.square.filled.and.at.rectangle"),
    ("chest", "胸甲", "战甲", "tshirt.fill"),
    ("hands", "手套", "护手", "hand.raised.fill"),
    ("waist", "腰带", "束带", "circle.dotted"),
    ("legs", "腿甲", "胫甲", "figure.walk"),
    ("feet", "战靴", "长靴", "shoeprints.fill"),
    ("necklace", "项链", "项坠", "seal.fill"),
    ("ringLeft", "左戒", "指环", "circle.circle.fill"),
    ("ringRight", "右戒", "指环", "circle.circle.fill"),
    ("cloak", "披风", "斗篷", "wind"),
    ("relic", "圣物", "秘宝", "sparkles"),
]
SLOT_INDEX = {item[0]: index for index, item in enumerate(SLOTS)}
OFFENSIVE_SLOTS = {"mainHand", "hands", "ringLeft", "ringRight"}
DEFENSIVE_SLOTS = {"offHand", "head", "shoulders", "chest", "waist", "legs", "feet"}
V05_OFFENSIVE = {"mainHand", "hands", "ringLeft", "ringRight", "relic"}
V05_DEFENSIVE = {"offHand", "head", "shoulders", "chest", "waist", "legs", "feet", "cloak"}

RARITY_TITLE = {1: "普通", 2: "精良", 3: "稀有", 4: "史诗", 5: "传说", 6: "神话", 7: "绝世"}
GUARANTEE = {3: 10, 4: 30, 5: 150, 6: 500, 7: 2000}
GUARANTEED_TIERS = [3, 4, 5, 6, 7]

COMBAT_SKILLS = ["echoStrike", "execution", "regeneration", "fortification", "armorPierce", "arcaneSurge", "haste", "luckyFind"]
SKILL_CAP = {
    "echoStrike": 0.40, "execution": 0.35, "regeneration": 0.03, "fortification": 0.35,
    "armorPierce": 0.30, "arcaneSurge": 0.35, "haste": 0.30, "luckyFind": 0.40,
}
SKILL_WEIGHT = {
    "echoStrike": 3000, "execution": 3500, "regeneration": 10000, "fortification": 5000,
    "armorPierce": 5500, "arcaneSurge": 4000, "haste": 7000, "luckyFind": 1500,
}

EFFECTS = [
    "attack", "defense", "vitality", "critical", "criticalDamage", "lifesteal", "speed",
    "physicalResistance", "magicResistance", "physicalDamage", "magicDamage", "trueDamage",
    "damageReduction", "shield", "bossDamage", "experience", "stardust",
    "depositPower", "streakPower", "budgetPower", "incomePower", "expenseGuard", "fortune",
]
EFFECT_TITLE = {
    "attack": "攻击强化", "defense": "防御强化", "vitality": "生命锻炼", "critical": "暴击修炼",
    "criticalDamage": "暴伤增幅", "lifesteal": "吸血转化", "speed": "速度精进",
    "physicalResistance": "物抗淬炼", "magicResistance": "魔抗淬炼", "physicalDamage": "物伤强化",
    "magicDamage": "魔伤强化", "trueDamage": "真伤领悟", "damageReduction": "减伤心法",
    "shield": "护盾凝聚", "bossDamage": "首领克制", "experience": "经验增幅", "stardust": "星尘增幅",
    "depositPower": "积蓄真意", "streakPower": "连战疾行", "budgetPower": "预算壁垒",
    "incomePower": "进取锋芒", "expenseGuard": "节制护盾", "fortune": "寻宝运势",
}

CURRENCIES = {
    "CNY": ("人民币", "¥"), "USD": ("美元", "$"), "EUR": ("欧元", "€"), "GBP": ("英镑", "£"),
    "JPY": ("日元", "¥"), "HKD": ("港币", "$"), "TWD": ("新台币", "$"), "KRW": ("韩元", "₩"),
    "SGD": ("新加坡元", "$"), "AUD": ("澳元", "$"), "CAD": ("加拿大元", "$"),
}
ACCOUNT_TYPES = {
    "cash": ("现金", "banknote.fill", False),
    "bank": ("银行卡", "building.columns.fill", False),
    "ewallet": ("电子钱包", "wallet.pass.fill", False),
    "credit": ("信用账户", "creditcard.fill", True),
    "investment": ("投资账户", "chart.line.uptrend.xyaxis", False),
    "other": ("其他账户", "tray.full.fill", False),
}
CATEGORIES = [
    ("food", "餐饮", "expense"), ("groceries", "日用购物", "expense"), ("housing", "住房", "expense"),
    ("transport", "交通", "expense"), ("utilities", "水电通讯", "expense"), ("health", "医疗健康", "expense"),
    ("education", "学习成长", "expense"), ("entertainment", "休闲娱乐", "expense"), ("family", "家庭人情", "expense"),
    ("subscription", "订阅服务", "expense"), ("pet", "宠物", "expense"), ("other-expense", "其他支出", "expense"),
    ("salary-income", "工资", "income"), ("bonus-income", "奖金", "income"), ("side-income", "副业", "income"),
    ("investment-income", "投资收益", "income"), ("gift-income", "红包礼金", "income"), ("other-income", "其他收入", "income"),
    ("account-transfer", "账户互转", "transfer"), ("savings-goal-transfer", "积蓄计划转账", "transfer"),
]
CATEGORY_BY_ID = {item[0]: item for item in CATEGORIES}
CATEGORY_BY_NAME = {item[1]: item for item in CATEGORIES}
SAVINGS_CATEGORIES = {
    "salary": "工资结余", "savedExpense": "少花一笔", "extraIncome": "额外收入",
    "scheduled": "固定储蓄", "gift": "红包礼金", "other": "其他",
}
FIXED_INCOME_CATEGORIES = {
    "other-income", "salary-income", "bonus-income", "side-income", "investment-income", "gift-income",
}
GOAL_STATUSES = {"active", "paused", "completed", "archived"}
MAX_EQUIPMENT = 99
MAX_TECHNIQUE = 99
MAX_PET_STARS = 99
MAX_PETS = 4
MAX_TECHNIQUES = 12
PET_EGG_COST = 10_000
TICKET_EXCHANGE_COST = 500
REWARD_CAP = 300
DRAW_CAP = 200

W_ATTACK, W_DEFENSE, W_VITALITY, W_SPEED = 18, 12, 5, 6
W_RESIST, W_PHYS, W_MAGIC, W_TRUE = 6, 14, 14, 24
W_FORTUNE, W_SHIELD = 5, 2.5
W_CRIT, W_CRIT_DMG, W_LEECH, W_REDUCE = 9000.0, 2500.0, 6500.0, 9000.0
W_MONSTER_HP, W_MONSTER_ATTACK, W_MONSTER_RESIST, W_LEVEL = 2, 28, 8, 60


def stable_seed(text: str, start: int, multiplier: int) -> int:
    value = start
    for byte in text.encode("utf-8"):
        value = ((value * multiplier) + byte) & 0x7FFFFFFF
    return value


def swift_round(value: float) -> int:
    if value >= 0:
        return int(math.floor(value + 0.5))
    return int(math.ceil(value - 0.5))


def trunc(value: float) -> int:
    return int(value)


def equipment_multiplier(level: int) -> float:
    safe = float(min(MAX_EQUIPMENT, max(0, level)))
    return 1 + safe * 0.05 + safe * safe * 0.005


def technique_scale(level: int) -> float:
    safe = float(min(MAX_TECHNIQUE, max(1, level)))
    late = max(0.0, safe - 10)
    return safe + late * late * 0.025


def equipment_upgrade_cost(rarity: int, next_level: int) -> int:
    level = min(MAX_EQUIPMENT, max(1, next_level))
    return rarity * (level * 60 + level * level * 10)


def technique_upgrade_cost(rarity: int, current_level: int) -> int:
    level = min(MAX_TECHNIQUE - 1, max(1, current_level))
    late = max(0, level - 9)
    return rarity * (level * 20 + late * late * 3)


def pet_multiplier(stars: int) -> float:
    extra = float(min(MAX_PET_STARS, max(1, stars)) - 1)
    return 1 + extra * 0.15 + extra * extra * 0.003


def effect_value(effect: str, tier: int) -> float:
    if effect in {"attack", "defense", "physicalDamage", "magicDamage", "physicalResistance", "magicResistance"}:
        return float(2 + tier)
    if effect in {"vitality", "shield"}:
        return float(4 + tier * 2)
    if effect == "trueDamage":
        return float(1 + tier // 2)
    if effect == "speed":
        return float(1 + tier)
    if effect == "critical":
        return 0.004 + tier * 0.002
    if effect == "criticalDamage":
        return 0.008 + tier * 0.004
    if effect in {"lifesteal", "damageReduction"}:
        return 0.002 + tier * 0.0015
    if effect in {"bossDamage", "experience", "stardust", "depositPower", "streakPower", "budgetPower", "incomePower", "expenseGuard"}:
        return 0.01 + tier * 0.006
    return float(tier)


class Equipment:
    def __init__(self, id, name, slot, rarity, power_seed, attack, defense, vitality, critical, fortune, symbol, set_name, flavor):
        self.id = id
        self.name = name
        self.slot = slot
        self.rarity = rarity
        self.power_seed = power_seed
        self.attack = attack
        self.defense = defense
        self.vitality = vitality
        self.critical = critical
        self.fortune = fortune
        self.symbol = symbol
        self.set_name = set_name
        self.flavor = flavor
        self.seed = stable_seed(id, 17, 31)

    @property
    def physical_damage(self) -> int:
        favored = self.slot in {"mainHand", "hands", "ringLeft"}
        base = self.attack if favored else self.attack // 3
        return max(0, base + self.power_seed // 3 + self.seed % 4)

    @property
    def magic_damage(self) -> int:
        favored = self.slot in {"relic", "necklace", "ringRight"}
        base = self.attack if favored else self.attack // 4
        return max(0, base + self.rarity * 2 + self.seed % 5)

    @property
    def true_damage(self) -> int:
        if self.rarity < 3:
            return 0
        return max(0, self.power_seed // 5 + self.seed % self.rarity)

    @property
    def critical_damage(self) -> float:
        return self.rarity * 0.025 + (self.seed % 6) * 0.005

    @property
    def lifesteal(self) -> float:
        if self.slot in {"mainHand", "necklace", "relic"}:
            return (self.rarity + self.seed % 3) * 0.004
        return 0.0

    @property
    def speed(self) -> int:
        base = self.rarity * 3 if self.slot in {"feet", "cloak", "hands"} else self.rarity
        return base + self.seed % 4

    @property
    def physical_resistance(self) -> int:
        favored = self.slot in {"offHand", "head", "shoulders", "chest", "legs"}
        base = self.defense // 2 if favored else self.defense // 5
        return max(0, base + self.rarity + self.seed % 4)

    @property
    def magic_resistance(self) -> int:
        favored = self.slot in {"cloak", "necklace", "relic"}
        base = self.defense // 2 if favored else self.defense // 6
        return max(0, base + self.rarity * 2 + self.seed % 4)

    @property
    def damage_reduction(self) -> float:
        if self.slot in {"offHand", "chest", "shoulders"}:
            return (self.rarity + self.seed % 3) * 0.004
        return self.rarity * 0.001

    @property
    def shield(self) -> int:
        if self.slot in {"offHand", "chest", "relic"}:
            base = self.vitality // 2 + self.defense
        else:
            base = self.vitality // 8
        return max(0, base + self.rarity * 2)

    @property
    def affixes(self):
        count = {1: 0, 5: 2, 6: 3, 7: 4}.get(self.rarity, 1)
        rows = []
        for offset in range(count):
            skill = COMBAT_SKILLS[(self.seed + offset * 3) % len(COMBAT_SKILLS)]
            power = (self.rarity * 2 + 1 + (self.seed // (offset + 1)) % 4) / 400
            rows.append((skill, power))
        return rows

    @property
    def base_power(self) -> int:
        flat = (
            self.attack * W_ATTACK + self.defense * W_DEFENSE + self.vitality * W_VITALITY
            + self.physical_damage * W_PHYS + self.magic_damage * W_MAGIC + self.true_damage * W_TRUE
            + self.speed * W_SPEED + self.physical_resistance * W_RESIST + self.magic_resistance * W_RESIST
            + int(self.shield * W_SHIELD) + self.fortune * W_FORTUNE
        )
        percent = (
            int(self.critical * W_CRIT) + int(self.critical_damage * W_CRIT_DMG)
            + int(self.lifesteal * W_LEECH) + int(self.damage_reduction * W_REDUCE)
        )
        affix = sum(int(power * SKILL_WEIGHT[skill]) for skill, power in self.affixes)
        return max(1, flat + percent + affix)


class Technique:
    def __init__(self, id, name, school, culture, symbol, description, effect, per_level, rarity):
        self.id = id
        self.name = name
        self.school = school
        self.culture = culture
        self.symbol = symbol
        self.description = description
        self.effect = effect
        self.per_level = per_level
        self.rarity = rarity
        self.seed = stable_seed(id, 23, 37)

    @property
    def signature_skill(self) -> str:
        return COMBAT_SKILLS[self.seed % len(COMBAT_SKILLS)]

    @property
    def signature_power(self) -> float:
        return (self.rarity + 1 + self.seed % 3) / 1000


class Pet:
    def __init__(self, id, name, role, flavor, sprite, attack, defense, vitality, speed, fortune, physical, magic, shield):
        self.id = id
        self.name = name
        self.role = role
        self.flavor = flavor
        self.sprite = sprite
        self.attack = attack
        self.defense = defense
        self.vitality = vitality
        self.speed = speed
        self.fortune = fortune
        self.physical = physical
        self.magic = magic
        self.shield = shield

    @property
    def base_power(self) -> int:
        return max(1, self.attack * W_ATTACK + self.defense * W_DEFENSE + self.vitality * W_VITALITY
                   + self.speed * W_SPEED + self.fortune * W_FORTUNE + self.physical * W_PHYS
                   + self.magic * W_MAGIC + int(self.shield * W_SHIELD))

    def power(self, stars: int) -> int:
        return max(1, swift_round(self.base_power * pet_multiplier(stars)))


class Monster:
    def __init__(self, id, name, chapter, max_hp, xp, tickets, insight, symbol, sprite, trait):
        self.id = id
        self.name = name
        self.chapter = chapter
        self.max_hp = max_hp
        self.xp = xp
        self.tickets = tickets
        self.insight = insight
        self.symbol = symbol
        self.sprite = sprite
        self.trait = trait


def _legacy_equipment():
    rows = [
        ("wood-sword", "存钱木剑", "mainHand", 1, 1, 4, 0, 0, 0, 0, "bolt.fill", "启程", "第一笔积蓄削成的练习剑。"),
        ("coin-dagger", "零钱短刃", "mainHand", 2, 3, 9, 0, 0, 0.02, 1, "bolt.fill", "零钱", "把零散选择磨成锋芒。"),
        ("budget-blade", "预算长锋", "mainHand", 3, 7, 18, 2, 0, 0.04, 1, "bolt.fill", "守序", "每一格预算都是清晰的刃纹。"),
        ("compound-sabre", "复利星刀", "mainHand", 4, 12, 30, 2, 5, 0.06, 3, "bolt.fill", "星辉", "微小增长在刀背上汇成星河。"),
        ("future-edge", "未来之锋", "mainHand", 5, 20, 48, 6, 10, 0.09, 5, "bolt.fill", "永恒", "为尚未抵达的明天而锻造。"),
        ("cloth-vest", "朴素布甲", "chest", 1, 1, 0, 4, 8, 0, 0, "tshirt.fill", "启程", "不耀眼，但能挡住第一次冲动。"),
        ("budget-mail", "预算锁甲", "chest", 2, 4, 1, 10, 18, 0, 0, "tshirt.fill", "守序", "由一条条消费边界编成。"),
        ("emergency-armor", "应急壁垒", "chest", 3, 8, 2, 20, 36, 0, 1, "shield.fill", "安稳", "风雨来时，储备就是盔甲。"),
        ("discipline-armor", "自律重铠", "chest", 4, 13, 4, 33, 58, 0, 2, "shield.fill", "守序", "长期习惯凝成的坚实轮廓。"),
        ("future-armor", "远景圣铠", "chest", 5, 21, 8, 50, 92, 0.02, 4, "shield.fill", "永恒", "替未来的自己守住今天。"),
        ("coin-charm", "零钱护符", "relic", 1, 2, 1, 1, 3, 0.01, 1, "sparkles", "零钱", "提醒你别忽略一枚小钱的方向。"),
        ("habit-charm", "习惯刻印", "relic", 2, 5, 3, 3, 6, 0.02, 2, "sparkles", "守序", "重复的好选择留下温热刻痕。"),
        ("goal-charm", "目标罗盘", "relic", 3, 9, 6, 5, 10, 0.03, 3, "scope", "远行", "指针永远朝向最重要的目标。"),
        ("streak-charm", "连存星核", "relic", 4, 14, 10, 8, 18, 0.05, 5, "sparkles", "星辉", "连续的日子在其中亮成星团。"),
        ("freedom-charm", "自由秘宝", "relic", 5, 22, 16, 13, 28, 0.08, 8, "sun.max.fill", "永恒", "财富不是终点，自主选择才是。"),
    ]
    return [Equipment(*row) for row in rows]


def _generated_equipment():
    materials = ["青铜", "黑铁", "白银", "秘银", "晶骨", "太虚", "圣堂", "符文", "荒原", "星辉"]
    epithets = ["守序", "远行", "破晓", "永恒"]
    result = []
    for slot, _title, noun, symbol in SLOTS:
        slot_index = SLOT_INDEX[slot]
        for index in range(40):
            tier = min(4, index // 8)
            rarity = tier + 1
            material = materials[(index + slot_index) % len(materials)]
            epithet = epithets[(index // 10) % len(epithets)]
            power = index + 2 + tier * 4
            offensive = slot in OFFENSIVE_SLOTS
            defensive = slot in DEFENSIVE_SLOTS
            result.append(Equipment(
                f"v02-{slot}-{index + 1:02d}",
                f"{epithet}·{material}{noun}",
                slot, rarity, 1 + index // 2,
                power + tier * 3 if offensive else max(0, power // 3),
                power + tier * 4 if defensive else max(0, power // 4),
                power * 2 if defensive else power // 2,
                (tier + 1) * 0.008 + (index % 4) * 0.003 if offensive else tier * 0.003,
                tier + index % 3 if slot in {"relic", "necklace", "cloak"} else max(0, tier - 1),
                symbol, f"{epithet}套装",
                f"{material}工艺与{epithet}铭文共同锻成，适合第 {index + 1} 阶冒险。",
            ))
    return result


def _v05_equipment():
    materials = ["绯曜", "天衡", "苍穹", "万象", "虹光", "寰宇", "无极", "永昼", "七曜", "星海", "时轮", "彼岸"]
    result = []
    for slot, _title, noun, symbol in SLOTS:
        slot_index = SLOT_INDEX[slot]
        for index in range(12):
            rarity = 6 if index < 8 else 7
            power = 78 + index * 7 + slot_index * 2
            offensive = slot in V05_OFFENSIVE
            defensive = slot in V05_DEFENSIVE
            result.append(Equipment(
                f"v05-{slot}-{index + 1:02d}",
                f"{materials[index]}·{noun}",
                slot, rarity, 32 + index * 3,
                power if offensive else max(12, power // 3),
                power + 18 if defensive else max(10, power // 4),
                power * 3 if defensive else power,
                0.10 + index * 0.006 if offensive else 0.025 + index * 0.002,
                (18 if rarity == 7 else 10) + index,
                symbol,
                "绝世·万象套装" if rarity == 7 else "神话·绯曜套装",
                "高阶锻造产物，拥有更多独特词条，并强化全部战斗维度。",
            ))
    return result


def _legacy_techniques():
    rows = [
        ("steady-heart", "定心诀", "内功", "东方", "heart.fill", "在每一次取舍前停一拍，提高暴击概率。", "critical", 0.02, 2),
        ("rainy-day", "未雨心法", "守御", "东方", "umbrella.fill", "先为未知留下余地，提高防御。", "defense", 5, 2),
        ("accumulate", "聚沙真经", "内功", "华夏玄门", "circle.grid.cross.fill", "细小积累也能汇成稳定攻势。", "depositPower", 0.06, 3),
        ("small-steps", "寸进步法", "身法", "东方", "figure.walk", "一步不必很大，只需保持前进。", "experience", 0.05, 3),
        ("long-view", "远望秘典", "星界", "西方奇幻", "scope", "把目光越过眼前诱惑，强化首领伤害。", "bossDamage", 0.08, 4),
        ("consistent", "恒行术", "骑士", "西方奇幻", "flame.fill", "守住日常节奏，提升星尘收益。", "stardust", 0.05, 3),
    ]
    return [Technique(*row) for row in rows]


def _generated_techniques():
    schools = [
        ("炼体", "东方武学", "figure.strengthtraining.traditional"), ("剑道", "东方武学", "bolt.fill"),
        ("刀意", "东方武学", "flame.fill"), ("枪诀", "东方武学", "scope"), ("拳经", "东方武学", "hand.raised.fill"),
        ("掌法", "东方武学", "hand.wave.fill"), ("身法", "东方武学", "figure.run"), ("内功", "东方武学", "heart.fill"),
        ("道法", "华夏玄门", "circle.hexagongrid.fill"), ("佛门", "华夏玄门", "sun.max.fill"),
        ("符箓", "华夏玄门", "scroll.fill"), ("阵法", "华夏玄门", "circle.grid.cross.fill"),
        ("奥术", "西方奇幻", "wand.and.stars"), ("元素", "西方奇幻", "aqi.medium"),
        ("骑士", "西方奇幻", "shield.fill"), ("德鲁伊", "凯尔特灵感", "leaf.fill"),
        ("炼金", "赫尔墨斯灵感", "flask.fill"), ("符文", "北境神话灵感", "snowflake"),
        ("萨满", "草原灵性灵感", "bird.fill"), ("星界", "世界神话灵感", "sparkles"),
    ]
    roots = ["太初", "归元", "玄冥", "曜金", "青木", "沧海", "赤炎", "厚土", "风痕", "月影"]
    forms = ["入门篇", "流转诀", "镇守式", "破阵章", "星辉卷", "无上典"]
    result = []
    for school_index, (school, culture, symbol) in enumerate(schools):
        for root_index, root in enumerate(roots):
            for form_index, form in enumerate(forms):
                effect = EFFECTS[(school_index + root_index * 2 + form_index) % len(EFFECTS)]
                rarity = min(5, 1 + form_index)
                result.append(Technique(
                    f"v02-tech-{school_index}-{root_index}-{form_index}",
                    f"{root}{school}·{form}", school, culture, symbol,
                    f"以{root}为意象的{school}分支；{EFFECT_TITLE[effect]}。",
                    effect, effect_value(effect, form_index + 1), rarity,
                ))
    return result


def _v05_techniques():
    schools = [
        ("炼体", "东方武学", "figure.strengthtraining.traditional"), ("剑道", "东方武学", "bolt.fill"),
        ("刀意", "东方武学", "flame.fill"), ("枪诀", "东方武学", "scope"), ("拳经", "东方武学", "hand.raised.fill"),
        ("掌法", "东方武学", "hand.wave.fill"), ("身法", "东方武学", "figure.run"), ("内功", "东方武学", "heart.fill"),
        ("道法", "华夏玄门", "circle.hexagongrid.fill"), ("佛门", "华夏玄门", "sun.max.fill"),
        ("符箓", "华夏玄门", "scroll.fill"), ("阵法", "华夏玄门", "circle.grid.cross.fill"),
        ("奥术", "西方奇幻", "wand.and.stars"), ("元素", "西方奇幻", "aqi.medium"),
        ("骑士", "西方奇幻", "shield.fill"), ("德鲁伊", "凯尔特灵感", "leaf.fill"),
        ("炼金", "赫尔墨斯灵感", "flask.fill"), ("符文", "北境神话灵感", "snowflake"),
        ("萨满", "草原灵性灵感", "bird.fill"), ("星界", "世界神话灵感", "sparkles"),
    ]
    roots = ["太初", "归元", "玄冥", "曜金", "青木", "沧海", "赤炎", "厚土", "风痕", "月影"]
    forms = ["神话真篇", "绝世终章"]
    result = []
    for school_index, (school, culture, symbol) in enumerate(schools):
        for root_index, root in enumerate(roots):
            for form_index, form in enumerate(forms):
                rarity = 6 if form_index == 0 else 7
                effect = EFFECTS[(school_index * 3 + root_index + form_index * 7) % len(EFFECTS)]
                result.append(Technique(
                    f"v05-tech-{school_index}-{root_index}-{form_index}",
                    f"{root}{school}·{forms[form_index]}", school, culture, symbol,
                    f"{root}一脉的高阶{school}传承；{EFFECT_TITLE[effect]}，并附带独门绝技。",
                    effect, effect_value(effect, 9 if form_index == 0 else 12), rarity,
                ))
    return result


def _pets():
    rows = [
        ("fortune-cat", "招财橘猫", "物理输出", "把每一枚硬币都变成轻快爪击。", 0, 42, 8, 18, 18, 8, 24, 0, 0),
        ("guardian-dog", "守护金毛", "均衡守护", "忠诚守在存钱罐旁，攻守都很可靠。", 1, 24, 30, 42, 10, 5, 10, 0, 30),
        ("laurel-rabbit", "月桂白兔", "高速突击", "每次跳跃都比冲动消费更快一步。", 2, 30, 8, 20, 42, 6, 16, 4, 0),
        ("ledger-owl", "智账猫头鹰", "魔法输出", "能从账本数字里看见最稳妥的路线。", 3, 16, 12, 24, 14, 8, 0, 38, 8),
        ("steady-turtle", "稳健陆龟", "护盾防御", "慢一点没关系，稳稳守住每一笔积蓄。", 4, 10, 42, 48, 4, 3, 4, 0, 52),
        ("granary-hamster", "储粮仓鼠", "幸运寻宝", "擅长把零散收获藏进鼓鼓的口袋。", 5, 18, 12, 24, 20, 32, 8, 6, 6),
        ("sunset-fox", "赤霞灵狐", "暴烈输出", "赤霞般的尾焰化作锐利攻势。", 6, 46, 8, 20, 28, 6, 28, 10, 0),
        ("ripple-otter", "涟漪水獭", "魔法护盾", "抱着贝壳，让水光同时化为锋芒与屏障。", 7, 16, 18, 30, 18, 7, 4, 28, 34),
        ("bamboo-panda", "墨竹熊猫", "生命防御", "沉稳如竹林，越久越显可靠。", 8, 18, 34, 58, 7, 4, 8, 0, 32),
        ("snow-penguin", "星雪企鹅", "灵巧法术", "踏着星雪滑行，洒下清亮的魔法。", 9, 20, 16, 28, 34, 7, 4, 30, 10),
        ("spring-capybara", "暖泉水豚", "生命回复", "从容的气场让队伍始终保持安定。", 10, 12, 28, 64, 6, 5, 2, 10, 38),
        ("pine-squirrel", "松果灵鼠", "高速寻宝", "眼疾手快，从不会漏掉一枚闪亮收获。", 11, 28, 10, 22, 36, 24, 18, 2, 0),
    ]
    return [Pet(*row) for row in rows]


def _monsters():
    rows = [
        ("coin-slime", "存钱软泥", "零钱草地", 100, 36, 1, 8, "drop.fill", 0, "均衡型"),
        ("impulse-moth", "冲动购物蛾", "橱窗小径", 100, 40, 1, 9, "leaf.fill", 1, "攻击稍快"),
        ("budget-robot", "预算石机", "计划工坊", 100, 44, 1, 10, "gearshape.fill", 2, "物理抗性"),
        ("receipt-ball", "账单纸团", "收据街角", 100, 48, 1, 11, "doc.text.fill", 3, "魔法抗性"),
        ("snack-box", "零食纸箱怪", "随手消费站", 100, 52, 1, 12, "shippingbox.fill", 4, "生命旺盛"),
        ("subscription-spider", "订阅蜘蛛", "续费角落", 100, 56, 1, 13, "repeat.circle.fill", 5, "持续扣血"),
        ("price-caterpillar", "比价毛毛虫", "标签长廊", 100, 60, 1, 14, "tag.fill", 6, "灵活闪避"),
        ("anxiety-puff", "焦虑眼团", "情绪广场", 100, 64, 1, 15, "eye.fill", 7, "魔法攻击"),
        ("shopping-pile", "购物袋堆", "囤积仓库", 100, 68, 1, 16, "bag.fill", 8, "高额护甲"),
        ("delay-snail", "拖延蜗牛", "明日钟庭", 100, 72, 2, 18, "clock.fill", 9, "回合护盾"),
    ]
    return [Monster(*row) for row in rows]


EQUIPMENT = _legacy_equipment() + _generated_equipment() + _v05_equipment()
TECHNIQUES = _legacy_techniques() + _generated_techniques() + _v05_techniques()
PETS = _pets()
MONSTERS = _monsters()
EQUIPMENT_BY_ID = {item.id: item for item in EQUIPMENT}
TECHNIQUE_BY_ID = {item.id: item for item in TECHNIQUES}
PET_BY_ID = {item.id: item for item in PETS}
MONSTER_BY_ID = {item.id: item for item in MONSTERS}


def category_name(category_id: str) -> str:
    if category_id == "balance-adjustment":
        return "余额调整"
    found = CATEGORY_BY_ID.get(category_id)
    return found[1] if found else category_id


def categories_for(kind: str):
    return [item for item in CATEGORIES if item[2] == kind]


def slot_title(slot: str) -> str:
    for key, title, _noun, _symbol in SLOTS:
        if key == slot:
            return title
    return slot
