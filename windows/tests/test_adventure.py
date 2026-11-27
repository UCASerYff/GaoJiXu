from datetime import datetime, timezone
import random
import re

import pytest

from gaojixu import adventure, adventure_view, catalog, finance
from gaojixu.errors import AppError
from gaojixu.store import Store
from gaojixu.web import dispatch


def open_store(path):
    return Store(path, now=lambda: datetime(2026, 11, 27, tzinfo=timezone.utc), tz=timezone.utc, rng=random.Random(16))


@pytest.fixture
def store(tmp_path):
    result = open_store(tmp_path)
    result.create_library()
    return result


def action(store, route, **payload):
    return dispatch(store, f"/api/adventure/{route}", payload)


def test_loadout_honors_empty_and_sells_only_unprotected_gear(store):
    with pytest.raises(AppError, match="已装备"):
        action(store, "sell", id="wood-sword")
    assert action(store, "enhance", id="wood-sword") == {"level": 1, "cost": 70}
    details = adventure_view.gear_details(store, "wood-sword")
    assert len(details["attributes"]) == 15 and details["enhancement"] == 1 and details["sale"] == 60
    store.doc["equipment"][0]["count"] = 3
    assert action(store, "sell-group") == {"count": 2, "earned": 120}
    assert adventure.owned_count(store, "wood-sword") == 1
    for slot in ("mainHand", "chest"):
        action(store, "unequip", slot=slot)
    reopened = open_store(store.directory)
    assert reopened.snapshot()["adventure"]["equipped"] == {}
    result = action(reopened, "sell-group", rarity=1)
    assert result["count"] == 2 and reopened.snapshot()["adventure"]["gear"] == []


def test_draw_pools_exchange_and_forget_refunds(store):
    expected_insight = store.doc["adventure"]["insight"] + 50
    assert action(store, "exchange", resource="insight") == {"insight": expected_insight, "coins": 9500}
    assert action(store, "exchange", resource="stardust") == {"stardust": 10050, "coins": 9000}
    assert action(store, "exchange", resource="tickets") == {"tickets": 10001, "coins": 8500}
    for pool, count in (("equipment", 1), ("technique", 100)):
        result = action(store, "draw", pool=pool, count=count)
        assert len(result["reveals"]) == count
        tiers = [item["rarity"] for item in result["reveals"]]
        assert tiers == sorted(tiers, reverse=True)
    game = store.snapshot()["adventure"]
    assert len(game["history"]) == 7 and game["pity"]["equipment"] != game["pity"]["technique"]
    assert game["techniqueCount"] == len(adventure_view.collection(store, "technique"))
    store.doc["techniques"] = [{"techniqueID": "steady-heart", "level": 1}, {"techniqueID": "rainy-day", "level": 4}]
    assert action(store, "forget-techniques", rarity=2) == {"count": 1, "earned": 400}
    assert adventure.technique_level(store, "steady-heart") == 1
    action(store, "unequip-technique", id="steady-heart")
    assert action(store, "forget-techniques", rarity=2)["count"] == 1


def test_pet_loadout_migrates_with_power_and_round_trips(store):
    pet = catalog.PETS[0]
    store.doc["pets"] = [{"petID": pet.id, "stars": 3}]
    store.doc["adventure"]["equippedPetIDs"] = [pet.id]
    store.save_game()
    reopened = open_store(store.directory)
    assert reopened.snapshot()["adventure"]["powerBreakdown"]["pets"] == pet.power(3)
    assert reopened.doc["equippedPetIDs"] == [pet.id]
    assert "equippedPetIDs" not in reopened.doc["adventure"]
    assert reopened.snapshot()["adventure"]["petCatalog"][0]["stage"] == 2
    assert action(reopened, "unequip-pet", id=pet.id) == {"equipped": False}
    assert action(reopened, "pet-best") == {"count": 1}
    assert open_store(store.directory).doc["equippedPetIDs"] == [pet.id]
    result = action(reopened, "hatch")
    assert result["stars"] >= 1 and reopened.snapshot()["adventure"]["latestPetHatch"] == result


def test_goal_completion_changes_tickets_and_live_achievements(store):
    cash = store.doc["accounts"][0]
    savings = store.doc["accounts"][1]
    target = store.doc["goals"][0]
    finance.save_account(store, {**cash, "balance": 20000})
    before = store.doc["adventure"]["tickets"]
    finance.save_record(store, {"goalID": target["id"], "kind": "deposit", "amount": 10000,
                                "fundingAccountID": cash["id"], "savingsAccountID": savings["id"], "category": "other"})
    updated = store.snapshot()
    assert updated["summary"]["tickets"] - before == 10100
    assert updated["adventure"]["savingDays"] == 1
    unlocked = {item["title"] for item in updated["adventure"]["achievements"] if item["unlocked"]}
    assert {"第一枚硬币", "半程灯火", "愿望落地"} <= unlocked


def test_english_adventure_catalog_and_rewards_do_not_rewrite_localized_save(store):
    chinese = re.compile(r"[\u4e00-\u9fff]")
    data_file = store.directory / "library.json"
    original = data_file.read_bytes()
    for kind in ("equipment", "technique"):
        for row in adventure_view.collection(store, kind):
            assert row["english"]["name"] and all(not chinese.search(display) for display in row["english"].values())
    game = store.snapshot()["adventure"]
    assert game["english"]["monster"] == "Coin Slime"
    assert game["gear"][0]["english"]["name"] == "Savings Wooden Sword"
    assert game["techniques"][0]["english"]["name"] == "Steady Heart"
    assert game["attributes"][0]["english"]["name"] == "Attack"
    assert game["events"][0]["english"]["title"] == "Adventure Begins"
    assert data_file.read_bytes() == original
    for pool in ("equipment", "technique"):
        reveals = action(store, "draw", count=10, pool=pool)["reveals"]
        assert all(not chinese.search(row["english"]["title"] + row["english"]["detail"]) for row in reveals)
    assert all("english" not in row for row in store.doc["drawHistory"])
