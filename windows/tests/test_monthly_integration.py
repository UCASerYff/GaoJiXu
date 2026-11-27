import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.request import Request, urlopen

import pytest

from gaojixu import finance, monthly, monthly_signal
from gaojixu.errors import AppError
from gaojixu.monthly_integration import HISTORY, MonthlyIntegration
from gaojixu.store import Store, dumps
from gaojixu.web import serve

TESTS = Path(__file__).resolve().parent
NOW = datetime(2026, 11, 27, 13, tzinfo=timezone.utc)


def make_store(root):
    store = Store(root, now=lambda: NOW, tz=timezone.utc)
    store.create_library()
    store.create_monthly()
    (root / ".gaojixu-provider-fixture").touch()
    return store


def add_subscription(store, name="Synthetic streaming"):
    return monthly.save_subscription(store.directory, {"name": name, "price": 23.50,
        "currency": "CNY", "start": "2026-11-27", "anchor": "2026-11-27"}, store.now)


def run_provider(store, operation, subscription):
    subprocess.run([sys.executable, str(TESTS / "fixture_monthly_provider.py"), str(store.directory),
                    operation, subscription["id"]], check=True, capture_output=True)


def await_value(get, compare, *, seconds=5):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = get()
        if compare(value):
            return value
        time.sleep(.04)
    raise AssertionError(f"timed out waiting for synchronization: {get()!r}")


@pytest.mark.skipif(os.name != "nt", reason="Verifies Win32 event across separate processes")
def test_external_process_reconciles_only_verified_confirmed_payments(tmp_path, monkeypatch):
    monkeypatch.setenv("GAOJIXU_NO_BATTLE", "1")
    store = make_store(tmp_path)
    subscription = add_subscription(store)
    other = add_subscription(store, "Unbound synthetic plan")
    account = finance.accounts(store)[0]
    store._atomic(tmp_path / "monthly-account-bindings.json", dumps({
        "gqns.monthly.account." + subscription["id"]: account["id"],
    }))
    sample = finance.save_entry(store, {"accountID": account["id"], "kind": "expense",
        "amount": 11, "categoryID": "subscription", "date": "2026-11-27", "note": "Old imported payment"})
    sample["id"] = "auto-monthly|imported-orphan"
    store.mark_financial()
    store.save()

    server = serve(store, open_browser=False)
    auth = {"X-Gao-Token": server.token}

    def status():
        with urlopen(Request(server.url + "api/monthly/integration", headers=auth), timeout=2) as response:
            return json.load(response)

    def wake():
        request = [sys.executable, str(TESTS.parent / "launch.py"), "--data-dir", str(tmp_path),
                   "--notify-monthly-change"]
        result = subprocess.run(request, check=True, capture_output=True, text=True)
        assert result.stdout.strip() == "monthly-change-signaled"

    def apply(operation, plan, source="ready"):
        prior = status()["generation"]
        run_provider(store, operation, plan)
        wake()
        return await_value(status, lambda value: value["generation"] > prior and value["source"] == source)

    try:
        started = await_value(status, lambda value: value["source"] == "ready")
        assert started["transport"] == "windows-event"
        assert started["externalProvider"] == "unverified"
        assert store.counts()["entries"] == 1
        assert monthly_signal.signal(tmp_path / "another-profile") is False
        apply("confirm", subscription)
        identifier = f"auto-monthly|{subscription['id']}|2026-11-27"
        entry = next(row for row in finance.entries(store) if row["id"] == identifier)
        assert entry["amount"] == 23.50
        assert entry["accountID"] == account["id"]
        before = status()["generation"]
        wake()
        assert status()["generation"] == before
        apply("correct", subscription)
        updated = next(row for row in finance.entries(store) if row["id"] == identifier)
        assert updated["amount"] == 42 and updated["date"] > entry["date"]

        apply("confirm", other)
        assert store.counts()["entries"] == 2  # No same-currency account choice has been made for the other plan.
        with server.lock:
            assert any(row["subscriptionID"] == other["id"] for row in store.snapshot()["monthly"]["reconciliation"])
        apply("duplicate", subscription, "unverified")
        assert any(row["id"] == identifier and row["amount"] == 42 for row in finance.entries(store))
        apply("correct", subscription)
        apply("withdraw", subscription)
        assert [row["id"] for row in finance.entries(store)] == ["auto-monthly|imported-orphan"]
        apply("confirm", subscription)
        apply("skip", subscription)
        assert [row["id"] for row in finance.entries(store)] == ["auto-monthly|imported-orphan"]
    finally:
        server.shutdown_requested.set()
        server.shutdown()
        server.server_close()


def test_stale_monthly_sqlite_transaction_cannot_overwrite_peer(tmp_path):
    store = make_store(tmp_path)
    subscription = add_subscription(store)
    stale = monthly._require(tmp_path)
    stale["subscriptions"][0]["note"] = "Stale editor"
    run_provider(store, "confirm", subscription)
    with pytest.raises(AppError) as form_error:
        monthly.change_item(tmp_path, {"collection": "subscriptions", "operation": "delete",
            "id": subscription["id"], "expectedRevision": stale.revision}, store.now)
    assert form_error.value.code == "monthly-conflict"
    with pytest.raises(AppError) as error:
        monthly._write_state(tmp_path, stale)
    assert error.value.code == "monthly-conflict"
    assert len(monthly._require(tmp_path)["payments"]) == 1


def test_unavailable_source_and_changed_authority_leave_ledger_alone(tmp_path):
    from threading import Event, Lock

    store = make_store(tmp_path)
    subscription = add_subscription(store)
    account = finance.accounts(store)[0]
    store._atomic(tmp_path / "monthly-account-bindings.json", dumps({
        "gqns.monthly.account." + subscription["id"]: account["id"],
    }))
    run_provider(store, "confirm", subscription)
    integration = MonthlyIntegration(store, Lock(), Event())
    integration.sync()
    assert store.counts()["entries"] == 1
    assert HISTORY in json.loads((tmp_path / "monthly-reconciliation.json").read_text(encoding="utf-8"))

    run_provider(store, "incomplete", subscription)
    integration.sync()
    assert integration.state["source"] == "unverified"
    assert store.counts()["entries"] == 1
    target = monthly.directory_for(tmp_path) / "authority.json"
    original = target.read_bytes()
    target.write_text("invalid", encoding="utf-8")
    integration.sync()
    assert integration.state["source"] == "readonly"
    assert store.counts()["entries"] == 1
    target.write_bytes(original)
    database = monthly.directory_for(tmp_path) / "monthly.sqlite"
    moved = database.with_suffix(".fixture-hold")
    database.rename(moved)
    integration.sync()
    assert integration.state["source"] == "missing"
    assert store.counts()["entries"] == 1
    moved.rename(database)
    root = monthly._require(tmp_path)
    root["payments"] = []
    monthly._write_state(tmp_path, root)
    updated_authority = json.loads(original)
    updated_authority["transactionID"] = monthly.new_id()
    target.write_bytes(dumps(updated_authority))
    integration.sync()
    assert integration.state["source"] == "authority-changed"
    assert store.counts()["entries"] == 1


def test_migrated_authority_and_missing_reconciliation_history(tmp_path):
    from threading import Event, Lock

    store = make_store(tmp_path)
    subscription = add_subscription(store)
    account = finance.accounts(store)[0]
    store._atomic(tmp_path / "monthly-account-bindings.json", dumps({
        "gqns.monthly.account." + subscription["id"]: account["id"],
    }))
    authority = monthly.directory_for(tmp_path) / "authority.json"
    state = json.loads(authority.read_bytes())
    transaction = state["transactionID"]
    relative = f"IntegratedFinance/Migrations/{transaction}/committed.json"
    state.update(mode="migrated", sourceBundleID="com.gaoseries.GaoYueGong", sourceRevision="a" * 64,
        commitMarkerPath="app-group:" + relative, expectedModules=["monthly"])
    authority.write_bytes(dumps(state))
    run_provider(store, "confirm", subscription)
    integration = MonthlyIntegration(store, Lock(), Event())
    integration.sync()
    assert integration.state["source"] == "readonly"
    assert store.counts()["entries"] == 0
    store._atomic(tmp_path / relative, dumps({"schemaVersion": 1, "ownerBundleID": monthly.OWNER,
        "transactionID": transaction, "committedAt": state["activatedAt"], "modules": ["monthly"]}))
    integration.sync()
    assert integration.state["source"] == "ready"
    assert store.counts()["entries"] == 1
    (tmp_path / "monthly-reconciliation.json").unlink()
    run_provider(store, "withdraw", subscription)
    integration = MonthlyIntegration(Store(tmp_path, now=lambda: NOW, tz=timezone.utc), Lock(), Event())
    integration.sync()
    assert integration.state["source"] == "unverified"
    assert integration.store.counts()["entries"] == 1
