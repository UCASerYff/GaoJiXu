import json
import random
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from gaojixu import catalog
from gaojixu.errors import AppError
from gaojixu.money import money
from gaojixu.store import Store
from gaojixu.web import serve


def utc_store(tmp_path, when=None, rng=None):
    moment = when or datetime(2026, 11, 15, 9, 0, tzinfo=timezone.utc)
    return Store(tmp_path, now=lambda: moment, tz=timezone.utc, rng=rng or random.Random(1))


def test_catalog_matches_mac_ids():
    assert len(catalog.EQUIPMENT) == 15 + 14 * 40 + 14 * 12
    assert len(catalog.TECHNIQUES) == 6 + 20 * 10 * 6 + 20 * 10 * 2
    sword = catalog.EQUIPMENT_BY_ID["wood-sword"]
    assert sword.attack == 4 and sword.slot == "mainHand"
    generated = catalog.EQUIPMENT_BY_ID["v02-mainHand-01"]
    assert generated.name == "守序·青铜刃"
    technique = catalog.TECHNIQUE_BY_ID["v02-tech-0-0-0"]
    assert technique.name == "太初炼体·入门篇"
    assert catalog.equipment_upgrade_cost(1, 1) == 70
    assert catalog.technique_upgrade_cost(2, 1) == 40


def test_create_roundtrip_preserves_unknown_and_does_not_rewrite(tmp_path):
    store = utc_store(tmp_path)
    store.create_library()
    path = tmp_path / "library.json"
    document = json.loads(path.read_text(encoding="utf-8"))
    document["macOnlyField"] = {"kept": True}
    document["goals"][0]["futureNote"] = "保留"
    path.write_text(json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    raw = path.read_bytes()
    again = utc_store(tmp_path)
    assert again.status == "ready"
    assert path.read_bytes() == raw
    assert again.doc["macOnlyField"]["kept"] is True
    finance_account = again.doc["accounts"][0]["id"]
    from gaojixu import finance
    finance.save_entry(again, {"kind": "expense", "accountID": finance_account, "amount": 12.5, "categoryID": "food", "note": "午饭"})
    saved = json.loads(path.read_text(encoding="utf-8"))
    assert saved["macOnlyField"]["kept"] is True
    assert saved["goals"][0]["futureNote"] == "保留"
    assert saved["version"] == 24
    assert any(row["note"] == "午饭" for row in saved["ledgerEntries"])


def test_corrupt_and_newer_library_are_not_overwritten(tmp_path):
    broken = tmp_path / "broken"
    broken.mkdir()
    target = broken / "library.json"
    target.write_bytes(b"{unreadable")
    store = utc_store(broken)
    assert store.status == "protected"
    assert target.read_bytes() == b"{unreadable"
    with pytest.raises(AppError):
        store.create_library()
    newer = tmp_path / "newer"
    newer.mkdir()
    payload = {"version": 25, "goals": [], "records": [], "adventure": {}, "equipment": [], "techniques": [], "rewardEvents": [], "drawHistory": []}
    raw = json.dumps(payload).encode("utf-8")
    (newer / "library.json").write_bytes(raw)
    assert utc_store(newer).status == "protected"
    assert (newer / "library.json").read_bytes() == raw


def test_nonempty_directory_without_library_is_not_treated_as_blank(tmp_path):
    (tmp_path / "notes.txt").write_text("已有资料", encoding="utf-8")
    store = utc_store(tmp_path)
    assert store.status == "protected"
    assert not (tmp_path / "library.json").exists()


def test_balances_budget_and_transfer(tmp_path):
    store = utc_store(tmp_path)
    store.create_library()
    from gaojixu import finance
    cash = next(row for row in store.doc["accounts"] if row["name"] == "现金")
    bank = next(row for row in store.doc["accounts"] if row["name"] == "银行卡")
    finance.save_account(store, {"id": cash["id"], "name": "现金", "type": "cash", "currency": "CNY", "balance": 100, "includeInNetWorth": True})
    assert finance.account_balance(store, cash) == 100
    assert finance.month_income(store, "CNY") == 0
    finance.save_entry(store, {"kind": "expense", "accountID": cash["id"], "amount": 30, "categoryID": "food", "note": "午饭"})
    assert finance.account_balance(store, cash) == 70
    assert finance.month_expense(store, "CNY") == 30
    usd = finance.save_account(store, {"name": "美元现金", "type": "cash", "currency": "USD", "balance": 0, "includeInNetWorth": True})
    with pytest.raises(AppError):
        finance.save_entry(store, {"kind": "transfer", "accountID": cash["id"], "targetAccountID": usd["id"], "amount": 10, "note": ""})
    finance.save_entry(store, {"kind": "transfer", "accountID": cash["id"], "targetAccountID": bank["id"], "amount": 20, "note": "转入"})
    assert finance.account_balance(store, cash) == 50
    assert finance.account_balance(store, bank) == 20
    credit = finance.save_account(store, {"name": "信用卡", "type": "credit", "currency": "CNY", "balance": 0, "includeInNetWorth": True})
    finance.save_entry(store, {"kind": "expense", "accountID": credit["id"], "amount": 15, "categoryID": "food", "note": "刷卡"})
    assert finance.account_balance(store, credit) == 15
    assert finance.net_worth_contribution(store, credit) == -15
    finance.save_budget(store, {"monthKey": "2026-11", "categoryID": "food", "currency": "CNY", "amount": 200})
    assert store.doc["budgets"][0]["id"] == "2026-11-CNY-food"
    finance.delete_account(store, cash["id"])
    assert next(row for row in store.doc["accounts"] if row["id"] == cash["id"])["isArchived"] is True


def test_recurring_keeps_month_anchor(tmp_path):
    store = utc_store(tmp_path, datetime(2025, 4, 1, tzinfo=timezone.utc))
    store.create_library()
    from gaojixu import finance
    cash = store.doc["accounts"][0]
    finance.save_rule(store, {
        "kind": "expense", "amount": 10, "accountID": cash["id"], "categoryID": "housing",
        "frequency": "monthly", "nextDueDate": "2025-01-31", "note": "房租", "isEnabled": True,
    })
    assert finance.materialize_recurring(store, datetime(2025, 3, 31, tzinfo=timezone.utc)) == 3
    dates = sorted(row["date"] for row in store.doc["ledgerEntries"] if row.get("recurringRuleID"))
    rendered = [datetime(2001, 1, 1, tzinfo=timezone.utc) + timedelta(seconds=value) for value in dates]
    assert [item.day for item in rendered] == [31, 28, 31]
    assert finance.materialize_recurring(store, datetime(2025, 3, 31, tzinfo=timezone.utc)) == 0


def test_goal_tickets_and_withdrawal_limit(tmp_path):
    store = utc_store(tmp_path)
    store.create_library()
    from gaojixu import finance
    cash, bank = store.doc["accounts"]
    goal = finance.save_goal(store, {"title": "旅行", "targetAmount": 10, "currency": "CNY", "deadline": "2027-01-01"})
    before = store.doc["adventure"]["tickets"]
    finance.save_record(store, {
        "goalID": goal["id"], "kind": "deposit", "amount": 12.9, "fundingAccountID": cash["id"],
        "savingsAccountID": bank["id"], "category": "salary",
    })
    assert store.doc["adventure"]["tickets"] == before + 12 + 100
    assert store.doc["goals"][0]["status"] == "completed" or any(row["status"] == "completed" for row in store.doc["goals"] if row["id"] == goal["id"])
    transfer = next(row for row in store.doc["ledgerEntries"] if row["categoryID"] == "savings-goal-transfer")
    assert transfer["accountID"] == cash["id"] and transfer["targetAccountID"] == bank["id"]
    with pytest.raises(AppError):
        finance.save_record(store, {
            "goalID": goal["id"], "kind": "withdrawal", "amount": 100, "fundingAccountID": cash["id"],
            "savingsAccountID": bank["id"], "category": "other",
        })


def test_fixed_income_confirms_once(tmp_path):
    store = utc_store(tmp_path)
    store.create_library()
    from gaojixu import finance
    plan = finance.save_fixed_income(store, {
        "name": "工资", "amount": "8000.00", "currency": "CNY", "category": "salary-income",
        "dayOfMonth": 10, "startMonth": "2026-11", "isEnabled": True,
    })
    cash = next(row for row in store.doc["accounts"] if row["currency"] == "CNY" and not row["isArchived"])
    first = finance.confirm_fixed_income(store, {"planID": plan["id"], "month": "2026-11", "accountID": cash["id"], "receivedOn": "2026-11-10", "receivedIsConfirmed": True})
    second = finance.confirm_fixed_income(store, {"planID": plan["id"], "month": "2026-11", "accountID": cash["id"], "receivedOn": "2026-11-10", "receivedIsConfirmed": True})
    assert first["result"] == "posted" and second["result"] == "alreadyConfirmed"
    matches = [row for row in store.doc["ledgerEntries"] if row["id"] == first["ledgerID"]]
    assert len(matches) == 1 and matches[0]["amount"] == 8000
    with pytest.raises(AppError):
        finance.save_fixed_income(store, {"name": "补发", "amount": "1", "currency": "CNY", "category": "salary-income", "dayOfMonth": 1, "startMonth": "2026-10", "isEnabled": True})


def test_game_save_does_not_move_financial_time(tmp_path):
    clock = {"now": datetime(2026, 11, 15, 9, 0, tzinfo=timezone.utc)}
    store = Store(tmp_path, now=lambda: clock["now"], tz=timezone.utc, rng=random.Random(1))
    store.create_library()
    from gaojixu import adventure, finance
    cash = store.doc["accounts"][0]
    finance.save_entry(store, {"kind": "expense", "accountID": cash["id"], "amount": 8, "categoryID": "food", "note": "早餐"})
    stamp = json.loads((tmp_path / "library.json").read_text(encoding="utf-8"))["financialUpdatedAt"]
    clock["now"] = datetime(2026, 11, 16, 9, 0, tzinfo=timezone.utc)
    adventure.exchange_ticket(store)
    again = json.loads((tmp_path / "library.json").read_text(encoding="utf-8"))
    assert again["financialUpdatedAt"] == stamp
    assert again["adventure"]["coins"] == 9500
    assert again["adventure"]["tickets"] == 10001


def test_battle_draw_and_pity(tmp_path):
    class AlwaysCommon(random.Random):
        def randint(self, a, b):
            return b
        def random(self):
            return 0.99
        def randrange(self, n):
            return 0

    store = utc_store(tmp_path, rng=AlwaysCommon())
    store.create_library()
    from gaojixu import adventure
    before = store.doc["adventure"]["monsterHP"]
    outcome = adventure.battle_tick(store)
    assert outcome["dealt"] >= 1
    assert store.doc["adventure"]["monsterHP"] != before or outcome.get("defeated")
    store.doc["adventure"]["equipmentPityCounters"] = {"rare": 9, "epic": 0, "legendary": 0, "mythic": 0, "peerless": 0}
    result = adventure.draw(store, 1, "equipment")
    assert result["reveals"][0]["rarity"] >= 3
    assert store.doc["adventure"]["tickets"] == 9999


def test_csv_and_widget(tmp_path):
    store = utc_store(tmp_path)
    store.create_library()
    from gaojixu import finance
    cash = store.doc["accounts"][0]
    finance.save_entry(store, {"kind": "expense", "accountID": cash["id"], "amount": 6, "categoryID": "food", "note": "咖啡,加糖"})
    text = store.export_ledger()
    assert text.startswith("\ufeff日期,类型")
    assert "\r\n" in text
    assert '"咖啡,加糖"' in text
    widget = json.loads((tmp_path / "gaojixu-widget.json").read_text(encoding="utf-8"))
    assert widget["schemaVersion"] == 2
    assert widget["currencyCode"] == "CNY"
    assert 28 <= len(widget["days"]) <= 31
    assert widget["dataRevision"]
    other = tmp_path / "import"
    other.mkdir()
    imported = utc_store(other)
    imported.create_library()
    outcome = imported.import_ledger(text)
    assert outcome["imported"] == 1
    assert any(row["note"] == "咖啡,加糖" for row in imported.doc["ledgerEntries"])
    assert imported.import_ledger(text)["duplicates"] == 1


def test_monthly_payment_posts_once(tmp_path):
    store = utc_store(tmp_path)
    store.create_library()
    from gaojixu import monthly
    from gaojixu.store import post_monthly_to_ledger
    store.create_monthly()
    subscription = monthly.save_subscription(store.directory, {"name": "视频会员", "price": 25, "currency": "CNY", "cycle": "monthly", "interval": 1}, store.now)
    cash = store.doc["accounts"][0]["id"]
    payment = monthly.record_payment(store.directory, {"subscriptionID": subscription["id"], "due": "2026-11-15"}, store.now)
    post_monthly_to_ledger(store, payment["payment"], subscription, cash)
    with pytest.raises(AppError):
        monthly.record_payment(store.directory, {"subscriptionID": subscription["id"], "due": "2026-11-15"}, store.now)
    assert any(row["id"].startswith("auto-monthly|") for row in store.doc["ledgerEntries"])


def test_backfill_old_record_currency(tmp_path):
    moment = 810000000
    document = {
        "version": 22,
        "goals": [{
            "id": "GOAL", "title": "旧目标", "targetAmount": 100, "startingAmount": 0, "currency": "CNY",
            "deadline": moment, "symbol": "flag", "colorKey": "blue", "notes": "", "status": "active", "createdAt": moment,
        }],
        "records": [{
            "id": "REC", "goalID": "GOAL", "kind": "deposit", "amount": 5, "date": moment, "category": "other",
            "note": "", "gameRewardClaimed": True, "createdAt": moment,
        }],
        "adventure": {"level": 1, "experience": 0, "stardust": 0, "tickets": 1, "insight": 0, "monsterIndex": 0, "monsterHP": 100, "defeatedMonsters": 0, "pityCount": 0, "coins": 0},
        "equipment": [], "techniques": [], "rewardEvents": [], "drawHistory": [],
        "accounts": [], "ledgerEntries": [], "budgets": [],
    }
    (tmp_path / "library.json").write_text(json.dumps(document), encoding="utf-8")
    store = utc_store(tmp_path)
    assert store.status == "ready"
    assert store.doc["version"] == 24
    assert store.doc["records"][0]["currency"] == "CNY"


def test_http_create_and_read(tmp_path, monkeypatch):
    monkeypatch.setenv("GAOJIXU_NO_BATTLE", "1")
    store = utc_store(tmp_path)
    server = serve(store, port=0, open_browser=False)
    try:
        import urllib.request
        page = urllib.request.urlopen(server.url, timeout=5)
        body = page.read().decode("utf-8")
        assert page.status == 200
        token = body.split('name="gao-token" content="', 1)[1].split('"', 1)[0]
        assert token
        request = urllib.request.Request(server.url + "api/library/create", data=b"{}", method="POST", headers={"Content-Type": "application/json", "X-Gao-Token": token})
        urllib.request.urlopen(request, timeout=5).read()
        cash = json.loads((tmp_path / "library.json").read_text(encoding="utf-8"))["accounts"][0]["id"]
        payload = json.dumps({"kind": "expense", "accountID": cash, "amount": 3, "categoryID": "food", "note": "CI smoke ledger"}).encode("utf-8")
        request = urllib.request.Request(server.url + "api/ledger/save", data=payload, method="POST", headers={"Content-Type": "application/json", "X-Gao-Token": token})
        urllib.request.urlopen(request, timeout=5).read()
        saved = (tmp_path / "library.json").read_text(encoding="utf-8")
        assert "CI smoke ledger" in saved
        state_request = urllib.request.Request(server.url + "api/state", headers={"X-Gao-Token": token})
        state = json.loads(urllib.request.urlopen(state_request, timeout=5).read().decode("utf-8"))
        assert any(row["note"] == "CI smoke ledger" for row in state["entries"])
    finally:
        server.shutdown_requested.set()
        server.shutdown()
        server.server_close()


def test_money_half_away_from_zero():
    assert money("88.1") == money("88.10")
    assert money("1.005") == money("1.01")
    assert money("-1.005") == money("-1.01")
