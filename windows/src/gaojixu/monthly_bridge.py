"""Link confirmed fixed expenses to ledger entries while leaving forecasts outside the ledger."""

import json

from gaojixu import finance, monthly
from gaojixu.errors import AppError
from gaojixu.store import dumps, post_monthly_to_ledger
from gaojixu.timeutil import read_cocoa

RECONCILIATION_FILE = "monthly-reconciliation.json"
CLEANUP_KEY = "__pendingCleanup"

def _read_metadata(store, name):
    path = store.directory / name
    if path.is_symlink():
        raise AppError("月供对账设置无法读取，原文件已保留。", "protected")
    if not path.exists():
        return {}
    try:
        values = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, ValueError) as exc:
        raise AppError("月供对账设置无法读取，原文件已保留。", "protected") from exc
    if not isinstance(values, dict):
        raise AppError("月供对账设置格式无法读取，原文件已保留。", "protected")
    return values


def _binding_key(subscription_id):
    return f"gqns.monthly.account.{subscription_id}"


def _entry(store, ident):
    return next((row for row in finance.entries(store) if row.get("id") == f"auto-monthly|{ident}"), None)


def _queue_cleanup(store, identifiers):
    new = {ident for ident in identifiers if _entry(store, ident)}
    if not new:
        return
    metadata = _read_metadata(store, RECONCILIATION_FILE)
    pending = metadata.get(CLEANUP_KEY, [])
    if not isinstance(pending, list) or not all(isinstance(ident, str) for ident in pending):
        raise AppError("待对账任务格式无法读取，原文件已保留。", "protected")
    metadata[CLEANUP_KEY] = sorted(set(pending) | new)
    store._atomic(store.directory / RECONCILIATION_FILE, dumps(metadata))


def flush_cleanup(store, monthly_view=None):
    """Only remove entries queued before a payment was explicitly withdrawn."""
    if monthly_view is not None and monthly_view.get("status") != "ready":
        return
    metadata = _read_metadata(store, RECONCILIATION_FILE)
    pending = metadata.get(CLEANUP_KEY, [])
    if not pending:
        return
    if not isinstance(pending, list) or not all(isinstance(ident, str) for ident in pending):
        raise AppError("待对账任务格式无法读取，原文件已保留。", "protected")
    if monthly_view is None:
        monthly_view = monthly._require(store.directory)
    valid = {row.get("id") for row in monthly_view.get("payments", [])
             if not row.get("skipped") and row.get("amount")}
    ledger_ids = {f"auto-monthly|{ident}" for ident in pending if ident not in valid}
    original = finance.entries(store)
    retained = [entry for entry in original if entry.get("id") not in ledger_ids]
    if len(original) != len(retained):
        store.doc["ledgerEntries"] = retained
        store.mark_financial()
        try:
            store.save()
        except OSError:
            store.doc["ledgerEntries"] = original
            raise
    del metadata[CLEANUP_KEY]
    store._atomic(store.directory / RECONCILIATION_FILE, dumps(metadata))


def _account(store, account_id, currency):
    owner = finance.account(store, account_id)
    if not owner or owner.get("isArchived") or owner.get("currency") != currency:
        raise AppError("请选择一个仍在使用、且与订阅同币种的扣款账户。", "invalid")
    return owner["id"]


def confirm(store, payload):
    store.require_ready()
    monthly_state = monthly._require(store.directory, payload.get("expectedRevision"))
    subscription = monthly._row(monthly_state, "subscriptions", payload.get("subscriptionID"))
    if not subscription:
        raise AppError("没有这项订阅。", "invalid")
    existing = _entry(store, payload.get("id")) if payload.get("id") else None
    account_id = payload.get("accountID") or (existing or {}).get("accountID")
    bindings = _read_metadata(store, "monthly-account-bindings.json")
    if not account_id and not payload.get("ledgerDeferred"):
        candidate = bindings.get(_binding_key(subscription["id"]))
        account = finance.account(store, candidate) if isinstance(candidate, str) else None
        if account and not account.get("isArchived") and account.get("currency") == (payload.get("currency") or (subscription.get("plans") or [{}])[-1].get("currency")):
            account_id = account["id"]
    if payload.get("skipped"):
        account_id = None
    def validate(payment, _subscription):
        if account_id:
            _account(store, account_id, payment["currency"])
        if payment.get("skipped") or not payment.get("amount"):
            _queue_cleanup(store, [payment["id"]])
    payment = monthly.record_payment(store.directory, payload, store.now, validate=validate)["payment"]
    ledger_id = None
    if account_id and payment.get("amount"):
        ledger_id = post_monthly_to_ledger(store, payment, subscription, account_id)
        if payload.get("rememberAccount"):
            bindings[_binding_key(subscription["id"])] = account_id
            store._atomic(store.directory / "monthly-account-bindings.json", dumps(bindings))
    elif payment.get("skipped") or not payment.get("amount"):
        flush_cleanup(store)
    return {"payment": payment, "ledgerID": ledger_id}


def change_item(store, payload):
    store.require_ready()
    state = monthly._require(store.directory, payload.get("expectedRevision"))
    collection, operation = payload.get("collection"), payload.get("operation")
    current = monthly._row(state, collection, payload.get("id"))
    effects = []
    if operation == "delete" and current:
        if collection == "subscriptions":
            effects = [row["id"] for row in state.get("payments", []) if row.get("subscriptionID") == current["id"]]
        elif collection == "payments":
            effects = [current["id"]]
    _queue_cleanup(store, effects)
    row = monthly.change_item(store.directory, payload, store.now)
    if effects:
        flush_cleanup(store)
    return row


def pending(store, monthly_view):
    if store.status != "ready" or monthly_view.get("status") != "ready":
        return []
    try:
        ignored = _read_metadata(store, RECONCILIATION_FILE)
    except AppError:
        ignored = {}
    subscriptions = {row.get("id"): row for row in monthly_view.get("subscriptions", [])}
    existing = {row.get("id"): row for row in finance.entries(store) if str(row.get("id", "")).startswith("auto-monthly|")}
    pending_rows = []
    for payment in monthly_view.get("payments", []):
        ledger = existing.get(f"auto-monthly|{payment.get('id')}")
        if ledger:
            payment["accountID"] = ledger.get("accountID")
    for payment in monthly_view.get("payments", []):
        identifier = payment.get("id")
        entry = existing.get(f"auto-monthly|{identifier}")
        subscription = subscriptions.get(payment.get("subscriptionID"), {})
        name = subscription.get("name") or "订阅"
        if payment.get("skipped") or not payment.get("amount") or ignored.get(identifier):
            continue
        account = finance.account(store, entry.get("accountID")) if entry else None
        if (not entry or entry.get("kind") != "expense" or entry.get("categoryID") != "subscription" or
                not account or account.get("currency") != payment.get("currency") or
                entry.get("amount") != payment.get("amount") or
                str(entry.get("note")) != f"月供·{name}" or
                _ledger_day(entry, store, monthly_view) != payment.get("paidAt")):
            pending_rows.append({**payment, "name": name, "accountID": (entry or {}).get("accountID")})
    return pending_rows


def _ledger_day(entry, store, view):
    when = read_cocoa(entry.get("date"), monthly.business_zone(view, store.tz))
    return when.date().isoformat() if when else ""


def reconcile(store, payload):
    store.require_ready()
    state = monthly._require(store.directory, payload.get("expectedRevision"))
    payment = monthly._row(state, "payments", payload.get("id"))
    if not payment or payment.get("skipped") or not payment.get("amount"):
        raise AppError("这笔已确认的支付已变化。", "conflict")
    if payload.get("ignore"):
        ignored = _read_metadata(store, RECONCILIATION_FILE)
        ignored[payment["id"]] = True
        store._atomic(store.directory / RECONCILIATION_FILE, dumps(ignored))
        return {"ignored": True}
    plan = monthly._row(state, "subscriptions", payment.get("subscriptionID"))
    if not plan:
        raise AppError("这项订阅已变化。", "conflict")
    result = post_monthly_to_ledger(store, payment, plan, payload.get("accountID"))
    return {"ledgerID": result}
