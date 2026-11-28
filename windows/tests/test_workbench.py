from datetime import datetime, timedelta, timezone

import pytest

from gaojixu import monthly
from gaojixu.desktop import RunningInstance, target_for
from gaojixu.errors import AppError
from gaojixu.monthly_notices import due_notices
from gaojixu.store import Store
from gaojixu.timeutil import cocoa_json
from gaojixu.web import dispatch, serve


def test_monthly_forecast_keeps_paid_history_through_plan_changes(tmp_path):
    now = datetime(2026, 11, 27, 10, tzinfo=timezone.utc)
    store = Store(tmp_path / "资料 #20", tz=timezone.utc, now=lambda: now)
    store.create_library()
    store.create_monthly()
    root = store.directory
    original = {"name": "测试月供", "price": "20.00", "currency": "CNY", "cycle": "monthly",
                "monthEnd": True, "start": "2026-08-31", "anchor": "2026-08-31"}
    subscription = monthly.save_subscription(root, original, store.now)
    monthly.save_subscription(root, {**original, "id": subscription["id"], "price": 35,
                                     "effective": "2026-11-01"}, store.now)
    summary = store.snapshot()["monthly"]
    october = next(bill for bill in summary["bills"] if bill["due"] == "2026-10-31")
    november = next(bill for bill in summary["bills"] if bill["due"] == "2026-11-30")
    assert october["price"] == 20 and november["price"] == 35
    assert store.counts()["entries"] == 0
    with pytest.raises(AppError):
        dispatch(store, "/api/monthly/pay", {**october, "billID": october["id"], "id": None, "accountID": "missing"})
    assert not store.snapshot()["monthly"]["payments"]

    payload = {**october, "billID": october["id"], "id": None, "paidAt": "2026-10-31"}
    payment = dispatch(store, "/api/monthly/pay", payload)["payment"]
    assert store.counts()["entries"] == 0
    pending, = store.snapshot()["monthly"]["reconciliation"]
    cash = store.snapshot()["accounts"][0]["id"]
    dispatch(store, "/api/monthly/reconcile", {"id": pending["id"], "accountID": cash})
    assert store.counts()["entries"] == 1
    assert not store.snapshot()["monthly"]["reconciliation"]
    dispatch(store, "/api/monthly/pay", {**payload, "billID": None, "id": payment["id"], "amount": "18.20"})
    assert store.snapshot()["entries"][0]["amount"] == 18.20
    dispatch(store, "/api/monthly/change", {"collection": "payments", "operation": "delete", "id": payment["id"]})
    assert store.counts()["entries"] == 0


def test_recurring_expenses_preserve_legacy_benefits(tmp_path):
    now = datetime(2026, 11, 27, 10, tzinfo=timezone.utc)
    store = Store(tmp_path, tz=timezone.utc, now=lambda: now)
    store.create_library()
    store.create_monthly()
    details = {"name": "测试月供", "price": 25, "currency": "CNY", "start": "2026-11-26"}
    sub = monthly.save_subscription(tmp_path, details, store.now)
    monthly.update_preferences(tmp_path, {"notifications": True, "privacy": True, "reminderHour": 9}, store.now)
    monthly.save_event(tmp_path, {"name": "私密事项", "deadline": "2026-11-27T09:30"}, store.now)
    state = monthly._require(tmp_path)
    legacy_sub = state["subscriptions"][0]
    legacy_sub["plans"][0]["benefit"] = "daily"
    legacy_sub["serviceEnd"] = cocoa_json(now + timedelta(days=5))
    legacy_id = monthly.new_id()
    benefit = {"id": legacy_id, "name": "旧权益", "kind": "daily", "createdAt": cocoa_json(now),
               "subscriptionID": sub["id"], "archived": False, "note": "历史记录"}
    claim = {"id": f"{legacy_id}|daily|2026-11-27", "subscriptionID": sub["id"],
             "date": cocoa_json(now), "recordedAt": cocoa_json(now), "backfill": False}
    state["benefits"], state["claims"] = [benefit], [claim]
    monthly._save(tmp_path, state, store.now)

    database = monthly.directory_for(tmp_path) / "monthly.sqlite"
    original = database.read_bytes()
    view = store.snapshot()["monthly"]
    assert "benefits" not in view and "claims" not in view
    assert view["subscriptions"][0]["usage"]["score"] is None
    for endpoint, payload in (("benefit", benefit), ("claim", claim),
                              ("change", {"collection": "claims", "operation": "delete", "id": claim["id"]})):
        with pytest.raises(AppError):
            dispatch(store, f"/api/monthly/{endpoint}", payload)
    assert database.read_bytes() == original

    notices = due_notices(state, now, timezone.utc, now - timedelta(hours=2))
    assert [body for _due, _key, body in notices] == ["有到期事项待处理。"]
    saved = dispatch(store, "/api/monthly/subscription", {**details, "id": sub["id"], "serviceEnd": "", "note": "编辑"})
    assert saved["serviceEnd"] == legacy_sub["serviceEnd"]
    assert len(saved["plans"]) == 1 and saved["plans"][0]["benefit"] == "daily"
    monthly.save_review(tmp_path, {"subscriptionID": sub["id"], "month": "2026-11", "rating": 2}, store.now)
    reopened = Store(tmp_path, tz=timezone.utc, now=lambda: now)
    assert reopened.snapshot()["monthly"]["subscriptions"][0]["usage"]["score"] == 2
    active = monthly._require(tmp_path)
    assert active["claims"] == [claim] and active["benefits"] == [benefit]
    dispatch(store, "/api/monthly/change", {"collection": "subscriptions", "operation": "delete", "id": sub["id"]})
    active = monthly._require(tmp_path)
    assert active["claims"] == [{**claim, "subscriptionID": legacy_id}]
    assert active["benefits"] == [{key: value for key, value in benefit.items() if key != "subscriptionID"}]


def test_deeplink_targets_and_single_running_server(tmp_path, monkeypatch):
    monkeypatch.setattr("gaojixu.desktop.tempfile.gettempdir", lambda: str(tmp_path))
    assert target_for("gaojixu://today") == "#fixed-expenses"
    assert target_for("gaojixu://benefits") == "#fixed-expenses"
    assert target_for("gaojixu://widgets?type=benefits") == "?widget=expenses"
    assert target_for(None, "benefits") == "?widget=expenses"
    with pytest.raises(ValueError):
        target_for("gaojixu://unavailable")
    store = Store(tmp_path / "isolated-data")
    first = RunningInstance(store.directory)
    duplicate = RunningInstance(store.directory)
    assert first.acquire()
    assert not duplicate.acquire()
    server = serve(store, open_browser=False, instance_key=first.key)
    try:
        first.publish(server.server_address[1])
        assert duplicate.running_url() == server.url
    finally:
        server.shutdown_requested.set()
        server.shutdown()
        server.server_close()
        first.close()
    assert duplicate.acquire()
    duplicate.close()


def test_interrupted_monthly_removal_repairs_on_next_open(tmp_path, monkeypatch):
    now = datetime(2026, 11, 27, 10, tzinfo=timezone.utc)
    store = Store(tmp_path, tz=timezone.utc, now=lambda: now)
    store.create_library()
    store.create_monthly()
    sub = monthly.save_subscription(tmp_path, {"name": "跨库存档测试", "price": 25, "currency": "CNY"}, store.now)
    snapshot = store.snapshot()
    bill, *_ = snapshot["monthly"]["bills"]
    result = dispatch(store, "/api/monthly/pay", {
        "billID": bill["id"], "due": bill["due"], "subscriptionID": sub["id"], "accountID": snapshot["accounts"][0]["id"]
    })
    assert store.counts()["entries"] == 1

    def unavailable():
        raise PermissionError("synthetic ledger write failure")

    monkeypatch.setattr(store, "save", unavailable)
    with pytest.raises(PermissionError):
        dispatch(store, "/api/monthly/change", {
            "collection": "payments", "operation": "delete", "id": result["payment"]["id"]
        })
    assert monthly._require(tmp_path)["payments"] == []
    recovered = Store(tmp_path, tz=timezone.utc, now=lambda: now)
    assert recovered.counts()["entries"] == 1
    assert recovered.snapshot()["summary"]["monthExpense"] == 0
    assert recovered.counts()["entries"] == 0
    reread = Store(tmp_path, tz=timezone.utc, now=lambda: now)
    assert reread.counts()["entries"] == 0


def test_damaged_monthly_authority_keeps_ledger_available(tmp_path):
    now = datetime(2026, 11, 27, 10, tzinfo=timezone.utc)
    store = Store(tmp_path, tz=timezone.utc, now=lambda: now)
    store.create_library()
    store.create_monthly()
    authority = monthly.directory_for(tmp_path) / "authority.json"
    broken = b"\xFF\xFE"
    authority.write_bytes(broken)
    snapshot = store.snapshot()
    assert snapshot["status"] == "ready"
    assert snapshot["monthly"]["status"] == "readonly"
    with pytest.raises(AppError):
        monthly.save_subscription(tmp_path, {"name": "不可写入", "price": 10}, store.now)
    assert authority.read_bytes() == broken
