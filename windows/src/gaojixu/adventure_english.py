"""English display text for the Mac-compatible adventure vocabulary.

The catalogue and stored event strings remain in their original format.
"""

from functools import lru_cache
import re

from gaojixu import catalog


RARITIES = ("", "Common", "Fine", "Rare", "Epic", "Legendary", "Mythic", "Peerless")
SLOTS = ("Main Hand", "Off Hand", "Helm", "Shoulders", "Chest", "Hands", "Waist", "Legs",
         "Feet", "Necklace", "Left Ring", "Right Ring", "Cloak", "Relic")
SLOT_NOUNS = ("Blade", "Shield", "Crown", "Shoulderguards", "Armor", "Gauntlets", "Belt", "Greaves",
              "Boots", "Pendant", "Ring", "Ring", "Cloak", "Relic")
SLOT_NAMES = dict(zip((row[0] for row in catalog.SLOTS), SLOTS))
EFFECTS = dict(zip(catalog.EFFECTS, (
    "Attack", "Defense", "Vitality", "Critical Chance", "Critical Damage", "Life Steal", "Speed",
    "Physical Resistance", "Magic Resistance", "Physical Damage", "Magic Damage", "True Damage",
    "Damage Reduction", "Shield", "Boss Damage", "Experience", "Stardust",
    "Saving Power", "Streak Speed", "Budget Defense", "Income Attack", "Spending Shield", "Fortune",
)))
SCHOOLS = dict(zip(
    ("炼体", "剑道", "刀意", "枪诀", "拳经", "掌法", "身法", "内功", "道法", "佛门", "符箓", "阵法",
     "奥术", "元素", "骑士", "德鲁伊", "炼金", "符文", "萨满", "星界", "守御"),
    ("Body Training", "Sword Arts", "Saber Arts", "Spear Arts", "Fist Arts", "Palm Arts", "Footwork",
     "Inner Arts", "Dao Arts", "Buddhist Arts", "Talismans", "Formations", "Arcane", "Elemental",
     "Knightly Arts", "Druidry", "Alchemy", "Runes", "Shamanism", "Astral Arts", "Guard Arts"),
))
TRADITIONS = {
    "东方": "Eastern Tradition", "东方武学": "Eastern Martial Arts", "华夏玄门": "Chinese Esoteric Tradition",
    "西方奇幻": "Western Fantasy", "凯尔特灵感": "Celtic-inspired", "赫尔墨斯灵感": "Hermetic-inspired",
    "北境神话灵感": "Norse-inspired", "草原灵性灵感": "Steppe Traditions", "世界神话灵感": "World Mythology",
}
ROOTS = ("Primordial", "Returning", "Deep Night", "Gilded", "Verdant", "Tidal", "Crimson Flame",
         "Earthbound", "Windtrace", "Moonshadow")
FORMS = ("Primer", "Flow", "Guard", "Formation Breaker", "Starlight Volume", "Supreme Canon")
ADVANCED_FORMS = ("Mythic Volume", "Peerless Finale")
MATERIALS = ("Bronze", "Black Iron", "Silver", "Mithril", "Crystal Bone", "Void", "Sanctum", "Runic",
             "Wasteland", "Starlight")
ADVANCED_MATERIALS = ("Crimson", "Celestial Balance", "Skyvault", "Myriad", "Iridescent", "Cosmic",
                      "Boundless", "Eternal Day", "Seven Luminaries", "Star Sea", "Wheel of Time", "Far Shore")
EPITHETS = ("Order", "Voyage", "Dawn", "Eternity")
SET_NAMES = {
    "启程": "Departure", "零钱": "Pocket Change", "守序": "Order", "星辉": "Starlight", "永恒": "Eternity",
    "安稳": "Steadfast", "远行": "Voyage", "破晓": "Dawn",
}
LEGACY_GEAR = {
    "wood-sword": ("Savings Wooden Sword", "A practice sword carved from the first deposit."),
    "coin-dagger": ("Pocket Change Dagger", "Small choices honed into a cutting edge."),
    "budget-blade": ("Budget Longblade", "The blade carries a clear mark for every budget category."),
    "compound-sabre": ("Compound Interest Saber", "Tiny gains gather like stars along the spine."),
    "future-edge": ("Edge of Tomorrow", "Forged for the days still ahead."),
    "cloth-vest": ("Plain Cloth Armor", "Simple armor that can withstand the first impulse."),
    "budget-mail": ("Budget Chainmail", "Woven from spending limits."),
    "emergency-armor": ("Emergency Bulwark", "When hard times come, reserves are armor."),
    "discipline-armor": ("Discipline Plate", "Years of steady habits give this armor its shape."),
    "future-armor": ("Foresight Armor", "It safeguards today for your future self."),
    "coin-charm": ("Pocket Change Charm", "It reminds you that even a small coin has a purpose."),
    "habit-charm": ("Habit Sigil", "Repeated good choices leave warm marks on its surface."),
    "goal-charm": ("Goal Compass", "The needle points toward your most important goal."),
    "streak-charm": ("Saving Streak Core", "Consecutive days shine together like a star cluster."),
    "freedom-charm": ("Treasure of Freedom", "What matters is the freedom to make your own choices."),
}
LEGACY_TECHNIQUES = {
    "steady-heart": ("Steady Heart", "Pause before each choice to increase critical chance."),
    "rainy-day": ("Rainy Day", "Leave room for the unexpected to improve defense."),
    "accumulate": ("Grain by Grain", "Even the smallest deposits build a steady offense."),
    "small-steps": ("Small Steps", "Keep moving forward one step at a time."),
    "long-view": ("Long View", "Look beyond immediate temptations to increase boss damage."),
    "consistent": ("Steady Stride", "Keep to a daily rhythm to earn more stardust."),
}
PETS = (
    ("Fortune Cat", "Physical Offense", "Turns every coin into a quick swipe."),
    ("Guardian Golden Retriever", "Balanced Defense", "Keeps watch over the piggy bank with dependable attack and defense."),
    ("Laurel Rabbit", "Fast Attacker", "Always one hop ahead of impulse spending."),
    ("Ledger Owl", "Magic Offense", "Reads the numbers to find the safest path."),
    ("Steady Tortoise", "Shield Defense", "Moves slowly and keeps every deposit safe."),
    ("Granary Hamster", "Fortunate Treasure Hunter", "Stashes scattered finds in its full cheeks."),
    ("Sunset Fox", "Burst Damage", "Its fiery tail flares into fierce attacks."),
    ("Ripple Otter", "Magic Shield", "Uses its shell to shape shimmering water into weapons and shields."),
    ("Bamboo Panda", "Durable Defender", "As steady and dependable as a bamboo grove."),
    ("Snowstar Penguin", "Agile Caster", "Glides over bright snow, scattering clear magic."),
    ("Hot Springs Capybara", "Health Recovery", "Its calm presence keeps the party steady."),
    ("Pinecone Squirrel", "Fast Treasure Hunter", "Quick eyes and paws never miss a gleaming find."),
)
MONSTERS = (
    ("Coin Slime", "Pocket Change Meadow", "Balanced", "Balanced offense and defense."),
    ("Impulse Moth", "Window Shopping Lane", "Increased Attack", "Attack ×1.12 after stage scaling."),
    ("Budget Stone Golem", "Planning Workshop", "Physical Resistance", "Base physical resistance +24 instead of +7. Each stage adds 2."),
    ("Receipt Paper Ball", "Receipt Corner", "Magic Resistance", "Base magic resistance +24 instead of +7. Each stage adds 2."),
    ("Snack Crate", "Impulse Stop", "Regeneration", "Recovers 1% of maximum health each turn."),
    ("Subscription Spider", "Renewal Corner", "Damage Over Time", "Attack ×1.12, plus damage equal to stage divided by 8 each turn."),
    ("Price Tag Caterpillar", "Tag Gallery", "Evasion", "Receives 90% of the hero’s damage."),
    ("Anxiety Eye", "Mood Plaza", "Magic Attack", "Attack ×1.12 and base magic resistance +24. Its magic attacks bypass defense and are reduced by magic resistance."),
    ("Shopping Bag Heap", "Stockpile Storehouse", "Heavy Armor", "Base physical resistance +24 instead of +7. Each stage adds 2."),
    ("Procrastination Snail", "Tomorrow’s Clock Court", "Opening Guard", "Base physical and magic resistance +24. At full health, it receives 80% of the hero’s damage."),
)
SKILLS = {
    "echoStrike": ("Echo Strike", "Every fifth hit deals {0}% additional damage."),
    "execution": ("Execution", "+{0}% damage against enemies below 20% health."),
    "regeneration": ("Regeneration", "After every attack, heal {0}% of maximum health. The combined cap is 3%."),
    "fortification": ("Fortification", "+{0}% maximum health."),
    "armorPierce": ("Armor Pierce", "Ignore {0}% of the enemy’s physical and magic resistance."),
    "arcaneSurge": ("Arcane Surge", "+{0}% magic damage."),
    "haste": ("Haste", "+{0}% damage of all types."),
    "luckyFind": ("Lucky Find", "+{0}% gold and insight from victories."),
}


@lru_cache(maxsize=None)
def equipment(item):
    if item.id in LEGACY_GEAR:
        name, flavor = LEGACY_GEAR[item.id]
        return {"name": name, "setName": SET_NAMES[item.set_name], "flavor": flavor}
    version, slot, raw_index = item.id.split("-")
    index, slot_index = int(raw_index) - 1, catalog.SLOT_INDEX[slot]
    noun = SLOT_NOUNS[slot_index]
    if version == "v02":
        material = MATERIALS[(index + slot_index) % len(MATERIALS)]
        epithet = EPITHETS[(index // 10) % len(EPITHETS)]
        return {"name": f"{epithet} · {material} {noun}", "setName": f"{epithet} Set",
                "flavor": f"{material} and {epithet.lower()} inscriptions, forged for adventure tier {index + 1}."}
    return {"name": f"{ADVANCED_MATERIALS[index]} · {noun}",
            "setName": "Peerless · Myriad Set" if item.rarity == 7 else "Mythic · Crimson Set",
            "flavor": "Advanced forging adds unique modifiers and improves all combat attributes."}


@lru_cache(maxsize=None)
def technique(item):
    school, culture, effect = SCHOOLS[item.school], TRADITIONS[item.culture], EFFECTS[item.effect]
    if item.id in LEGACY_TECHNIQUES:
        name, description = LEGACY_TECHNIQUES[item.id]
    else:
        version, _, _, root_index, form_index = item.id.split("-")
        root = ROOTS[int(root_index)]
        form = (FORMS if version == "v02" else ADVANCED_FORMS)[int(form_index)]
        name = f"{root} {school} · {form}"
        description = (f"A {school} technique in the {root} tradition. Effect: {effect}."
                       if version == "v02" else
                       f"An advanced {root} {school} technique with a signature move. Effect: {effect}.")
    return {"name": name, "school": school, "culture": culture, "description": description, "effectLabel": effect}


def pet(item):
    return dict(zip(("name", "role", "flavor"), PETS[item.sprite]))


@lru_cache(maxsize=1)
def _names():
    result = {item.name: equipment(item)["name"] for item in catalog.EQUIPMENT}
    result.update({item.name: technique(item)["name"] for item in catalog.TECHNIQUES})
    result.update({item.name: pet(item)["name"] for item in catalog.PETS})
    result.update({item.name: MONSTERS[item.sprite][0] for item in catalog.MONSTERS})
    return result


PLAIN = {
    "冒险开始": "Adventure Begins",
    "记账整理生活，给目标分配积蓄，勇者便会随你成长。": "Track your spending and save toward goals to help the hero grow.",
    "每秒自动战斗，失败会在原关重开": "Battles run every second. A defeat restarts the same stage.",
    "原关重开": "Stage Restarted", "兑换星券": "Tickets Exchanged", "冒险商店": "Adventure Shop",
    "更换装备": "Equipment Changed", "一键装备": "Auto-equip", "装备强化": "Equipment Enhanced",
    "出售装备": "Equipment Sold", "清理重复装备": "Duplicates Sold", "一键出售": "Bulk Sale",
    "技能一键装配": "Auto-equip Techniques", "一键遗忘": "Bulk Forget", "技能参悟": "Technique Trained",
    "宠物蛋孵化": "Pet Egg Hatched", "宠物上阵": "Pet Added to Party", "宠物一键上阵": "Party Selected",
    "目标达成": "Goal Completed", "积蓄兑换星券": "Tickets Earned",
    "装备池": "Equipment Pool", "技能池": "Technique Pool", "技能": "Technique",
    "首次获得 · 1 星幼年体": "First hatch · 1-star juvenile",
    "幼年体": "Juvenile", "成年体": "Adult", "完全体": "Full Form",
    "V0.4 自动战斗已启动": "V0.4: Automatic battles enabled",
    "旧版历史结算（规则已停用）": "Legacy reward from retired rules",
    "旧版记录": "Legacy record",
}
PLAIN.update(dict(zip(catalog.RARITY_TITLE.values(), RARITIES[1:])))
PLAIN.update({catalog.EFFECT_TITLE[key]: value for key, value in EFFECTS.items()})
PLAIN.update({row[1]: SLOT_NAMES[row[0]] for row in catalog.SLOTS})

# Only reviewed message formats are translated. Preserve unfamiliar imported event text.
MESSAGE_FORMATS = (
    (r"第 (\d+) 关通过，正在挑战第 (\d+) 关", "Stage {0} cleared. Starting stage {1}."),
    (r"第 (\d+) 关通过", "Stage {0} cleared"),
    (r"第 (\d+) 关未通过，已在原关第 (\d+) 次重开", "Stage {0} lost. Retry {1} has started."),
    (r"第 (\d+) 关暂未通过；怪物和勇者已恢复，变强后会自动继续尝试。", "Stage {0} lost. Both sides recovered and will retry automatically."),
    (r"暴击 (\d+) 点，承受 (\d+) 点伤害", "Critical hit for {0}. Received {1} damage."),
    (r"自动攻击 (\d+) 点，承受 (\d+) 点伤害", "Attack for {0}. Received {1} damage."),
    (r"击败(.+?)，获得 (\d+) 经验、(\d+) 金币和 (\d+) 悟性。", "Defeated {0} and earned {1} experience, {2} gold, and {3} insight."),
    (r"击败(.+?)，获得 (\d+) 经验、(\d+) 金币和 (\d+) 悟性；掉落“(.+?)”（(.+?)）。", "Defeated {0} and earned {1} experience, {2} gold, and {3} insight. Loot: {4} ({5})."),
    (r"重复转化 · \+(\d+) 悟性", "Duplicate · +{0} insight"),
    (r"重复转化 · \+(\d+) 星尘", "Duplicate · +{0} stardust"),
    (r"已满 99 星 · 转化为 (\d+) 金币", "At 99 stars · converted to {0} gold"),
    (r"升至 (\d+) 星 · (.+)", "Upgraded to {0} stars · {1}"),
    (r"消耗 (\d+) 金币兑换 1 张免费星券。", "Exchanged {0} gold for 1 ticket."),
    (r"消耗 (\d+) 金币购买 (\d+) (悟性|星尘)。", "Spent {0} gold for {1} {2}."),
    (r"已将“(.+?)”装备至(.+?)。", "Equipped {0} in {1}."),
    (r"已按未强化的初始战力，为 (\d+) 个装备位换上当前最强装备。", "Equipped the strongest base items in {0} slots."),
    (r"消耗 (\d+) 星尘，将“(.+?)”强化至 \+(\d+)，战力提升至 (\d+)。", "Spent {0} stardust to enhance {1} to +{2}. Its power is now {3}."),
    (r"出售 (\d+) 件“(.+?)”，获得 (\d+) 星尘。", "Sold {0} × {1} and earned {2} stardust."),
    (r"出售 (\d+) 件重复装备，获得 (\d+) 星尘。", "Sold {0} duplicate items and earned {1} stardust."),
    (r"出售 (\d+) 件(.+?)及以下未装备物品，获得 (\d+) 星尘。", "Sold {0} unequipped {1} or lower items and earned {2} stardust."),
    (r"已按未参悟的 1 重初始战力，装配当前最强的 (\d+) 门技能。", "Equipped the top {0} techniques by rank 1 power."),
    (r"遗忘 (\d+) 门(.+?)及以下未装配技能，返还 (\d+) 悟性。", "Forgot {0} unequipped {1} or lower techniques and recovered {2} insight."),
    (r"消耗 (\d+) 点悟性，将“(.+?)”修炼至 (\d+) 重。", "Spent {0} insight to train {1} to rank {2}."),
    (r"孵化出“(.+?)”：(.+?)。", "Hatched {0}: {1}."),
    (r"“(.+?)”已加入冒险队伍。", "{0} joined the party."),
    (r"已按当前星级战力选出最强的 (\d+) 只宠物。", "Selected the top {0} pets by current power."),
    (r"“(.+?)”已完成，额外获得 100 张星券。", "Completed “{0}” and earned 100 extra tickets."),
    (r"分配 (.+?)，按每 1 个货币单位 1 张的规则获得 (\d+) 张星券。", "Moved {0} into savings and earned {1} tickets."),
)
MESSAGE_FORMATS = tuple((re.compile(pattern), output) for pattern, output in MESSAGE_FORMATS)


@lru_cache(maxsize=512)
def message(value):
    if value in PLAIN:
        return PLAIN[value]
    if value in _names():
        return _names()[value]
    if value in {"悟性", "星尘"}:
        return {"悟性": "insight", "星尘": "stardust"}[value]
    for pattern, output in MESSAGE_FORMATS:
        match = pattern.fullmatch(value)
        if match:
            return output.format(*(message(part) for part in match.groups()))
    if " · " in value:
        return " · ".join(message(part) for part in value.split(" · "))
    return value


def event(row):
    return {**row, "english": {key: message(str(row.get(key) or "")) for key in ("title", "detail")}}


def hatch(row):
    return {**row, "english": {key: message(str(row.get(key) or "")) for key in ("name", "result")}} if row else None
