"""Read models for the adventure pages and the observation panel."""

from gaojixu import adventure, adventure_english as english, catalog, finance
from gaojixu.timeutil import read_cocoa


ATTRIBUTES = (
    ("attack", "攻击", "bolt.fill", "attack"), ("defense", "防御", "shield.fill", "defense"),
    ("vitality", "生命", "heart.fill", "vitality"), ("critical", "暴击率", "burst.fill", "critical"),
    ("criticalDamage", "暴击效果", "sparkles", "critical_damage"), ("lifesteal", "吸血", "drop.fill", "lifesteal"),
    ("speed", "速度", "wind", "speed"), ("physicalResistance", "物理抗性", "shield.fill", "physical_resistance"),
    ("magicResistance", "魔法抗性", "wand.and.stars", "magic_resistance"), ("physical", "物理伤害", "hammer.fill", "physical_damage"),
    ("magic", "魔法伤害", "flame.fill", "magic_damage"), ("true", "真实伤害", "scope", "true_damage"),
    ("damageReduction", "伤害减免", "checkmark.shield.fill", "damage_reduction"), ("shield", "护盾", "hexagon.fill", "shield"),
    ("fortune", "幸运", "star.circle.fill", "fortune"),
)
PERCENT_ATTRIBUTES = {"critical", "criticalDamage", "lifesteal", "damageReduction"}
ATTRIBUTE_ENGLISH = {"physical": "Physical Damage", "magic": "Magic Damage", "true": "True Damage"}
FLAT_EFFECTS = {"attack", "defense", "vitality", "speed", "physicalResistance", "magicResistance", "physicalDamage",
                "magicDamage", "trueDamage", "shield", "fortune"}
PERCENT_EFFECTS = {"critical", "criticalDamage", "lifesteal", "damageReduction", "bossDamage", "experience", "stardust"}
SKILLS = {
    "echoStrike": ("复击", "arrow.triangle.2.circlepath", "每第 5 次攻击追加 {0}% 伤害"),
    "execution": ("收束", "scope", "目标低于 20% 生命时伤害 +{0}%"),
    "regeneration": ("回春", "heart.fill", "每次攻击后恢复 {0}% 最大生命（同类总上限 3%）"),
    "fortification": ("磐壁", "shield.fill", "最大生命 +{0}%"),
    "armorPierce": ("穿透", "arrow.right.to.line.compact", "忽略怪物 {0}% 双抗"),
    "arcaneSurge": ("法涌", "wand.and.stars", "魔法伤害 +{0}%"),
    "haste": ("疾行", "wind", "全部伤害 +{0}%"),
    "luckyFind": ("寻宝", "sparkles", "过关金币与悟性 +{0}%"),
}
MONSTER_TRAITS = (
    "无特殊机制，攻防均衡。", "攻击 ×1.12（关卡成长后再乘算）。", "物理抗性基础 +24（普通怪 +7），每关再 +2。",
    "魔法抗性基础 +24（普通怪 +7），每关再 +2。", "每回合回复最大生命 1%。",
    "攻击 ×1.12；每回合额外追加 关卡÷8 点伤害。", "受到的玩家伤害 ×0.9。",
    "攻击 ×1.12，魔法抗性基础 +24；攻击为魔法伤害，无视防御、受魔法抗性减免。",
    "物理抗性基础 +24（普通怪 +7），每关再 +2。", "物理/魔法抗性基础 +24；满血时受到的玩家伤害 ×0.8。",
)


def _skill(key, value):
    name, symbol, explanation = SKILLS[key]
    percent = max(1, catalog.swift_round(min(value, catalog.SKILL_CAP[key]) * 100))
    title, detail = english.SKILLS[key]
    return {"name": name, "symbol": symbol, "detail": explanation.format(percent),
            "english": {"name": title, "detail": detail.format(percent)}}


def _attribute_rows(values, gear=False):
    rows = []
    for key, label, symbol, _ in ATTRIBUTES:
        value = values[key]
        if key in PERCENT_ATTRIBUTES:
            prefix = "+" if gear and key == "criticalDamage" else ""
            value = f"{prefix}{int(value * 100)}%"
        rows.append({"name": label, "value": value, "symbol": symbol,
                     "english": {"name": ATTRIBUTE_ENGLISH.get(key) or english.EFFECTS[key]}})
    return rows


def gear_definition(item):
    return {"id": item.id, "name": item.name, "slot": item.slot, "rarity": item.rarity,
            "setName": item.set_name, "flavor": item.flavor, "symbol": item.symbol, "power": item.base_power,
            "english": english.equipment(item)}


def technique_definition(item):
    return {"id": item.id, "name": item.name, "rarity": item.rarity, "school": item.school,
            "culture": item.culture, "description": item.description, "symbol": item.symbol,
            "effect": item.effect, "effectLabel": catalog.EFFECT_TITLE[item.effect],
            "english": english.technique(item)}


def gear_card(store, item):
    enhancement = adventure.enhancement_level(store, item.id)
    return {**gear_definition(item), "count": adventure.owned_count(store, item.id), "enhancement": enhancement,
            "power": adventure.equipment_power(store, item), "sale": adventure._sale_stardust(store, item),
            "enhanceCost": catalog.equipment_upgrade_cost(item.rarity, enhancement + 1) if enhancement < catalog.MAX_EQUIPMENT else 0}


def gear_details(store, definition_id):
    item = catalog.EQUIPMENT_BY_ID.get(definition_id)
    if item is None:
        return None
    values = {}
    scale = catalog.equipment_multiplier(adventure.enhancement_level(store, item.id))
    for key, _, _, source in ATTRIBUTES:
        value = getattr(item, source) * scale
        values[key] = value if key in PERCENT_ATTRIBUTES else catalog.swift_round(value)
    return {**gear_card(store, item), "attributes": _attribute_rows(values, gear=True),
            "affixes": [_skill(key, power) for key, power in item.affixes]}


def technique_card(store, item, level=None):
    level = adventure.technique_level(store, item.id) if level is None else level
    scale = catalog.technique_scale(level)
    effect = item.per_level * scale
    amount = max(1, catalog.swift_round(effect if item.effect in FLAT_EFFECTS else effect * 100))
    bonus = f"{amount}%" if item.effect in PERCENT_EFFECTS else str(amount)
    definition = technique_definition(item)
    definition["english"] = {**definition["english"], "effectDisplay": f"{english.EFFECTS[item.effect]} +{bonus}"}
    return {**definition, "level": level, "power": adventure._technique_power(store, item, level),
            "upgradeCost": catalog.technique_upgrade_cost(item.rarity, level) if 0 < level < catalog.MAX_TECHNIQUE else 0,
            "effectDisplay": f"{catalog.EFFECT_TITLE[item.effect]} +{bonus}",
            "signature": _skill(item.signature_skill, item.signature_power * scale)}


def collection(store, kind):
    store.require_ready()
    if kind == "equipment":
        return [gear_definition(item) for item in catalog.EQUIPMENT]
    if kind == "technique":
        return [technique_card(store, item, 0) for item in catalog.TECHNIQUES]
    return []


def _pet_card(store, pet):
    stars = adventure.pet_stars(store, pet.id)
    return {"id": pet.id, "name": pet.name, "role": pet.role, "flavor": pet.flavor, "sprite": pet.sprite,
            "stars": stars, "power": pet.power(max(1, stars)), "stage": min(2, max(0, stars - 1)),
            "english": english.pet(pet)}


def _achievements(store, goal_rows, gear, techniques, game):
    deposits = [row for row in finance.records(store) if row.get("kind") == "deposit"]
    saving_days = len({date.date() for row in deposits if (date := read_cocoa(row.get("date"), store.tz))})
    deposit_count = len(deposits)
    best = catalog.swift_round(max((row["progress"] for row in goal_rows), default=0) * 1000) // 10
    victories = int(game.get("defeatedMonsters") or 0)
    definitions = [
        ("第一枚硬币", "完成第一笔有效存入", deposit_count, 1, "circle.fill", "orange"),
        ("积少成多", "完成 5 笔有效存入", deposit_count, 5, "square.stack.3d.up.fill", "teal"),
        ("长期主义者", "完成 20 笔有效存入", deposit_count, 20, "calendar.badge.checkmark", "blue"),
        ("七日不断", "连续 7 天记录积蓄", finance.saving_streak(store), 7, "flame.fill", "red"),
        ("半程灯火", f"任一目标达到 50%（当前最佳 {best}%）", best, 50, "moonphase.first.quarter", "purple"),
        ("愿望落地", "完成第一个攒钱目标", sum(goal["status"] == "completed" for goal in goal_rows), 1, "trophy.fill", "orange"),
        ("初战告捷", "击败第一只怪物", victories, 1, "burst.fill", "green"),
        ("百战积蓄", "累计击败 8 只怪物", victories, 8, "shield.checkered", "blue"),
        ("渐入佳境", "勇者达到 5 级", int(game.get("level") or 1), 5, "arrow.up.circle.fill", "green"),
        ("稀有收藏家", "获得一件稀有或更高装备", sum(item["rarity"] >= 3 for item in gear), 1, "diamond.fill", "purple"),
        ("传说相伴", "获得一件传说或更高装备", sum(item["rarity"] >= 5 for item in gear), 1, "star.fill", "orange"),
        ("心法初成", "修炼 3 门不同技能", len(techniques), 3, "scroll.fill", "purple"),
    ]
    titles = (
        ("First Coin", "Record your first valid deposit."),
        ("Small Savings Add Up", "Record 5 valid deposits."),
        ("Long-term Saver", "Record 20 valid deposits."),
        ("Seven-day Streak", "Record savings 7 days in a row."),
        ("Halfway Light", f"Reach 50% of any goal. Current best: {best}%."),
        ("Wish Fulfilled", "Complete your first savings goal."),
        ("First Victory", "Defeat your first enemy."),
        ("Battle-tested Saver", "Defeat 8 enemies."),
        ("Growing Stronger", "Reach hero level 5."),
        ("Rare Collector", "Obtain a rare or higher item."),
        ("Legendary Companion", "Obtain a legendary or higher item."),
        ("Technique Student", "Learn 3 different techniques."),
    )
    return saving_days, [{"title": title, "detail": detail, "current": min(value, total), "total": total,
                          "unlocked": value >= total, "symbol": symbol, "color": color,
                          "english": {"title": en_title, "detail": en_detail}}
                         for (title, detail, value, total, symbol, color), (en_title, en_detail) in zip(definitions, titles)]


def snapshot(store, goal_rows):
    game = store.doc["adventure"]
    stats = adventure.hero_stats(store)
    breakdown = adventure.power_breakdown(store, stats)
    monster = adventure.current_monster(store)
    monster_hp = adventure.monster_max_hp(store)
    level = int(game.get("level") or 1)
    owned_gear = [gear_card(store, item) for row in store.doc.get("equipment") or []
                  if (item := catalog.EQUIPMENT_BY_ID.get(row.get("definitionID"))) and int(row.get("count") or 0) > 0]
    owned_tech = [technique_card(store, item, rank) for row in store.doc.get("techniques") or []
                  if (item := catalog.TECHNIQUE_BY_ID.get(row.get("techniqueID"))) and (rank := int(row.get("level") or 0)) > 0]
    pets = [_pet_card(store, item) for item in catalog.PETS]
    saving_days, achievements = _achievements(store, goal_rows, owned_gear, owned_tech, game)
    affixes = [_skill(key, power) for key in catalog.COMBAT_SKILLS if (power := adventure.combat_skill_power(store, key)) > 0]
    translated = dict(zip(("monster", "monsterChapter", "monsterTrait", "monsterTraitDetail"), english.MONSTERS[monster.sprite]))
    message = game.get("lastBattleMessage") or ""
    translated["message"] = english.message(str(message))
    return {
        "level": level, "experience": game.get("experience"), "experienceNeeded": adventure.experience_needed(level),
        "heroHP": min(stats["maxHP"], max(0, int(game.get("heroHP", stats["maxHP"]) or stats["maxHP"]))), "heroMaxHP": stats["maxHP"],
        "attack": stats["attack"], "defense": stats["defense"], "power": sum(breakdown.values()), "powerBreakdown": breakdown,
        "monster": monster.name, "monsterChapter": monster.chapter, "monsterSymbol": monster.symbol, "monsterSprite": monster.sprite,
        "monsterTrait": monster.trait, "monsterTraitDetail": MONSTER_TRAITS[monster.sprite],
        "monsterHP": min(monster_hp, max(0, int(game.get("monsterHP") or 0))), "monsterMaxHP": monster_hp,
        "monsterPower": adventure.monster_power(store), "stage": adventure.current_stage(store), "message": message,
        "english": translated,
        "defeated": int(game.get("defeatedMonsters") or 0), "attempts": int(game.get("battleAttempts") or 0),
        "attackCount": int(game.get("attackCount") or 0),
        "equipped": game.get("equippedItems") or {}, "equippedTechniques": adventure.equipped_ids(store),
        "equippedPets": adventure.equipped_pet_ids(store), "latestPetHatch": english.hatch(getattr(store, "latest_pet_hatch", None)),
        "attributes": _attribute_rows(stats), "affixes": affixes,
        "pity": {pool: adventure._pity(store, pool) for pool in ("equipment", "technique")},
        "gear": owned_gear, "techniques": owned_tech, "pets": [pet for pet in pets if pet["stars"] > 0], "petCatalog": pets,
        "gearCount": len(catalog.EQUIPMENT), "techniqueCount": len(catalog.TECHNIQUES),
        "slots": [{"id": key, "name": name, "symbol": symbol, "english": {"name": english.SLOT_NAMES[key]}}
                  for key, name, _, symbol in catalog.SLOTS],
        "effects": catalog.EFFECT_TITLE, "schools": sorted({item.school for item in catalog.TECHNIQUES}),
        "effectsEnglish": english.EFFECTS, "schoolsEnglish": english.SCHOOLS,
        "history": [english.event(row) for row in (store.doc.get("drawHistory") or [])[:7] if isinstance(row, dict)],
        "events": [english.event(row) for row in (store.doc.get("rewardEvents") or [])[:6] if isinstance(row, dict)],
        "savingDays": saving_days, "achievements": achievements,
    }
