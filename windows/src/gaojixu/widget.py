"""schema 2 财务快照。Windows 没有 WidgetKit，文件写在资料目录里。"""

from __future__ import annotations

import json
import uuid
from pathlib import Path

from gaojixu import finance
from gaojixu.money import money, money_number
from gaojixu.timeutil import cocoa_json, in_zone, month_key, month_title, start_of_day
from gaojixu.version import MARKETING_VERSION, WIDGET_SCHEMA_VERSION, WINDOWS_BUILD


def publish(store) -> None:
    if store.status != "ready" or not store.financial_revision:
        return
    payload = build(store)
    raw = json.dumps(payload, ensure_ascii=False, sort_keys=True).encode("utf-8")
    for path in targets(store.directory):
        _write_if_compatible(path, raw)


def targets(directory: Path):
    return [
        directory / "IsolatedWidgetGroup" / "gaojixu-widget.json",
        directory / "gaojixu-widget.json",
    ]


def build(store) -> dict:
    currency = store.currency if store.currency in {"CNY", "USD", "EUR", "GBP", "JPY", "HKD", "TWD", "KRW", "SGD", "AUD", "CAD"} else "CNY"
    symbol = {"CNY": "¥", "USD": "$", "EUR": "€", "GBP": "£", "JPY": "¥", "HKD": "$", "TWD": "$", "KRW": "₩", "SGD": "$", "AUD": "$", "CAD": "$"}[currency]
    now = store.now()
    local = in_zone(now, store.tz)
    month_start = local.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    days = finance.daily_summary(store, currency, now)
    movements = []
    for entry in finance.entries(store):
        if entry.get("kind") == "transfer" or entry.get("categoryID") == "balance-adjustment":
            continue
        owner = finance.account(store, entry.get("accountID"))
        if not owner or owner.get("currency") != currency:
            continue
        movements.append({
            "date": entry.get("date"),
            "expense": money_number(entry.get("amount")) if entry.get("kind") == "expense" else 0,
            "income": money_number(entry.get("amount")) if entry.get("kind") == "income" else 0,
            "saving": 0,
        })
    goal_currency = {row.get("id"): row.get("currency") for row in finance.goals(store)}
    for record in finance.records(store):
        if goal_currency.get(record.get("goalID")) != currency:
            continue
        signed = money_number(record.get("amount"))
        movements.append({
            "date": record.get("date"),
            "expense": 0,
            "income": 0,
            "saving": signed if record.get("kind") == "deposit" else money_number(-money(record.get("amount"))),
        })
    budget_rows = [
        {"monthKey": row.get("monthKey"), "amount": money_number(row.get("amount"))}
        for row in finance.budgets(store) if row.get("currency") == currency
    ]
    key = month_key(now, store.tz)
    budget_total = money(0)
    for row in budget_rows:
        if row["monthKey"] == key:
            budget_total += money(row["amount"])
    spent = money(0)
    for day in days:
        spent += money(day["expense"])
    accounts = []
    for row in finance.net_worth_accounts(store, currency):
        accounts.append({
            "balance": finance.net_worth_contribution(store, row),
            "id": row.get("id"),
            "name": row.get("name"),
            "symbol": row.get("symbol") or "tray.full.fill",
        })
    payload = {
        "accounts": accounts,
        "calendarIdentifier": "gregorian",
        "currency": currency,
        "currencyCode": currency,
        "currencySymbol": symbol,
        "dataRevision": store.financial_revision,
        "days": days,
        "monthStart": cocoa_json(month_start),
        "monthTitle": month_title(now, store.tz),
        "netWorth": finance.net_worth(store, currency),
        "projection": {"budgets": budget_rows, "movements": movements},
        "revision": str(uuid.uuid4()).upper(),
        "schemaVersion": WIDGET_SCHEMA_VERSION,
        "timeZoneIdentifier": getattr(store.tz, "key", None) or "UTC",
        "updatedAt": cocoa_json(now),
        "writerBuild": WINDOWS_BUILD,
        "writerVersion": MARKETING_VERSION,
    }
    if budget_total > 0:
        payload["budgetSpent"] = money_number(spent)
        payload["budgetTotal"] = money_number(budget_total)
    if store.financial_updated_at is not None:
        payload["dataUpdatedAt"] = cocoa_json(store.financial_updated_at)
    if store.source_saved_at is not None:
        payload["sourceSavedAt"] = cocoa_json(store.source_saved_at)
    return payload


def _write_if_compatible(path: Path, raw: bytes) -> None:
    if path.exists():
        try:
            current = json.loads(path.read_text(encoding="utf-8"))
            schema = current.get("schemaVersion") if isinstance(current, dict) else None
            if isinstance(schema, int) and schema > WIDGET_SCHEMA_VERSION:
                return
        except (OSError, json.JSONDecodeError):
            pass
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_bytes(raw)
    temporary.replace(path)
