"""冒险属性、自动战斗、祈愿、装备、技能和宠物。"""

from __future__ import annotations

import math
import uuid

from gaojixu import catalog
from gaojixu.errors import AppError
from gaojixu.timeutil import cocoa_json


def new_id() -> str:
    return str(uuid.uuid4()).upper()


def _adv(store) -> dict:
    adventure = store.doc.get("adventure")
    if not isinstance(adventure, dict):
        raise AppError("冒险存档缺失，已停止写入。", "protected")
    return adventure


def _items(store) -> dict:
    adventure = _adv(store)
    items = adventure.get("equippedItems")
    if not isinstance(items, dict):
        items = {}
        adventure["equippedItems"] = items
    return items


def _techniques(store) -> list:
    rows = store.doc.get("techniques")
    if not isinstance(rows, list):
        rows = []
        store.doc["techniques"] = rows
    return rows


def _equipment(store) -> list:
    rows = store.doc.get("equipment")
    if not isinstance(rows, list):
        rows = []
        store.doc["equipment"] = rows
    return rows


def _pets(store) -> list:
    rows = store.doc.get("pets")
    if not isinstance(rows, list):
        rows = []
        store.doc["pets"] = rows
    return rows


def _events(store) -> list:
    rows = store.doc.get("rewardEvents")
    if not isinstance(rows, list):
        rows = []
        store.doc["rewardEvents"] = rows
    return rows


def add_event(store, title: str, detail: str, symbol: str) -> None:
    events = _events(store)
    events.insert(0, {
        "id": new_id(),
        "date": cocoa_json(store.now()),
        "title": title,
        "detail": detail,
        "symbol": symbol,
    })
    del events[catalog.REWARD_CAP:]


def add_migration_event(store, title: str, detail: str, symbol: str) -> None:
    if any(isinstance(row, dict) and row.get("title") == title for row in _events(store)):
        return
    add_event(store, title, detail, symbol)


def normalize_wording(text: str) -> str:
    return text.replace("功法", "技能")


def enhancement_level(store, definition_id: str) -> int:
    for row in _equipment(store):
        if isinstance(row, dict) and row.get("definitionID") == definition_id:
            try:
                level = int(row.get("enhancementLevel") or 0)
            except (TypeError, ValueError):
                level = 0
            return min(catalog.MAX_EQUIPMENT, max(0, level))
    return 0


def owned_count(store, definition_id: str) -> int:
    for row in _equipment(store):
        if isinstance(row, dict) and row.get("definitionID") == definition_id:
            try:
                return max(0, int(row.get("count") or 0))
            except (TypeError, ValueError):
                return 0
    return 0


def technique_level(store, technique_id: str) -> int:
    best = 0
    for row in _techniques(store):
        if isinstance(row, dict) and row.get("techniqueID") == technique_id:
            try:
                best = max(best, int(row.get("level") or 0))
            except (TypeError, ValueError):
                continue
    return min(catalog.MAX_TECHNIQUE, best)


def pet_stars(store, pet_id: str) -> int:
    for row in _pets(store):
        if isinstance(row, dict) and row.get("petID") == pet_id:
            try:
                return min(catalog.MAX_PET_STARS, max(0, int(row.get("stars") or 0)))
            except (TypeError, ValueError):
                return 0
    return 0


def equipped_pet_ids(store) -> list[str]:
    # Windows 初版将上阵名单放在 adventure 内，Mac 存在资料库顶层。
    raw = _adv(store).get("equippedPetIDs")
    if not isinstance(raw, list):
        raw = store.doc.get("equippedPetIDs")
    if not isinstance(raw, list) or not raw:
        return []
    owned = {row.get("petID") for row in _pets(store) if isinstance(row, dict) and int(row.get("stars") or 0) > 0}
    return list(dict.fromkeys(item for item in raw
                              if isinstance(item, str) and item in catalog.PET_BY_ID and item in owned))[:catalog.MAX_PETS]


def _set_equipped_pet_ids(store, ids: list[str]) -> None:
    _adv(store).pop("equippedPetIDs", None)
    store.doc["equippedPetIDs"] = ids


def equipped_ids(store) -> list[str]:
    raw = _adv(store).get("equippedTechniqueIDs") or []
    if not isinstance(raw, list):
        return []
    seen = set()
    result = []
    for item in raw:
        if item in seen or technique_level(store, item) <= 0:
            continue
        seen.add(item)
        result.append(item)
        if len(result) >= catalog.MAX_TECHNIQUES:
            break
    return result


def equipped_definitions(store):
    items = _items(store)
    result = []
    for slot, *_rest in catalog.SLOTS:
        found = catalog.EQUIPMENT_BY_ID.get(items.get(slot))
        if found and owned_count(store, found.id) > 0:
            result.append(found)
    return result


def technique_bonus(store, effect: str) -> float:
    total = 0.0
    for technique_id in equipped_ids(store):
        definition = catalog.TECHNIQUE_BY_ID.get(technique_id)
        if definition and definition.effect == effect:
            total += definition.per_level * catalog.technique_scale(technique_level(store, technique_id))
    return total


def combat_skill_power(store, skill: str) -> float:
    equipment_power = 0.0
    for definition in equipped_definitions(store):
        base = sum(power for name, power in definition.affixes if name == skill)
        scale = 1 + (catalog.equipment_multiplier(enhancement_level(store, definition.id)) - 1) * 0.5
        equipment_power += base * scale
    technique_power = 0.0
    for technique_id in equipped_ids(store):
        definition = catalog.TECHNIQUE_BY_ID.get(technique_id)
        if definition and definition.signature_skill == skill:
            technique_power += definition.signature_power * catalog.technique_scale(technique_level(store, technique_id))
    return min(catalog.SKILL_CAP[skill], equipment_power + technique_power)


def _enhanced_int(store, definition, value: int) -> int:
    return max(0, catalog.swift_round(value * catalog.equipment_multiplier(enhancement_level(store, definition.id))))


def _enhanced_float(store, definition, value: float) -> float:
    return max(0.0, value * catalog.equipment_multiplier(enhancement_level(store, definition.id)))


def hero_stats(store) -> dict:
    adventure = _adv(store)
    level = int(adventure.get("level") or 1)
    growth = max(0, level - 1)
    attack = defense = vitality = speed = fortune = 0
    physical = magic = true_damage = shield = 0
    physical_res = magic_res = 0
    critical = critical_damage = lifesteal = reduction = 0.0
    for definition in equipped_definitions(store):
        attack += _enhanced_int(store, definition, definition.attack)
        defense += _enhanced_int(store, definition, definition.defense)
        vitality += _enhanced_int(store, definition, definition.vitality)
        speed += _enhanced_int(store, definition, definition.speed)
        fortune += _enhanced_int(store, definition, definition.fortune)
        physical += _enhanced_int(store, definition, definition.physical_damage)
        magic += _enhanced_int(store, definition, definition.magic_damage)
        true_damage += _enhanced_int(store, definition, definition.true_damage)
        shield += _enhanced_int(store, definition, definition.shield)
        physical_res += _enhanced_int(store, definition, definition.physical_resistance)
        magic_res += _enhanced_int(store, definition, definition.magic_resistance)
        critical += _enhanced_float(store, definition, definition.critical)
        critical_damage += _enhanced_float(store, definition, definition.critical_damage)
        lifesteal += _enhanced_float(store, definition, definition.lifesteal)
        reduction += _enhanced_float(store, definition, definition.damage_reduction)
    for pet_id in equipped_pet_ids(store):
        pet = catalog.PET_BY_ID[pet_id]
        scale = catalog.pet_multiplier(pet_stars(store, pet_id))
        attack += catalog.swift_round(pet.attack * scale)
        defense += catalog.swift_round(pet.defense * scale)
        vitality += catalog.swift_round(pet.vitality * scale)
        speed += catalog.swift_round(pet.speed * scale)
        fortune += catalog.swift_round(pet.fortune * scale)
        physical += catalog.swift_round(pet.physical * scale)
        magic += catalog.swift_round(pet.magic * scale)
        shield += catalog.swift_round(pet.shield * scale)
    stats = {
        "attack": 12 + growth * 3 + attack + catalog.trunc(technique_bonus(store, "attack")) + catalog.trunc(technique_bonus(store, "incomePower") * 100),
        "defense": 6 + growth * 2 + defense + catalog.trunc(technique_bonus(store, "defense")) + catalog.trunc(technique_bonus(store, "budgetPower") * 100),
        "vitality": 24 + growth * 4 + vitality + catalog.trunc(technique_bonus(store, "vitality")),
        "critical": min(0.65, 0.05 + growth * 0.001 + critical + technique_bonus(store, "critical")),
        "fortune": growth // 10 + fortune + catalog.trunc(technique_bonus(store, "fortune")),
        "physical": 4 + growth + physical + catalog.trunc(technique_bonus(store, "physicalDamage")),
        "magic": 2 + growth // 2 + magic + catalog.trunc(technique_bonus(store, "magicDamage")),
        "true": growth // 12 + true_damage + catalog.trunc(technique_bonus(store, "trueDamage")) + catalog.trunc(technique_bonus(store, "depositPower") * 100),
        "criticalDamage": 1.5 + growth * 0.002 + critical_damage + technique_bonus(store, "criticalDamage"),
        "lifesteal": min(0.20, lifesteal + technique_bonus(store, "lifesteal")),
        "speed": 10 + growth // 3 + speed + catalog.trunc(technique_bonus(store, "speed")) + catalog.trunc(technique_bonus(store, "streakPower") * 100),
        "physicalResistance": 6 + growth // 3 + physical_res + catalog.trunc(technique_bonus(store, "physicalResistance")),
        "magicResistance": 6 + growth // 3 + magic_res + catalog.trunc(technique_bonus(store, "magicResistance")),
        "damageReduction": min(0.50, min(0.05, growth * 0.0005) + reduction + technique_bonus(store, "damageReduction")),
        "shield": growth * 2 + shield + catalog.trunc(technique_bonus(store, "shield")) + catalog.trunc(technique_bonus(store, "expenseGuard") * 100),
    }
    fortification = combat_skill_power(store, "fortification")
    stats["maxHP"] = max(1, catalog.trunc((100 + stats["vitality"] * 5 + stats["shield"] * 2) * (1 + fortification)))
    stats["level"] = level
    return stats


def current_stage(store) -> int:
    index = int(_adv(store).get("monsterIndex") or 0)
    if index >= 2**63 - 2:
        return 2**63 - 1
    return max(1, index + 1)


def current_monster(store):
    if not catalog.MONSTERS:
        raise AppError("怪物图鉴为空。", "invalid")
    index = int(_adv(store).get("monsterIndex") or 0)
    return catalog.MONSTERS[max(0, index) % len(catalog.MONSTERS)]


def _stage_scaled(base: int, growth: float, stage: int) -> int:
    safe = max(1, base)
    maximum = (2**63 - 1) / 8
    step = float(min(100_000, max(0, stage - 1)))
    exponent = min(step * math.log(growth), math.log(maximum / safe))
    return max(safe, catalog.swift_round(safe * math.exp(exponent)))


def monster_max_hp(store) -> int:
    return _stage_scaled(current_monster(store).max_hp, 1.11, current_stage(store))


def monster_attack(store) -> int:
    monster = current_monster(store)
    trait = 1.12 if monster.sprite in {1, 5, 7} else 1
    return max(1, catalog.trunc(_stage_scaled(9, 1.088, current_stage(store)) * trait))


def monster_physical_resistance(store) -> int:
    bonus = 24 if current_monster(store).sprite in {2, 8, 9} else 7
    return bonus + min(100_000, current_stage(store)) * 2


def monster_magic_resistance(store) -> int:
    bonus = 24 if current_monster(store).sprite in {3, 7, 9} else 7
    return bonus + min(100_000, current_stage(store)) * 2


def equipment_power(store, definition) -> int:
    return max(1, catalog.swift_round(
        definition.base_power * catalog.equipment_multiplier(enhancement_level(store, definition.id))))


def power_breakdown(store, stats=None) -> dict:
    stats = stats or hero_stats(store)
    level = stats["level"]
    growth = max(0, level - 1)
    base = (
        (12 + growth * 3) * catalog.W_ATTACK + (6 + growth * 2) * catalog.W_DEFENSE
        + (24 + growth * 4) * catalog.W_VITALITY + (10 + growth // 3) * catalog.W_SPEED
        + (6 + growth // 3) * catalog.W_RESIST * 2 + level * catalog.W_LEVEL
    )
    gear = sum(equipment_power(store, definition) for definition in equipped_definitions(store))
    techniques = sum(_technique_power(store, catalog.TECHNIQUE_BY_ID[item]) for item in equipped_ids(store))
    pets = sum(catalog.PET_BY_ID[item].power(pet_stars(store, item)) for item in equipped_pet_ids(store))
    return {"base": base, "equipment": gear, "techniques": techniques, "pets": pets}


def hero_power(store, stats=None) -> int:
    return sum(power_breakdown(store, stats).values())


def _technique_power(store, definition, level=None) -> int:
    if level is None:
        level = technique_level(store, definition.id)
    level = min(catalog.MAX_TECHNIQUE, max(1, int(level)))
    scale = catalog.technique_scale(level)
    value = definition.per_level * scale
    effect = definition.effect
    weights = {
        "attack": value * catalog.W_ATTACK, "defense": value * catalog.W_DEFENSE, "vitality": value * catalog.W_VITALITY,
        "critical": value * catalog.W_CRIT, "criticalDamage": value * catalog.W_CRIT_DMG, "lifesteal": value * catalog.W_LEECH,
        "speed": value * catalog.W_SPEED, "physicalResistance": value * catalog.W_RESIST, "magicResistance": value * catalog.W_RESIST,
        "physicalDamage": value * catalog.W_PHYS, "magicDamage": value * catalog.W_MAGIC, "trueDamage": value * catalog.W_TRUE,
        "damageReduction": value * catalog.W_REDUCE, "shield": value * catalog.W_SHIELD, "bossDamage": value * 2000,
        "experience": value * 400, "stardust": value * 400, "depositPower": value * 100 * catalog.W_TRUE,
        "streakPower": value * 100 * catalog.W_SPEED, "budgetPower": value * 100 * catalog.W_DEFENSE,
        "incomePower": value * 100 * catalog.W_ATTACK, "expenseGuard": value * 100 * catalog.W_SHIELD,
        "fortune": value * catalog.W_FORTUNE,
    }
    signature = definition.signature_power * scale * catalog.SKILL_WEIGHT[definition.signature_skill]
    return max(1, definition.rarity * 100 + catalog.trunc(weights[effect]) + catalog.trunc(signature))


def monster_power(store) -> int:
    return max(1, monster_max_hp(store) // catalog.W_MONSTER_HP + monster_attack(store) * catalog.W_MONSTER_ATTACK
               + monster_physical_resistance(store) * catalog.W_MONSTER_RESIST
               + monster_magic_resistance(store) * catalog.W_MONSTER_RESIST)


def _power_modifiers(hero: int, monster: int):
    ratio = min(20, max(0.05, max(1, hero) / max(1, monster)))
    return min(1.80, max(0.20, ratio ** 0.90)), min(4.00, max(0.55, (1 / ratio) ** 0.90))


def experience_needed(level: int) -> int:
    return 90 + max(0, level - 1) * 35


def _resolve_levels(store) -> bool:
    adventure = _adv(store)
    leveled = False
    while int(adventure.get("experience") or 0) >= experience_needed(int(adventure.get("level") or 1)):
        adventure["experience"] = int(adventure["experience"]) - experience_needed(int(adventure["level"]))
        adventure["level"] = int(adventure["level"]) + 1
        adventure["insight"] = int(adventure.get("insight") or 0) + 5
        leveled = True
    return leveled


def _grant_equipment(store, definition) -> str:
    if owned_count(store, definition.id) > 0:
        converted = _sale_stardust(store, definition) * max(2, definition.rarity)
        _adv(store)["stardust"] = int(_adv(store).get("stardust") or 0) + converted
        return f"重复转化 · +{converted} 星尘"
    rows = _equipment(store)
    for row in rows:
        if row.get("definitionID") == definition.id:
            row["count"] = int(row.get("count") or 0) + 1
            return f"{catalog.slot_title(definition.slot)} · {catalog.RARITY_TITLE[definition.rarity]}"
    rows.append({"definitionID": definition.id, "count": 1})
    return f"{catalog.slot_title(definition.slot)} · {catalog.RARITY_TITLE[definition.rarity]}"


def _grant_technique(store, definition) -> str:
    if technique_level(store, definition.id) > 0:
        converted = definition.rarity * definition.rarity * 40
        _adv(store)["insight"] = int(_adv(store).get("insight") or 0) + converted
        return f"重复转化 · +{converted} 悟性"
    _techniques(store).append({"techniqueID": definition.id, "level": 1})
    return f"技能 · {catalog.RARITY_TITLE[definition.rarity]} · {catalog.EFFECT_TITLE[definition.effect]}"


def _sale_stardust(store, definition) -> int:
    base = definition.rarity * definition.rarity * 40 + enhancement_level(store, definition.id) * definition.rarity * 20
    return max(1, catalog.swift_round(base * (1 + technique_bonus(store, "stardust"))))


def roll_rarity(store, minimum: int | None, fortune: int | None = None) -> int:
    fortune = hero_stats(store)["fortune"] if fortune is None else fortune
    ultra = store.rng.randint(1, 1_000_000)
    if ultra == 1:
        rolled = 7
    elif ultra <= 101:
        rolled = 6
    else:
        roll = max(1, store.rng.randint(1, 1000) - min(180, fortune * 2))
        if roll <= 10:
            rolled = 5
        elif roll <= 60:
            rolled = 4
        elif roll <= 200:
            rolled = 3
        elif roll <= 520:
            rolled = 2
        else:
            rolled = 1
    if minimum and rolled < minimum:
        return minimum
    return rolled


def _random_of(pool, rarity: int, rng):
    matched = [item for item in pool if item.rarity == rarity]
    source = matched or pool
    if not source:
        return None
    return source[rng.randrange(len(source))]


def battle_tick(store) -> dict:
    store.require_ready()
    if not catalog.MONSTERS:
        return {"skipped": True}
    adventure = _adv(store)
    monster = current_monster(store)
    stage = current_stage(store)
    stats = hero_stats(store)
    max_monster = monster_max_hp(store)
    max_hero = stats["maxHP"]
    old_hp = min(max_monster, max(1, int(adventure.get("monsterHP") or max_monster)))
    attack_number = int(adventure.get("attackCount") or 0) + 1
    adventure["attackCount"] = attack_number
    outgoing, incoming_scale = _power_modifiers(hero_power(store, stats), monster_power(store))
    penetration = combat_skill_power(store, "armorPierce")
    physical_res = monster_physical_resistance(store) * (1 - penetration)
    magic_res = monster_magic_resistance(store) * (1 - penetration)
    physical = (stats["attack"] + stats["physical"]) * 100 / (100 + max(0, physical_res))
    magic = stats["magic"] * (1 + combat_skill_power(store, "arcaneSurge")) * 100 / (100 + max(0, magic_res))
    critical = store.rng.random() < stats["critical"]
    speed = 1 + min(0.8, stats["speed"] / 220)
    damage = (physical + magic) * speed + stats["true"]
    damage *= 1 + combat_skill_power(store, "haste")
    if stage % 10 == 0:
        damage *= 1 + technique_bonus(store, "bossDamage")
    if critical:
        damage *= stats["criticalDamage"]
    if attack_number % 5 == 0:
        damage *= 1 + combat_skill_power(store, "echoStrike")
    if old_hp / max_monster <= 0.2:
        damage *= 1 + combat_skill_power(store, "execution")
    if monster.sprite == 6:
        damage *= 0.9
    if monster.sprite == 9 and old_hp == max_monster:
        damage *= 0.8
    damage *= outgoing
    dealt = max(1, catalog.swift_round(damage))
    adventure["monsterHP"] = old_hp - dealt
    if adventure["monsterHP"] <= 0:
        adventure["defeatedMonsters"] = int(adventure.get("defeatedMonsters") or 0) + 1
        reward = 1 + combat_skill_power(store, "luckyFind") + min(0.5, stats["fortune"] / 200)
        coins = max(20, catalog.trunc((25 + min(2000, stage) * 5) * reward))
        insight = max(1, catalog.trunc((monster.insight + min(500, stage // 3)) * reward))
        xp = max(1, catalog.trunc((monster.xp + min(2000, stage * 3)) * (1 + technique_bonus(store, "experience"))))
        adventure["coins"] = int(adventure.get("coins") or 0) + coins
        adventure["insight"] = int(adventure.get("insight") or 0) + insight
        adventure["experience"] = int(adventure.get("experience") or 0) + xp
        _resolve_levels(store)
        loot = ""
        if store.rng.randint(1, 100) <= min(75, 30 + stats["fortune"]):
            rarity = roll_rarity(store, None, stats["fortune"])
            if store.rng.randint(1, 100) <= 35:
                definition = _random_of(catalog.TECHNIQUES, rarity, store.rng)
                if definition:
                    loot = f"；掉落“{definition.name}”（{_grant_technique(store, definition)}）"
            else:
                definition = _random_of(catalog.EQUIPMENT, rarity, store.rng)
                if definition:
                    loot = f"；掉落“{definition.name}”（{_grant_equipment(store, definition)}）"
        cleared = stage
        cleared_name = monster.name
        if int(adventure.get("monsterIndex") or 0) < 2**62:
            adventure["monsterIndex"] = int(adventure.get("monsterIndex") or 0) + 1
        adventure["monsterHP"] = monster_max_hp(store)
        adventure["heroHP"] = hero_stats(store)["maxHP"]
        adventure["battleAttempts"] = 0
        adventure["lastBattleMessage"] = f"第 {cleared} 关通过，正在挑战第 {current_stage(store)} 关"
        add_event(store, f"第 {cleared} 关通过", f"击败{cleared_name}，获得 {xp} 经验、{coins} 金币和 {insight} 悟性{loot}。", "forward.fill")
        store.save_game()
        return {"defeated": True, "dealt": dealt, "stage": cleared, "coins": coins}
    if monster.sprite == 4:
        adventure["monsterHP"] = min(max_monster, int(adventure["monsterHP"]) + max(1, max_monster // 100))
    incoming = float(monster_attack(store))
    if monster.sprite == 7:
        incoming *= 100 / (100 + stats["magicResistance"])
    else:
        incoming = max(1, incoming - stats["defense"] * 0.18)
        incoming *= 100 / (100 + stats["physicalResistance"])
    if monster.sprite == 5:
        incoming += max(1, stage // 8)
    incoming *= 1 - stats["damageReduction"]
    incoming *= incoming_scale
    ratio = max(1, hero_power(store, stats)) / max(1, monster_power(store))
    pressure_ratio = min(0.12, (1 - ratio) * 0.10) if ratio < 1 else 0
    pressure = max(1, catalog.trunc(max(1, max_hero) * pressure_ratio))
    received = max(pressure, max(1, catalog.swift_round(incoming)))
    raw_healing = catalog.trunc(dealt * stats["lifesteal"]) + catalog.trunc(max_hero * combat_skill_power(store, "regeneration"))
    healing = min(max(0, catalog.trunc(max(1, max_hero) * 0.04)), raw_healing)
    before = min(max_hero, int(adventure.get("heroHP") or max_hero) + healing)
    adventure["heroHP"] = before - received
    if int(adventure.get("heroHP") or 0) <= 0:
        attempts = int(adventure.get("battleAttempts") or 0) + 1
        adventure["battleAttempts"] = attempts
        adventure["monsterHP"] = max_monster
        adventure["heroHP"] = max_hero
        adventure["lastBattleMessage"] = f"第 {stage} 关未通过，已在原关第 {attempts} 次重开"
        if attempts == 1 or attempts % 10 == 0:
            add_event(store, "原关重开", f"第 {stage} 关暂未通过；怪物和勇者已恢复，变强后会自动继续尝试。", "arrow.counterclockwise")
        result = {"defeated": False, "restarted": True, "dealt": dealt, "received": received}
    else:
        message = f"暴击 {dealt} 点，承受 {received} 点伤害" if critical else f"自动攻击 {dealt} 点，承受 {received} 点伤害"
        adventure["lastBattleMessage"] = message
        result = {"defeated": False, "dealt": dealt, "received": received, "critical": critical}
    store.save_game()
    return result


def _pity(store, pool: str) -> dict:
    adventure = _adv(store)
    key = "equipmentPityCounters" if pool == "equipment" else "techniquePityCounters"
    raw = adventure.get(key)
    if not isinstance(raw, dict):
        rare = adventure.get("equipmentPityCount" if pool == "equipment" else "techniquePityCount")
        if rare is None:
            rare = adventure.get("pityCount") or 0
        raw = {"rare": int(rare or 0), "epic": 0, "legendary": 0, "mythic": 0, "peerless": 0}
    names = {3: "rare", 4: "epic", 5: "legendary", 6: "mythic", 7: "peerless"}
    counters = {}
    for tier, name in names.items():
        maximum = max(0, catalog.GUARANTEE[tier] - 1)
        try:
            value = int(raw.get(name) or 0)
        except (TypeError, ValueError):
            value = 0
        counters[name] = min(maximum, max(0, value))
    return counters


def _set_pity(store, pool: str, counters: dict) -> None:
    adventure = _adv(store)
    key = "equipmentPityCounters" if pool == "equipment" else "techniquePityCounters"
    legacy = "equipmentPityCount" if pool == "equipment" else "techniquePityCount"
    adventure[key] = dict(counters)
    adventure[legacy] = counters["rare"]


def _guaranteed_minimum(store, pool: str) -> int | None:
    counters = _pity(store, pool)
    names = {3: "rare", 4: "epic", 5: "legendary", 6: "mythic", 7: "peerless"}
    for tier in (7, 6, 5, 4, 3):
        if counters[names[tier]] >= catalog.GUARANTEE[tier] - 1:
            return tier
    return None


def _record_pity(store, pool: str, rarity: int) -> None:
    counters = _pity(store, pool)
    names = {3: "rare", 4: "epic", 5: "legendary", 6: "mythic", 7: "peerless"}
    for tier, name in names.items():
        maximum = max(0, catalog.GUARANTEE[tier] - 1)
        value = 0 if rarity >= tier else counters[name] + 1
        counters[name] = min(maximum, max(0, value))
    _set_pity(store, pool, counters)


def draw(store, count: int, pool: str) -> dict:
    store.require_ready()
    if count not in {1, 10, 100}:
        raise AppError("祈愿次数只支持 1、10 或 100 连，本次未扣券。", "invalid")
    if pool not in {"equipment", "technique"}:
        raise AppError("祈愿池只支持装备或技能。", "invalid")
    adventure = _adv(store)
    tickets = int(adventure.get("tickets") or 0)
    if tickets < count:
        raise AppError("星券不足。每积蓄 1 个货币单位获得 1 张星券，也可使用金币兑换。", "invalid")
    adventure["tickets"] = tickets - count
    reveals = []
    source = catalog.TECHNIQUES if pool == "technique" else catalog.EQUIPMENT
    label = "技能池" if pool == "technique" else "装备池"
    for _ in range(count):
        rarity = roll_rarity(store, _guaranteed_minimum(store, pool))
        definition = _random_of(source, rarity, store.rng)
        if definition:
            subtitle = _grant_technique(store, definition) if pool == "technique" else _grant_equipment(store, definition)
            reveals.append({
                "title": definition.name,
                "detail": f"{label} · {subtitle}",
                "symbol": definition.symbol,
                "rarity": rarity,
            })
        _record_pity(store, pool, rarity)
    reveals.sort(key=lambda row: (-row["rarity"], row["title"]))
    moment = store.now().timestamp()
    history = store.doc.get("drawHistory") if isinstance(store.doc.get("drawHistory"), list) else []
    entries = []
    for index, reveal in enumerate(reveals):
        when = store.now()
        # 与 Mac 相同：同一批按 0.001 秒错开，便于倒序稳定。
        from datetime import timedelta
        stamped = when - timedelta(milliseconds=index)
        entries.append({
            "id": new_id(),
            "date": cocoa_json(stamped),
            "title": reveal["title"],
            "detail": reveal["detail"],
            "symbol": reveal["symbol"],
            "rarity": reveal["rarity"],
        })
        _ = moment
    store.doc["drawHistory"] = (entries + history)[:catalog.DRAW_CAP]
    store.save_game()
    return {"reveals": reveals, "tickets": adventure["tickets"]}


def exchange_ticket(store) -> dict:
    return exchange_resource(store, "tickets")


def exchange_resource(store, resource: str) -> dict:
    store.require_ready()
    amount, label = {"tickets": (1, "星券"), "insight": (50, "悟性"), "stardust": (50, "星尘")}.get(resource, (0, ""))
    if not amount:
        raise AppError("请选择星券、悟性或星尘。", "invalid")
    adventure = _adv(store)
    coins = int(adventure.get("coins") or 0)
    cost = catalog.TICKET_EXCHANGE_COST
    if coins < cost:
        raise AppError(f"金币不足，需要 {cost} 金币。", "invalid")
    adventure["coins"] = coins - cost
    adventure[resource] = int(adventure.get(resource) or 0) + amount
    if resource == "tickets":
        add_event(store, "兑换星券", f"消耗 {cost} 金币兑换 1 张免费星券。", "ticket.fill")
    else:
        add_event(store, "冒险商店", f"消耗 {cost} 金币购买 {amount} {label}。", "cart.fill")
    store.save_game()
    return {resource: adventure[resource], "coins": adventure["coins"]}


def equip(store, definition_id: str) -> None:
    store.require_ready()
    definition = catalog.EQUIPMENT_BY_ID.get(definition_id)
    if not definition or owned_count(store, definition_id) <= 0:
        raise AppError("背包里没有这件装备。", "invalid")
    _items(store)[definition.slot] = definition.id
    add_event(store, "更换装备", f"已将“{definition.name}”装备至{catalog.slot_title(definition.slot)}。", definition.symbol)
    store.save_game()


def unequip(store, slot: str) -> dict:
    store.require_ready()
    if slot not in catalog.SLOT_INDEX:
        raise AppError("请选择有效的装备部位。", "invalid")
    removed = _items(store).pop(slot, None)
    if removed:
        legacy = {"mainHand": "equippedWeaponID", "chest": "equippedArmorID", "relic": "equippedCharmID"}
        if slot in legacy:
            _adv(store).pop(legacy[slot], None)
        store.save_game()
    return {"id": removed}


def equip_best(store) -> dict:
    store.require_ready()
    owned = []
    for row in _equipment(store):
        if int(row.get("count") or 0) <= 0:
            continue
        definition = catalog.EQUIPMENT_BY_ID.get(row.get("definitionID"))
        if definition:
            owned.append(definition)
    selected = {}
    for slot, *_rest in catalog.SLOTS:
        candidates = [item for item in owned if item.slot == slot]
        if not candidates:
            continue
        best = min(candidates, key=lambda item: (-item.base_power, -item.rarity, item.name))
        selected[slot] = best.id
    if not selected:
        raise AppError("背包里还没有可以装备的物品。", "invalid")
    _adv(store)["equippedItems"] = selected
    add_event(store, "一键装备", f"已按未强化的初始战力，为 {len(selected)} 个装备位换上当前最强装备。", "wand.and.stars")
    store.save_game()
    return {"count": len(selected)}


def enhance(store, definition_id: str) -> dict:
    store.require_ready()
    definition = catalog.EQUIPMENT_BY_ID.get(definition_id)
    row = next((item for item in _equipment(store) if item.get("definitionID") == definition_id), None)
    if not definition or row is None:
        raise AppError("背包中没有这件装备。", "invalid")
    current = enhancement_level(store, definition_id)
    if current >= catalog.MAX_EQUIPMENT:
        raise AppError(f"这件装备已经强化至 +{catalog.MAX_EQUIPMENT}。", "invalid")
    cost = catalog.equipment_upgrade_cost(definition.rarity, current + 1)
    adventure = _adv(store)
    if int(adventure.get("stardust") or 0) < cost:
        raise AppError(f"星尘不足，本次强化需要 {cost} 星尘。", "invalid")
    adventure["stardust"] = int(adventure.get("stardust") or 0) - cost
    row["enhancementLevel"] = current + 1
    add_event(store, "装备强化", f"消耗 {cost} 星尘，将“{definition.name}”强化至 +{current + 1}，战力提升至 {equipment_power(store, definition)}。", "sparkles")
    store.save_game()
    return {"level": current + 1, "cost": cost}


def _rarity_limit(value: int) -> str:
    if value not in range(1, 6):
        raise AppError("整理仅支持普通至传说品质。", "invalid")
    return catalog.RARITY_TITLE[value]


def sell_equipment(store, definition_id: str, count: int = 1) -> dict:
    store.require_ready()
    definition = catalog.EQUIPMENT_BY_ID.get(definition_id)
    if not definition or owned_count(store, definition_id) <= 0:
        raise AppError("背包中没有这件装备。", "invalid")
    if _items(store).get(definition.slot) == definition_id:
        raise AppError("已装备的物品不能出售，请先卸下。", "invalid")
    row = next(item for item in _equipment(store) if item.get("definitionID") == definition_id)
    count = min(max(1, count), int(row["count"]))
    earned = _sale_stardust(store, definition) * count
    row["count"] -= count
    if row["count"] <= 0:
        _equipment(store).remove(row)
    _adv(store)["stardust"] = int(_adv(store).get("stardust") or 0) + earned
    add_event(store, "出售装备", f"出售 {count} 件“{definition.name}”，获得 {earned} 星尘。", "sparkles")
    store.save_game()
    return {"count": count, "earned": earned}


def sell_equipment_group(store, maximum_rarity: int | None = None) -> dict:
    store.require_ready()
    rarity = _rarity_limit(maximum_rarity) if maximum_rarity is not None else None
    equipped = set(_items(store).values())
    sold = earned = 0
    rows = _equipment(store)
    for row in rows[:]:
        definition = catalog.EQUIPMENT_BY_ID.get(row.get("definitionID"))
        if not definition or (maximum_rarity is not None and definition.rarity > maximum_rarity):
            continue
        kept = int(maximum_rarity is None or definition.id in equipped)
        count = max(0, int(row.get("count") or 0) - kept)
        if count <= 0:
            continue
        sold += count
        earned += _sale_stardust(store, definition) * count
        row["count"] -= count
        if row["count"] <= 0:
            rows.remove(row)
    if sold <= 0:
        message = f"没有可出售的{rarity}及以下未装备物品。" if rarity else "没有可清理的重复装备；每种装备会保留 1 件。"
        raise AppError(message, "invalid")
    _adv(store)["stardust"] = int(_adv(store).get("stardust") or 0) + earned
    if rarity is None:
        add_event(store, "清理重复装备", f"出售 {sold} 件重复装备，获得 {earned} 星尘。", "shippingbox.and.arrow.backward.fill")
    else:
        add_event(store, "一键出售", f"出售 {sold} 件{rarity}及以下未装备物品，获得 {earned} 星尘。", "trash.slash.fill")
    store.save_game()
    return {"count": sold, "earned": earned}


def equip_technique(store, technique_id: str) -> None:
    store.require_ready()
    definition = catalog.TECHNIQUE_BY_ID.get(technique_id)
    if not definition or technique_level(store, technique_id) <= 0:
        raise AppError("需要先获得这门技能。", "invalid")
    ids = equipped_ids(store)
    if technique_id in ids:
        return
    if len(ids) >= catalog.MAX_TECHNIQUES:
        raise AppError(f"最多同时装配 {catalog.MAX_TECHNIQUES} 门技能，请先卸下一门。", "invalid")
    ids.append(technique_id)
    _adv(store)["equippedTechniqueIDs"] = ids
    store.save_game()


def unequip_technique(store, technique_id: str) -> dict:
    store.require_ready()
    ids = equipped_ids(store)
    if technique_id in ids:
        ids.remove(technique_id)
        _adv(store)["equippedTechniqueIDs"] = ids
        store.save_game()
    return {"equipped": False}


def equip_best_techniques(store) -> dict:
    store.require_ready()
    learned = []
    for row in _techniques(store):
        if int(row.get("level") or 0) <= 0:
            continue
        definition = catalog.TECHNIQUE_BY_ID.get(row.get("techniqueID"))
        if definition:
            learned.append(definition)
    learned.sort(key=lambda item: (-_technique_power(store, item, 1), -item.rarity, item.name))
    selected = [item.id for item in learned[:catalog.MAX_TECHNIQUES]]
    if not selected:
        raise AppError("还没有已学技能可以装配。", "invalid")
    _adv(store)["equippedTechniqueIDs"] = selected
    add_event(store, "技能一键装配", f"已按未参悟的 1 重初始战力，装配当前最强的 {len(selected)} 门技能。", "books.vertical.fill")
    store.save_game()
    return {"count": len(selected)}


def forget_techniques(store, maximum_rarity: int) -> dict:
    store.require_ready()
    rarity = _rarity_limit(maximum_rarity)
    equipped = set(equipped_ids(store))
    rows = _techniques(store)
    forgotten = returned = 0
    for row in rows[:]:
        definition = catalog.TECHNIQUE_BY_ID.get(row.get("techniqueID"))
        level = min(catalog.MAX_TECHNIQUE, max(0, int(row.get("level") or 0)))
        if not definition or not level or definition.id in equipped or definition.rarity > maximum_rarity:
            continue
        forgotten += 1
        returned += definition.rarity ** 2 * 40
        returned += sum(catalog.technique_upgrade_cost(definition.rarity, rank) for rank in range(1, level))
        rows.remove(row)
    if not forgotten:
        raise AppError(f"没有可遗忘的{rarity}及以下未装配技能。", "invalid")
    _adv(store)["insight"] = int(_adv(store).get("insight") or 0) + returned
    add_event(store, "一键遗忘", f"遗忘 {forgotten} 门{rarity}及以下未装配技能，返还 {returned} 悟性。", "brain.head.profile")
    store.save_game()
    return {"count": forgotten, "earned": returned}


def upgrade_technique(store, technique_id: str) -> dict:
    store.require_ready()
    definition = catalog.TECHNIQUE_BY_ID.get(technique_id)
    row = next((item for item in _techniques(store) if item.get("techniqueID") == technique_id and int(item.get("level") or 0) > 0), None)
    if not definition or row is None:
        raise AppError("需要先获得这门技能。", "invalid")
    level = int(row["level"])
    if level >= catalog.MAX_TECHNIQUE:
        raise AppError(f"这门技能已经修炼至 {catalog.MAX_TECHNIQUE} 重。", "invalid")
    cost = catalog.technique_upgrade_cost(definition.rarity, level)
    adventure = _adv(store)
    if int(adventure.get("insight") or 0) < cost:
        raise AppError(f"悟性不足，本次参悟需要 {cost} 点。", "invalid")
    adventure["insight"] = int(adventure.get("insight") or 0) - cost
    row["level"] = level + 1
    add_event(store, "技能参悟", f"消耗 {cost} 点悟性，将“{definition.name}”修炼至 {level + 1} 重。", definition.symbol)
    store.save_game()
    return {"level": level + 1, "cost": cost}


def grant_pet(store, definition) -> str:
    rows = _pets(store)
    for row in rows:
        if row.get("petID") == definition.id:
            stars = int(row.get("stars") or 1)
            if stars >= catalog.MAX_PET_STARS:
                _adv(store)["coins"] = int(_adv(store).get("coins") or 0) + catalog.PET_EGG_COST
                return f"已满 99 星 · 转化为 {catalog.PET_EGG_COST} 金币"
            row["stars"] = min(catalog.MAX_PET_STARS, stars + 1)
            stage = "幼年体" if row["stars"] <= 1 else "成年体" if row["stars"] == 2 else "完全体"
            return f"升至 {row['stars']} 星 · {stage}"
    rows.append({"petID": definition.id, "stars": 1})
    return "首次获得 · 1 星幼年体"


def hatch_pet(store) -> dict:
    store.require_ready()
    adventure = _adv(store)
    if int(adventure.get("coins") or 0) < catalog.PET_EGG_COST:
        raise AppError(f"金币不足，宠物蛋需要 {catalog.PET_EGG_COST} 金币。", "invalid")
    if not catalog.PETS:
        raise AppError("宠物图鉴为空。", "invalid")
    definition = catalog.PETS[store.rng.randrange(len(catalog.PETS))]
    adventure["coins"] = int(adventure.get("coins") or 0) - catalog.PET_EGG_COST
    result = grant_pet(store, definition)
    store.latest_pet_hatch = {"petID": definition.id, "name": definition.name, "stars": pet_stars(store, definition.id), "result": result}
    add_event(store, "宠物蛋孵化", f"孵化出“{definition.name}”：{result}。", "pawprint.fill")
    store.save_game()
    return store.latest_pet_hatch


def equip_pet(store, pet_id: str) -> None:
    store.require_ready()
    definition = catalog.PET_BY_ID.get(pet_id)
    if not definition or pet_stars(store, pet_id) <= 0:
        raise AppError("需要先孵化这只宠物。", "invalid")
    ids = equipped_pet_ids(store)
    if pet_id in ids:
        return
    if len(ids) >= catalog.MAX_PETS:
        raise AppError(f"最多同时上阵 {catalog.MAX_PETS} 只宠物。", "invalid")
    ids.append(pet_id)
    _set_equipped_pet_ids(store, ids)
    add_event(store, "宠物上阵", f"“{definition.name}”已加入冒险队伍。", "pawprint.fill")
    store.save_game()


def unequip_pet(store, pet_id: str) -> dict:
    store.require_ready()
    ids = equipped_pet_ids(store)
    if pet_id in ids:
        ids.remove(pet_id)
        _set_equipped_pet_ids(store, ids)
        store.save_game()
    return {"equipped": False}


def equip_best_pets(store) -> dict:
    store.require_ready()
    candidates = [(pet_stars(store, pet.id), pet) for pet in catalog.PETS]
    ranked = [(stars, pet) for stars, pet in candidates if stars > 0]
    ranked.sort(key=lambda pair: (-pair[1].power(pair[0]), pair[1].name))
    selected = [pet.id for _, pet in ranked[:catalog.MAX_PETS]]
    if not selected:
        raise AppError("宠物背包里还没有伙伴。", "invalid")
    _set_equipped_pet_ids(store, selected)
    add_event(store, "宠物一键上阵", f"已按当前星级战力选出最强的 {len(selected)} 只宠物。", "pawprint.fill")
    store.save_game()
    return {"count": len(selected)}


def grant_savings_tickets(store, amount: float, goal_title: str, completed: bool, currency_symbol: str) -> None:
    earned = max(0, math.floor(amount))
    adventure = _adv(store)
    adventure["tickets"] = int(adventure.get("tickets") or 0) + earned
    if completed:
        adventure["tickets"] += 100
        add_event(store, "目标达成", f"“{goal_title}”已完成，额外获得 100 张星券。", "trophy.fill")
    add_event(store, "积蓄兑换星券", f"分配 {currency_symbol}{amount:g}，按每 1 个货币单位 1 张的规则获得 {earned} 张星券。", "ticket.fill")


def normalize_loaded(store) -> bool:
    """按 Mac apply() 整理游戏字段。返回是否改动了应落盘的内容。"""
    changed = False
    doc = store.doc
    adventure = doc.get("adventure")
    if not isinstance(adventure, dict):
        return False
    version = int(doc.get("version") or 0)
    if isinstance(adventure.get("lastBattleMessage"), str):
        updated = normalize_wording(adventure["lastBattleMessage"])
        if updated != adventure["lastBattleMessage"]:
            adventure["lastBattleMessage"] = updated
            changed = True
    for row in doc.get("equipment") or []:
        if isinstance(row, dict):
            level = min(catalog.MAX_EQUIPMENT, max(0, int(row.get("enhancementLevel") or 0)))
            if row.get("enhancementLevel") not in (None, level) and "enhancementLevel" in row:
                row["enhancementLevel"] = level
                changed = True
            elif "enhancementLevel" in row and int(row.get("enhancementLevel") or 0) != level:
                row["enhancementLevel"] = level
                changed = True
    seen = {}
    order = []
    for row in doc.get("techniques") or []:
        if not isinstance(row, dict) or int(row.get("level") or 0) <= 0:
            continue
        technique_id = row.get("techniqueID")
        if technique_id not in catalog.TECHNIQUE_BY_ID:
            continue
        level = min(catalog.MAX_TECHNIQUE, max(seen.get(technique_id, 0), int(row.get("level") or 0)))
        if technique_id not in seen:
            order.append(technique_id)
        seen[technique_id] = level
    normalized_techniques = [{"techniqueID": item, "level": seen[item]} for item in order]
    if normalized_techniques != [row for row in (doc.get("techniques") or []) if isinstance(row, dict)]:
        # 保留未知字段会在完全重建时丢失。只在重复或非法时重建。
        raw = [row for row in (doc.get("techniques") or []) if isinstance(row, dict)]
        if len(raw) != len(normalized_techniques) or any(row.get("level", 0) <= 0 for row in raw):
            doc["techniques"] = normalized_techniques
            changed = True
    pet_order = []
    pet_stars_map = {}
    for row in doc.get("pets") or []:
        if not isinstance(row, dict) or row.get("petID") not in catalog.PET_BY_ID:
            continue
        pet_id = row["petID"]
        stars = min(catalog.MAX_PET_STARS, max(1, int(row.get("stars") or 1)))
        if pet_id not in pet_stars_map:
            pet_order.append(pet_id)
        pet_stars_map[pet_id] = max(pet_stars_map.get(pet_id, 0), stars)
    if isinstance(doc.get("pets"), list):
        cleaned = [{"petID": item, "stars": pet_stars_map[item]} for item in pet_order]
        original = [row for row in doc["pets"] if isinstance(row, dict)]
        if any(row.get("petID") not in catalog.PET_BY_ID for row in original) or len(original) != len(cleaned):
            doc["pets"] = cleaned
            changed = True
    pet_ids = equipped_pet_ids(store)
    if "equippedPetIDs" in adventure or (doc.get("equippedPetIDs") is not None and doc["equippedPetIDs"] != pet_ids):
        _set_equipped_pet_ids(store, pet_ids)
        changed = True
    items = adventure.get("equippedItems")
    if not isinstance(items, dict):
        migrated = {}
        if adventure.get("equippedWeaponID"):
            migrated["mainHand"] = adventure["equippedWeaponID"]
        if adventure.get("equippedArmorID"):
            migrated["chest"] = adventure["equippedArmorID"]
        if adventure.get("equippedCharmID"):
            migrated["relic"] = adventure["equippedCharmID"]
        adventure["equippedItems"] = migrated
        changed = True
    if adventure.get("equippedTechniqueIDs") is None:
        adventure["equippedTechniqueIDs"] = [row["techniqueID"] for row in doc.get("techniques") or [] if int(row.get("level") or 0) > 0][:catalog.MAX_TECHNIQUES]
        changed = True
    else:
        filtered = equipped_ids(store)
        if filtered != adventure.get("equippedTechniqueIDs"):
            adventure["equippedTechniqueIDs"] = filtered
            changed = True
    if version < 3:
        adventure["coins"] = max(10_000, int(adventure.get("coins") or 0))
        adventure["tickets"] = max(10_000, int(adventure.get("tickets") or 0))
        adventure["insight"] = max(10_000, int(adventure.get("insight") or 0))
        adventure["stardust"] = max(10_000, int(adventure.get("stardust") or 0))
        add_migration_event(store, "旧版测试补给", "金币、星券、悟性与星尘均已补足至至少 10,000。", "wrench.and.screwdriver.fill")
        changed = True
    elif adventure.get("coins") is None:
        adventure["coins"] = 0
        changed = True
    adventure["monsterIndex"] = max(0, int(adventure.get("monsterIndex") or 0))
    if version < 4:
        adventure["monsterHP"] = monster_max_hp(store)
        adventure["heroHP"] = hero_stats(store)["maxHP"]
        adventure["battleAttempts"] = 0
        adventure["attackCount"] = 0
        adventure["lastBattleMessage"] = "V0.4 自动战斗已启动"
        add_migration_event(store, "V0.4 无限冒险", "战斗改为每秒自动进行；失败会在原关重开，十种像素怪物循环且强度持续上涨。", "forward.fill")
        changed = True
    else:
        adventure["monsterHP"] = min(max(1, int(adventure.get("monsterHP") or 1)), monster_max_hp(store))
        adventure["heroHP"] = min(max(1, int(adventure.get("heroHP") or hero_stats(store)["maxHP"])), hero_stats(store)["maxHP"])
        adventure["battleAttempts"] = max(0, int(adventure.get("battleAttempts") or 0))
        adventure["attackCount"] = max(0, int(adventure.get("attackCount") or 0))
    if version < 5:
        add_migration_event(store, "V0.5 战利品更新", "旧技能残页与重复条目已清理；击杀现在是经验的唯一来源，并有概率掉落装备或技能。", "shippingbox.fill")
        changed = True
    if version < 10:
        for row in doc.get("rewardEvents") or []:
            if isinstance(row, dict) and isinstance(row.get("detail"), str) and not row["detail"].startswith("旧版历史结算"):
                row["detail"] = "旧版历史结算（规则已停用）· " + normalize_wording(row["detail"])
                changed = True
        for row in doc.get("drawHistory") or []:
            if isinstance(row, dict) and isinstance(row.get("detail"), str) and not str(row["detail"]).startswith("旧版记录"):
                row["detail"] = "旧版记录 · " + normalize_wording(row["detail"])
                changed = True
        if adventure.get("equipmentPityCount") is None:
            adventure["equipmentPityCount"] = adventure.get("pityCount") or 0
            changed = True
        if adventure.get("techniquePityCount") is None:
            adventure["techniquePityCount"] = adventure.get("pityCount") or 0
            changed = True
        add_migration_event(store, "V1.0 战力与强化", "装备等级已改为 +0 至 +10 强化；装备、技能、角色和怪物均已接入战力评估，祈愿池与货币来源也已重构。", "bolt.shield.fill")
        changed = True
    if version < 11:
        add_migration_event(store, "V1.1 装备整理", "一键出售已支持史诗品质；一键装备会按每个部位的未强化初始战力选择最强装备。", "wand.and.stars")
        changed = True
    if version < 12:
        adventure["monsterHP"] = min(max(1, int(adventure.get("monsterHP") or 1)), monster_max_hp(store))
        adventure["heroHP"] = min(max(1, int(adventure.get("heroHP") or hero_stats(store)["maxHP"])), hero_stats(store)["maxHP"])
        add_migration_event(store, "V1.2 数值重制", "重算角色、装备、技能与怪物战力，限制异常回复和减伤叠加，并让双方战力差直接校准实战伤害。", "scalemass.fill")
        changed = True
    if version < 13:
        for pool, legacy_key in (("equipment", "equipmentPityCount"), ("technique", "techniquePityCount")):
            if _adv(store).get("equipmentPityCounters" if pool == "equipment" else "techniquePityCounters") is None:
                rare = int(adventure.get(legacy_key) or adventure.get("pityCount") or 0)
                counters = _migrated_pity(store, pool, rare)
                _set_pity(store, pool, counters)
                changed = True
        add_migration_event(store, "V1.3 阶梯保底", "装备池与技能池分别累计：10 抽稀有、30 抽史诗、150 抽传说、500 抽神话、2000 抽绝世。", "shield.checkered")
        changed = True
    for title, detail, symbol, threshold in (
        ("V1.4 技能整理", "新增普通至传说五档一键遗忘；已装配技能会保留，并按品质及参悟投入返还悟性。", "brain.head.profile", 14),
        ("V1.5 九十九重成长", "装备强化与技能参悟上限提升至 99，后期每级属性和战力增量会逐步提高。", "chart.line.uptrend.xyaxis", 15),
        ("V1.6 账户联动与宠物", "积蓄记录现在同步生成账户转账；新增 12 种三形态宠物、4 个上阵位、99 星成长与宠物商店。", "pawprint.fill", 16),
        ("V1.7 紧凑流水表", "日常记账和积蓄记录改用紧凑表格展示，让日期、账户、分类、备注与金额在同一行快速浏览。", "list.bullet.rectangle.fill", 17),
        ("V1.8 桌面小组件", "新增月度每日收支与积蓄日历、净资产小组件；财务总览同步展示日历统计，账户速览按净资产贡献从高到低排列。", "rectangle.on.rectangle.angled", 18),
    ):
        if version < threshold:
            add_migration_event(store, title, detail, symbol)
            changed = True
    return changed


def _migrated_pity(store, pool: str, rare_count: int) -> dict:
    names = {3: "rare", 4: "epic", 5: "legendary", 6: "mythic", 7: "peerless"}
    counters = {name: 0 for name in names.values()}
    counters["rare"] = min(max(0, catalog.GUARANTEE[3] - 1), max(0, rare_count))
    label = "装备池" if pool == "equipment" else "技能池"
    history = [row for row in (store.doc.get("drawHistory") or []) if isinstance(row, dict) and label in str(row.get("detail") or "")]
    history.sort(key=lambda row: float(row.get("date") or 0), reverse=True)
    for tier in (4, 5, 6, 7):
        maximum = max(0, catalog.GUARANTEE[tier] - 1)
        misses = 0
        for entry in history:
            try:
                rarity = int(entry.get("rarity") or 0)
            except (TypeError, ValueError):
                rarity = 0
            if rarity >= tier:
                break
            misses += 1
            if misses >= maximum:
                break
        counters[names[tier]] = misses
    return counters
