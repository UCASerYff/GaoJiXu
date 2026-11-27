"""账户、流水、预算、周期记账、攒钱目标和固定收入。"""

from __future__ import annotations

import hashlib
import json
import uuid

from gaojixu import adventure, catalog
from gaojixu.errors import AppError
from gaojixu.money import currency_digits, money, money_number, valid_fixed_amount
from gaojixu.timeutil import (
    add_days,
    add_months,
    cocoa_json,
    format_minute,
    in_zone,
    month_key,
    parse_instant,
    parse_month_key,
    read_cocoa,
    same_day,
    same_month,
    start_of_day,
)


def new_id() -> str:
    return str(uuid.uuid4()).upper()


def accounts(store) -> list:
    rows = store.doc.get("accounts")
    return rows if isinstance(rows, list) else []


def entries(store) -> list:
    rows = store.doc.get("ledgerEntries")
    return rows if isinstance(rows, list) else []


def goals(store) -> list:
    rows = store.doc.get("goals")
    return rows if isinstance(rows, list) else []


def records(store) -> list:
    rows = store.doc.get("records")
    return rows if isinstance(rows, list) else []


def budgets(store) -> list:
    rows = store.doc.get("budgets")
    return rows if isinstance(rows, list) else []


def rules(store) -> list:
    rows = store.doc.get("recurringRules")
    return rows if isinstance(rows, list) else []


def plans(store) -> list:
    rows = store.doc.get("fixedIncomePlans")
    return rows if isinstance(rows, list) else []


def receipts(store) -> list:
    rows = store.doc.get("fixedIncomeReceipts")
    return rows if isinstance(rows, list) else []


def account(store, account_id):
    if not account_id:
        return None
    return next((row for row in accounts(store) if row.get("id") == account_id), None)


def active_accounts(store):
    rows = [row for row in accounts(store) if not row.get("isArchived")]
    rows.sort(key=lambda row: float(row.get("createdAt") or 0))
    return rows


def _when(store, row, key="date"):
    return read_cocoa(row.get(key), store.tz)


def account_balance(store, row) -> float:
    total = money(row.get("openingBalance"))
    liability = catalog.ACCOUNT_TYPES.get(row.get("type"), ("", "", False))[2]
    for entry in entries(store):
        amount = money(entry.get("amount"))
        target_amount = money(entry.get("targetAmount")) if entry.get("targetAmount") is not None else amount
        kind = entry.get("kind")
        if liability:
            if entry.get("accountID") == row.get("id"):
                if kind == "expense":
                    total += amount
                elif kind in {"income", "transfer"}:
                    total -= amount
            elif kind == "transfer" and entry.get("targetAccountID") == row.get("id"):
                total -= target_amount
        else:
            if entry.get("accountID") == row.get("id"):
                if kind in {"expense", "transfer"}:
                    total -= amount
                elif kind == "income":
                    total += amount
            elif kind == "transfer" and entry.get("targetAccountID") == row.get("id"):
                total += target_amount
    return money_number(total)


def net_worth_contribution(store, row) -> float:
    balance = account_balance(store, row)
    if catalog.ACCOUNT_TYPES.get(row.get("type"), ("", "", False))[2]:
        return money_number(-money(balance))
    return balance


def net_worth(store, currency: str) -> float:
    total = money(0)
    for row in accounts(store):
        if row.get("currency") == currency and row.get("includeInNetWorth") and not row.get("isArchived"):
            total += money(net_worth_contribution(store, row))
    return money_number(total)


def net_worth_accounts(store, currency: str):
    rows = [row for row in active_accounts(store) if row.get("currency") == currency and row.get("includeInNetWorth")]
    rows.sort(key=lambda row: (-net_worth_contribution(store, row), float(row.get("createdAt") or 0)))
    return rows


def _in_month(store, row, moment):
    when = _when(store, row)
    return when is not None and same_month(when, moment, store.tz)


def month_income(store, currency: str, moment=None) -> float:
    moment = moment or store.now()
    total = money(0)
    for entry in entries(store):
        if entry.get("kind") != "income" or entry.get("categoryID") == "balance-adjustment":
            continue
        owner = account(store, entry.get("accountID"))
        if owner and owner.get("currency") == currency and _in_month(store, entry, moment):
            total += money(entry.get("amount"))
    return money_number(total)


def month_expense(store, currency: str, moment=None) -> float:
    moment = moment or store.now()
    total = money(0)
    for entry in entries(store):
        if entry.get("kind") != "expense" or entry.get("categoryID") == "balance-adjustment":
            continue
        owner = account(store, entry.get("accountID"))
        if owner and owner.get("currency") == currency and _in_month(store, entry, moment):
            total += money(entry.get("amount"))
    return money_number(total)


def category_expense(store, category_id: str, key: str, currency: str) -> float:
    total = money(0)
    for entry in entries(store):
        when = _when(store, entry)
        owner = account(store, entry.get("accountID"))
        if entry.get("kind") == "expense" and entry.get("categoryID") == category_id and when and month_key(when, store.tz) == key and owner and owner.get("currency") == currency:
            total += money(entry.get("amount"))
    return money_number(total)


def goal_balance(store, goal) -> float:
    total = money(goal.get("startingAmount"))
    for record in records(store):
        if record.get("goalID") != goal.get("id"):
            continue
        signed = money(record.get("amount"))
        total += signed if record.get("kind") == "deposit" else -signed
    return money_number(max(money(0), total))


def _sort_entries(store):
    store.doc["ledgerEntries"] = sorted(entries(store), key=lambda row: float(row.get("date") or 0), reverse=True)


def _sort_records(store):
    store.doc["records"] = sorted(records(store), key=lambda row: float(row.get("date") or 0), reverse=True)


def _insert_entry(store, entry: dict):
    rows = entries(store)
    rows.append(entry)
    store.doc["ledgerEntries"] = rows
    _sort_entries(store)


def save_account(store, payload: dict) -> dict:
    store.require_ready()
    name = str(payload.get("name") or "").strip()
    if not name:
        raise AppError("请填写账户名称。", "invalid")
    account_type = payload.get("type") or "cash"
    if account_type not in catalog.ACCOUNT_TYPES:
        raise AppError("账户类型无法识别。", "invalid")
    currency = payload.get("currency") or store.currency
    if currency not in catalog.CURRENCIES:
        raise AppError("币种无法识别。", "invalid")
    try:
        balance = float(payload.get("balance"))
    except (TypeError, ValueError):
        raise AppError("账户余额必须是有效的非负数字。", "invalid")
    if balance != balance or balance < 0:
        raise AppError("账户余额必须是有效的非负数字。", "invalid")
    target = money(balance)
    existing_id = payload.get("id")
    row = account(store, existing_id) if existing_id else None
    if row is None:
        row = {
            "id": new_id(),
            "name": name,
            "type": account_type,
            "currency": currency,
            "openingBalance": 0,
            "symbol": catalog.ACCOUNT_TYPES[account_type][1],
            "colorKey": payload.get("colorKey") or "green",
            "includeInNetWorth": bool(payload.get("includeInNetWorth", True)),
            "isArchived": False,
            "createdAt": cocoa_json(store.now()),
        }
        accounts(store).append(row)
        store.doc["accounts"] = accounts(store)
    else:
        row["name"] = name
        row["type"] = account_type
        row["currency"] = currency
        row["symbol"] = catalog.ACCOUNT_TYPES[account_type][1]
        row["includeInNetWorth"] = bool(payload.get("includeInNetWorth", True))
        if payload.get("colorKey"):
            row["colorKey"] = payload["colorKey"]
    previous = money(account_balance(store, row))
    change = target - previous
    notice = ""
    if change != 0:
        liability = catalog.ACCOUNT_TYPES[account_type][2]
        raises = change > 0
        kind = "income" if (raises != liability) else "expense"
        symbol = catalog.CURRENCIES[currency][1]
        note = f"账户余额调整：{symbol}{money_number(previous):g} → {symbol}{money_number(target):g}"
        _insert_entry(store, {
            "id": new_id(),
            "kind": kind,
            "accountID": row["id"],
            "amount": money_number(abs(change)),
            "categoryID": "balance-adjustment",
            "date": cocoa_json(store.now()),
            "note": note,
            "createdAt": cocoa_json(store.now()),
        })
        notice = "账户余额已更新，并在记账中生成一笔余额调整记录。"
    store.mark_financial()
    store.save()
    if notice:
        store.notice = notice
    return row


def delete_account(store, account_id: str) -> dict:
    store.require_ready()
    row = account(store, account_id)
    if row is None:
        raise AppError("没有这个账户。", "invalid")
    used = any(entry.get("accountID") == account_id or entry.get("targetAccountID") == account_id for entry in entries(store))
    if used:
        row["isArchived"] = True
        store.notice = "有流水的账户已归档，以保留账本完整性。"
    else:
        store.doc["accounts"] = [item for item in accounts(store) if item.get("id") != account_id]
        store.notice = "账户已删除。"
    store.mark_financial()
    store.save()
    return {"archived": used}


def save_entry(store, payload: dict) -> dict:
    store.require_ready()
    existing_id = payload.get("id")
    existing = next((row for row in entries(store) if row.get("id") == existing_id), None) if existing_id else None
    if existing and existing.get("categoryID") == "balance-adjustment":
        raise AppError("余额调整记录请在资产账户中通过再次修改余额更正。", "invalid")
    if existing and any(record.get("ledgerEntryID") == existing_id for record in records(store)):
        raise AppError("积蓄计划生成的转账请在“积蓄记录”中编辑。", "invalid")
    kind = payload.get("kind")
    if kind not in {"expense", "income", "transfer"}:
        raise AppError("请选择收入、支出或转账。", "invalid")
    try:
        amount = float(payload.get("amount"))
    except (TypeError, ValueError):
        amount = 0
    if amount != amount or amount <= 0:
        raise AppError("金额必须大于 0。", "invalid")
    source = account(store, payload.get("accountID")) or next((row for row in active_accounts(store) if row.get("name") == payload.get("accountName")), None)
    if source is None or source.get("isArchived"):
        raise AppError("请选择有效账户。", "invalid")
    clean_target = None
    clean_target_amount = None
    if kind == "transfer":
        target = account(store, payload.get("targetAccountID")) or next((row for row in active_accounts(store) if row.get("name") == payload.get("targetAccountName")), None)
        if target is None or target.get("id") == source.get("id") or target.get("isArchived"):
            raise AppError("请选择不同的转入账户。", "invalid")
        clean_target = target["id"]
        if target.get("currency") == source.get("currency"):
            clean_target_amount = amount
        else:
            try:
                target_amount = float(payload.get("targetAmount"))
            except (TypeError, ValueError):
                target_amount = 0
            if target_amount != target_amount or target_amount <= 0:
                raise AppError("跨币种转账需要填写实际转入金额。", "invalid")
            clean_target_amount = target_amount
    category = "account-transfer" if kind == "transfer" else (payload.get("categoryID") or "")
    if kind != "transfer" and category not in catalog.CATEGORY_BY_ID:
        raise AppError("请选择分类。", "invalid")
    if kind != "transfer" and catalog.CATEGORY_BY_ID[category][2] != kind:
        raise AppError("分类与收支方向不一致。", "invalid")
    when = parse_instant(payload["date"], store.tz) if payload.get("date") else store.now()
    note = str(payload.get("note") or "").strip()
    normalized = money_number(amount)
    if existing:
        existing["kind"] = kind
        existing["accountID"] = source["id"]
        if clean_target:
            existing["targetAccountID"] = clean_target
        else:
            existing.pop("targetAccountID", None)
        existing["amount"] = normalized
        if clean_target_amount is not None:
            existing["targetAmount"] = money_number(clean_target_amount)
        else:
            existing.pop("targetAmount", None)
        existing["categoryID"] = category
        existing["date"] = cocoa_json(when)
        existing["note"] = note
        row = existing
    else:
        row = {
            "id": new_id(),
            "kind": kind,
            "accountID": source["id"],
            "amount": normalized,
            "categoryID": category,
            "date": cocoa_json(when),
            "note": note,
            "createdAt": cocoa_json(store.now()),
        }
        if clean_target:
            row["targetAccountID"] = clean_target
        if clean_target_amount is not None:
            row["targetAmount"] = money_number(clean_target_amount)
        _insert_entry(store, row)
    store.doc["lastLedgerAccountID"] = source["id"]
    _sort_entries(store)
    store.mark_financial()
    store.save()
    return row


def delete_entry(store, entry_id: str) -> None:
    store.require_ready()
    row = next((item for item in entries(store) if item.get("id") == entry_id), None)
    if row is None:
        raise AppError("没有这笔账。", "invalid")
    if row.get("categoryID") == "balance-adjustment":
        raise AppError("余额调整记录请在资产账户中通过再次修改余额更正。", "invalid")
    if any(record.get("ledgerEntryID") == entry_id for record in records(store)):
        raise AppError("这笔转账由积蓄计划管理，请在“积蓄记录”中删除。", "invalid")
    if str(entry_id).startswith("auto-monthly|") or str(entry_id).startswith("fixed-income|"):
        store.notice = "这笔账已删除。确认回执仍保留，不会再次自动入账。"
    else:
        store.notice = "这笔账已删除。日常记账不结算游戏货币。"
    store.doc["ledgerEntries"] = [item for item in entries(store) if item.get("id") != entry_id]
    store.mark_financial()
    store.save()


def save_budget(store, payload: dict) -> None:
    save_budgets(store, {**payload, "amounts": {payload.get("categoryID"): payload.get("amount")}})


def save_budgets(store, payload: dict) -> None:
    store.require_ready()
    key = payload.get("monthKey") or month_key(store.now(), store.tz)
    if parse_month_key(key) is None:
        raise AppError("请选择有效月份。", "invalid")
    currency = payload.get("currency") or store.currency
    if currency not in catalog.CURRENCIES:
        raise AppError("币种无法识别。", "invalid")
    amounts = payload.get("amounts")
    if not isinstance(amounts, dict):
        raise AppError("请填写分类预算。", "invalid")
    changed = {}
    for category_id, value in amounts.items():
        if category_id not in catalog.CATEGORY_BY_ID or catalog.CATEGORY_BY_ID[category_id][2] != "expense":
            raise AppError("预算只对应支出分类。", "invalid")
        changed[category_id] = money(value)
    rows = []
    written = set()
    for row in budgets(store):
        category_id = row.get("categoryID")
        if row.get("monthKey") != key or row.get("currency") != currency or category_id not in changed:
            rows.append(row)
        elif changed[category_id] > 0 and category_id not in written:
            rows.append({**row, "amount": money_number(changed[category_id])})
            written.add(category_id)
    for category_id, amount in changed.items():
        if category_id not in written and amount > 0:
            rows.append({"id": f"{key}-{currency}-{category_id}", "monthKey": key, "categoryID": category_id,
                         "currency": currency, "amount": money_number(amount)})
    store.doc["budgets"] = rows
    store.mark_financial()
    store.save()


def save_rule(store, payload: dict) -> dict:
    store.require_ready()
    kind = payload.get("kind")
    if kind not in {"income", "expense"}:
        raise AppError("周期记账只支持收入或支出。", "invalid")
    amount = money(payload.get("amount"))
    if amount <= 0:
        raise AppError("金额必须大于 0。", "invalid")
    source = account(store, payload.get("accountID"))
    if source is None or source.get("isArchived"):
        raise AppError("请选择有效账户。", "invalid")
    category_id = payload.get("categoryID")
    if category_id not in catalog.CATEGORY_BY_ID or catalog.CATEGORY_BY_ID[category_id][2] != kind:
        raise AppError("请选择分类。", "invalid")
    frequency = payload.get("frequency")
    if frequency not in {"daily", "weekly", "monthly", "yearly"}:
        raise AppError("请选择周期。", "invalid")
    due = parse_instant(payload.get("nextDueDate"), store.tz) if payload.get("nextDueDate") else store.now()
    row = {
        "id": str(payload.get("id") or new_id()).upper(),
        "kind": kind,
        "amount": money_number(amount),
        "accountID": source["id"],
        "categoryID": category_id,
        "note": str(payload.get("note") or ""),
        "frequency": frequency,
        "nextDueDate": cocoa_json(due),
        "isEnabled": bool(payload.get("isEnabled", True)),
    }
    replaced = False
    for index, item in enumerate(rules(store)):
        if str(item.get("id", "")).upper() == row["id"]:
            rules(store)[index] = {**item, **row}
            replaced = True
            row = rules(store)[index]
            break
    if not replaced:
        store.doc.setdefault("recurringRules", [])
        store.doc["recurringRules"].append(row)
    store.mark_financial()
    store.save()
    return row


def delete_rule(store, rule_id: str) -> None:
    store.require_ready()
    store.doc["recurringRules"] = [row for row in rules(store) if str(row.get("id", "")).upper() != str(rule_id).upper()]
    store.mark_financial()
    store.save()


def toggle_rule(store, rule_id: str) -> dict:
    store.require_ready()
    for row in rules(store):
        if str(row.get("id", "")).upper() == str(rule_id).upper():
            row["isEnabled"] = not bool(row.get("isEnabled"))
            store.mark_financial()
            store.save()
            return row
    raise AppError("没有这条周期规则。", "invalid")


def advance_due(store, due, frequency: str, anchor_day: int):
    if frequency == "daily":
        return add_days(due, 1, store.tz)
    if frequency == "weekly":
        return add_days(due, 7, store.tz)
    if frequency == "monthly":
        return add_months(due, 1, anchor_day, store.tz)
    return add_months(due, 12, anchor_day, store.tz)


def materialize_recurring(store, as_of=None) -> int:
    if store.doc is None:
        return 0
    as_of = as_of or store.now()
    generated = 0
    for rule in rules(store):
        if not rule.get("isEnabled"):
            continue
        due = read_cocoa(rule.get("nextDueDate"), store.tz)
        if due is None:
            continue
        anchor = in_zone(due, store.tz).day
        iterations = 0
        while due <= as_of and iterations < 366:
            entry = {
                "id": new_id(),
                "kind": rule.get("kind"),
                "accountID": rule.get("accountID"),
                "amount": money_number(rule.get("amount")),
                "categoryID": rule.get("categoryID"),
                "date": cocoa_json(due),
                "note": rule.get("note") or "",
                "createdAt": cocoa_json(store.now()),
                "recurringRuleID": rule.get("id"),
            }
            _insert_entry(store, entry)
            due = advance_due(store, due, rule.get("frequency"), anchor)
            rule["nextDueDate"] = cocoa_json(due)
            iterations += 1
            generated += 1
    if generated:
        _sort_entries(store)
        store.mark_financial()
        store.save()
    return generated


def save_goal(store, payload: dict) -> dict:
    store.require_ready()
    title = str(payload.get("title") or "").strip()
    if not title:
        raise AppError("请填写目标名称。", "invalid")
    target = money(payload.get("targetAmount"))
    starting = money(payload.get("startingAmount") or 0)
    if target <= 0:
        raise AppError("目标金额必须大于 0。", "invalid")
    if starting < 0:
        raise AppError("初始金额不能小于 0。", "invalid")
    currency = payload.get("currency") or store.currency
    if currency not in catalog.CURRENCIES:
        raise AppError("币种无法识别。", "invalid")
    deadline = parse_instant(payload.get("deadline"), store.tz) if payload.get("deadline") else add_months(store.now(), 6, in_zone(store.now(), store.tz).day, store.tz)
    savings_id = payload.get("savingsAccountID")
    savings = account(store, savings_id)
    if savings and (savings.get("isArchived") or savings.get("currency") != currency):
        savings = None
    existing = next((row for row in goals(store) if row.get("id") == payload.get("id")), None) if payload.get("id") else None
    if existing:
        existing.update({
            "title": title,
            "targetAmount": money_number(target),
            "startingAmount": money_number(starting),
            "currency": currency,
            "deadline": cocoa_json(deadline),
            "symbol": payload.get("symbol") or existing.get("symbol") or "flag.checkered",
            "colorKey": payload.get("colorKey") or existing.get("colorKey") or "blue",
            "notes": str(payload.get("notes") or "").strip(),
        })
        if savings:
            existing["savingsAccountID"] = savings["id"]
        elif "savingsAccountID" in payload:
            existing.pop("savingsAccountID", None)
        _refresh_goal(store, existing)
        row = existing
    else:
        completed = starting >= target
        row = {
            "id": new_id(),
            "title": title,
            "targetAmount": money_number(target),
            "startingAmount": money_number(starting),
            "currency": currency,
            "deadline": cocoa_json(deadline),
            "symbol": payload.get("symbol") or "flag.checkered",
            "colorKey": payload.get("colorKey") or "blue",
            "notes": str(payload.get("notes") or "").strip(),
            "status": "completed" if completed else "active",
            "createdAt": cocoa_json(store.now()),
        }
        if completed:
            row["completedAt"] = cocoa_json(store.now())
        if savings:
            row["savingsAccountID"] = savings["id"]
        goals(store).append(row)
        store.doc["goals"] = goals(store)
    store.mark_financial()
    store.save()
    return row


def set_goal_status(store, goal_id: str, status: str) -> dict:
    store.require_ready()
    if status not in catalog.GOAL_STATUSES:
        raise AppError("目标状态无法识别。", "invalid")
    row = next((item for item in goals(store) if item.get("id") == goal_id), None)
    if row is None:
        raise AppError("没有这个目标。", "invalid")
    row["status"] = status
    if status == "completed":
        row["completedAt"] = row.get("completedAt") or cocoa_json(store.now())
    else:
        row.pop("completedAt", None)
    store.mark_financial()
    store.save()
    return row


def delete_goal(store, goal_id: str) -> None:
    store.require_ready()
    row = next((item for item in goals(store) if item.get("id") == goal_id), None)
    if row is None:
        raise AppError("没有这个目标。", "invalid")
    if any(record.get("goalID") == goal_id for record in records(store)):
        row["status"] = "archived"
        store.notice = "已有记录的目标已归档，以保留历史数据。"
    else:
        store.doc["goals"] = [item for item in goals(store) if item.get("id") != goal_id]
        store.notice = "目标已删除。"
    store.mark_financial()
    store.save()


def _refresh_goal(store, goal) -> bool:
    if goal.get("status") == "archived":
        return False
    reached = money(goal_balance(store, goal)) >= money(goal.get("targetAmount"))
    if reached and goal.get("status") != "completed":
        goal["status"] = "completed"
        goal["completedAt"] = goal.get("completedAt") or cocoa_json(store.now())
        return True
    if not reached and goal.get("status") == "completed":
        goal["status"] = "active"
        goal.pop("completedAt", None)
    return False


def save_record(store, payload: dict) -> dict:
    store.require_ready()
    amount = money(payload.get("amount"))
    if amount <= 0:
        raise AppError("金额必须大于 0。", "invalid")
    goal = next((row for row in goals(store) if row.get("id") == payload.get("goalID")), None)
    if goal is None:
        raise AppError("请选择一个攒钱目标。", "invalid")
    kind = payload.get("kind")
    if kind not in {"deposit", "withdrawal"}:
        raise AppError("请选择存入或取出。", "invalid")
    funding = account(store, payload.get("fundingAccountID"))
    savings = account(store, payload.get("savingsAccountID") or goal.get("savingsAccountID"))
    if funding is None or savings is None or funding.get("isArchived") or savings.get("isArchived"):
        raise AppError("请选择资金账户和目标存钱罐账户。", "invalid")
    if funding.get("id") == savings.get("id"):
        raise AppError("资金账户和存钱罐账户不能相同。", "invalid")
    if funding.get("currency") != goal.get("currency") or savings.get("currency") != goal.get("currency"):
        raise AppError("两个账户必须与攒钱目标使用相同币种。", "invalid")
    category = payload.get("category") or "other"
    if category not in catalog.SAVINGS_CATEGORIES:
        raise AppError("积蓄分类无法识别。", "invalid")
    when = parse_instant(payload.get("date"), store.tz) if payload.get("date") else store.now()
    note = str(payload.get("note") or "").strip()
    existing = next((row for row in records(store) if row.get("id") == payload.get("id")), None) if payload.get("id") else None
    if existing:
        old_contribution = money(0)
        if existing.get("goalID") == goal.get("id"):
            old_contribution = money(existing.get("amount")) if existing.get("kind") == "deposit" else -money(existing.get("amount"))
        available = money(goal_balance(store, goal)) - old_contribution
        if kind == "withdrawal" and amount > max(money(0), available):
            raise AppError("撤回金额不能超过该目标的可用分配。", "invalid")
        ledger_id = existing.get("ledgerEntryID") or new_id()
        existing.update({
            "goalID": goal["id"], "kind": kind, "amount": money_number(amount), "date": cocoa_json(when),
            "category": category, "note": note, "fundingAccountID": funding["id"],
            "savingsAccountID": savings["id"], "ledgerEntryID": ledger_id, "currency": goal["currency"],
        })
        record = existing
    else:
        if kind == "withdrawal" and amount > money(goal_balance(store, goal)):
            raise AppError("撤回金额不能超过该目标的可用分配。", "invalid")
        ledger_id = new_id()
        record = {
            "id": new_id(), "goalID": goal["id"], "kind": kind, "amount": money_number(amount),
            "date": cocoa_json(when), "category": category, "note": note, "gameRewardClaimed": kind == "deposit",
            "createdAt": cocoa_json(store.now()), "fundingAccountID": funding["id"],
            "savingsAccountID": savings["id"], "ledgerEntryID": ledger_id, "currency": goal["currency"],
        }
        records(store).insert(0, record)
        store.doc["records"] = records(store)
    source_id = funding["id"] if kind == "deposit" else savings["id"]
    target_id = savings["id"] if kind == "deposit" else funding["id"]
    category_title = catalog.SAVINGS_CATEGORIES[category]
    transfer_note = f"{goal['title']} · {category_title}" if not note else f"{goal['title']} · {note}"
    transfer = {
        "id": record["ledgerEntryID"], "kind": "transfer", "accountID": source_id, "targetAccountID": target_id,
        "amount": money_number(amount), "targetAmount": money_number(amount), "categoryID": "savings-goal-transfer",
        "date": cocoa_json(when), "note": transfer_note, "createdAt": cocoa_json(store.now()),
    }
    replaced = False
    for index, entry in enumerate(entries(store)):
        if entry.get("id") == record["ledgerEntryID"]:
            entries(store)[index] = {**entry, **transfer}
            replaced = True
            break
    if not replaced:
        _insert_entry(store, transfer)
    goal["savingsAccountID"] = savings["id"]
    _sort_records(store)
    _sort_entries(store)
    if existing is None and kind == "deposit":
        previous = goal.get("status")
        completed_now = _refresh_goal(store, goal)
        adventure.grant_savings_tickets(
            store, money_number(amount), goal["title"], previous != "completed" and completed_now,
            catalog.CURRENCIES[goal["currency"]][1],
        )
    else:
        for candidate in goals(store):
            _refresh_goal(store, candidate)
        if existing is None:
            adventure.add_event(store, "调整目标分配", f"从“{goal['title']}”撤回 {catalog.CURRENCIES[goal['currency']][1]}{money_number(amount):g}。", "arrow.up.circle.fill")
    store.mark_financial()
    store.save()
    return record


def delete_record(store, record_id: str) -> None:
    store.require_ready()
    row = next((item for item in records(store) if item.get("id") == record_id), None)
    if row is None:
        raise AppError("没有这条积蓄记录。", "invalid")
    if row.get("ledgerEntryID"):
        store.doc["ledgerEntries"] = [item for item in entries(store) if item.get("id") != row.get("ledgerEntryID")]
    store.doc["records"] = [item for item in records(store) if item.get("id") != record_id]
    for goal in goals(store):
        _refresh_goal(store, goal)
    store.notice = "记录已删除；已经获得的成长不会被扣除，也不会重复结算。" if row.get("gameRewardClaimed") else "记录已删除。"
    store.mark_financial()
    store.save()


def _clean_plan(store, payload: dict, existing=None) -> dict:
    name = payload.get("name")
    if not isinstance(name, str) or name != name.strip() or not name or len(name) > 120:
        raise AppError("请填写收入名称、有效的正数金额和每月 1 至 31 日的预计到账日。", "invalid")
    currency = payload.get("currency") or (existing or {}).get("currency") or store.currency
    if currency not in catalog.CURRENCIES:
        raise AppError("币种无法识别。", "invalid")
    try:
        amount = payload.get("amount")
        if not valid_fixed_amount(amount, currency):
            raise ValueError
    except (TypeError, ValueError):
        raise AppError("请填写收入名称、有效的正数金额和每月 1 至 31 日的预计到账日。", "invalid")
    try:
        day = int(payload.get("dayOfMonth"))
    except (TypeError, ValueError):
        day = 0
    if not 1 <= day <= 31:
        raise AppError("请填写收入名称、有效的正数金额和每月 1 至 31 日的预计到账日。", "invalid")
    start = payload.get("startMonth") or (existing or {}).get("startMonth")
    if parse_month_key(start or "") is None:
        raise AppError("请填写收入名称、有效的正数金额和每月 1 至 31 日的预计到账日。", "invalid")
    category = payload.get("category") or "salary-income"
    if category not in catalog.FIXED_INCOME_CATEGORIES:
        raise AppError("请填写收入名称、有效的正数金额和每月 1 至 31 日的预计到账日。", "invalid")
    digits = currency_digits(currency)
    number = money_number(amount) if digits else float(int(amount))
    return {
        "id": str((existing or {}).get("id") or payload.get("id") or new_id()).upper(),
        "name": name,
        "amount": number if digits else int(number),
        "currency": currency,
        "category": category,
        "dayOfMonth": day,
        "startMonth": start,
        "isEnabled": bool(payload.get("isEnabled", True)),
    }


def save_fixed_income(store, payload: dict) -> dict:
    store.require_ready()
    existing = next((row for row in plans(store) if str(row.get("id", "")).upper() == str(payload.get("id", "")).upper()), None) if payload.get("id") else None
    row = _clean_plan(store, payload, existing)
    if existing:
        if existing.get("startMonth") != row["startMonth"]:
            raise AppError("这项计划已发生变化，请关闭表单后重新选择。", "invalid")
        existing.update(row)
        row = existing
    else:
        if month_key(store.now(), store.tz) > row["startMonth"]:
            raise AppError("新计划的起始月份不能早于本月。", "invalid")
        if any(str(item.get("id", "")).upper() == row["id"] for item in plans(store)) or any(str(item.get("planID", "")).upper() == row["id"] for item in receipts(store)):
            raise AppError("该月的流水或回执存在冲突；没有创建新的收入。请先核对原记录。", "conflict")
        store.doc.setdefault("fixedIncomePlans", [])
        store.doc["fixedIncomePlans"].append(row)
    store.save_preserve_finance_time()
    return row


def set_fixed_income_enabled(store, plan_id: str, enabled: bool) -> dict:
    store.require_ready()
    row = next((item for item in plans(store) if str(item.get("id", "")).upper() == str(plan_id).upper()), None)
    if row is None:
        raise AppError("没有这项固定收入。", "invalid")
    row["isEnabled"] = bool(enabled)
    store.save_preserve_finance_time()
    return row


def confirm_fixed_income(store, payload: dict) -> dict:
    store.require_ready()
    if not payload.get("receivedIsConfirmed"):
        raise AppError("请先确认这笔款项已经实际到账。", "invalid")
    month = payload.get("month")
    if parse_month_key(month or "") is None:
        raise AppError("请选择有效的所属月份。", "invalid")
    plan = next((row for row in plans(store) if str(row.get("id", "")).upper() == str(payload.get("planID", "")).upper()), None)
    if plan is None:
        raise AppError("这项计划已发生变化，请关闭表单后重新选择。", "invalid")
    current = month_key(store.now(), store.tz)
    if month < plan.get("startMonth") or month > current:
        raise AppError("只能确认从计划起始月到本月的收入。", "invalid")
    matched = [row for row in receipts(store) if str(row.get("planID", "")).upper() == str(plan.get("id")).upper() and row.get("month") == month]
    if len(matched) > 1:
        raise AppError("该月的流水或回执存在冲突；没有创建新的收入。请先核对原记录。", "conflict")
    if matched:
        return {"result": "alreadyConfirmed"}
    if not plan.get("isEnabled"):
        raise AppError("计划已停用，不能确认新的到账。", "invalid")
    owner = account(store, payload.get("accountID"))
    if owner is None or owner.get("isArchived") or owner.get("currency") != plan.get("currency"):
        raise AppError("请选择一个仍在使用、且与计划同币种的收款账户。", "invalid")
    received = parse_instant(payload.get("receivedOn"), store.tz) if payload.get("receivedOn") else store.now()
    if month_key(received, store.tz) < plan.get("startMonth") or start_of_day(received, store.tz) > start_of_day(store.now(), store.tz):
        raise AppError("实际到账日期不能早于计划起始月，也不能是未来日期。", "invalid")
    entry_id = f"fixed-income|{str(plan['id']).lower()}|{month}"
    if any(row.get("id") == entry_id for row in entries(store)):
        raise AppError("该月的流水或回执存在冲突；没有创建新的收入。请先核对原记录。", "conflict")
    receipt = {
        "planID": plan["id"], "month": month, "name": plan["name"], "amount": plan["amount"],
        "currency": plan["currency"], "category": plan["category"], "accountID": owner["id"],
        "accountName": owner["name"], "receivedOn": cocoa_json(received), "confirmedAt": cocoa_json(store.now()),
    }
    entry = {
        "id": entry_id, "kind": "income", "accountID": owner["id"], "amount": money_number(plan["amount"]),
        "categoryID": plan["category"], "date": cocoa_json(received),
        "note": f"固定收入·{plan['name']}（{month}）", "createdAt": cocoa_json(store.now()),
    }
    store.doc.setdefault("fixedIncomeReceipts", []).append(receipt)
    _insert_entry(store, entry)
    store.mark_financial()
    store.save()
    return {"result": "posted", "ledgerID": entry_id}


def backfill_record_currency(store) -> bool:
    changed = False
    for record in records(store):
        if record.get("currency"):
            continue
        goal = next((row for row in goals(store) if row.get("id") == record.get("goalID")), None)
        if goal and goal.get("currency"):
            record["currency"] = goal["currency"]
        else:
            funding = account(store, record.get("savingsAccountID")) or account(store, record.get("fundingAccountID"))
            record["currency"] = funding.get("currency") if funding else "CNY"
        changed = True
    return changed


def financial_fingerprint(store) -> str:
    def sort_rows(rows):
        return sorted((row for row in rows if isinstance(row, dict)), key=lambda row: str(row.get("id") or ""))

    payload = {
        "accounts": sort_rows(accounts(store)),
        "entries": sort_rows(entries(store)),
        "goals": sort_rows(goals(store)),
        "records": sort_rows(records(store)),
        "budgets": sort_rows(budgets(store)),
        "recurring": sort_rows(rules(store)),
    }
    raw = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(raw).hexdigest()


def daily_summary(store, currency: str, moment=None):
    moment = moment or store.now()
    local = in_zone(moment, store.tz)
    from gaojixu.timeutil import days_in_month
    count = days_in_month(local.year, local.month)
    start = local.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    expense = [money(0) for _ in range(count)]
    income = [money(0) for _ in range(count)]
    saving = [money(0) for _ in range(count)]
    for entry in entries(store):
        if entry.get("kind") == "transfer" or entry.get("categoryID") == "balance-adjustment":
            continue
        owner = account(store, entry.get("accountID"))
        when = _when(store, entry)
        if not owner or owner.get("currency") != currency or when is None or not same_month(when, start, store.tz):
            continue
        day = in_zone(when, store.tz).day - 1
        if entry.get("kind") == "expense":
            expense[day] += money(entry.get("amount"))
        elif entry.get("kind") == "income":
            income[day] += money(entry.get("amount"))
    goal_currency = {row.get("id"): row.get("currency") for row in goals(store)}
    for record in records(store):
        if goal_currency.get(record.get("goalID")) != currency:
            continue
        when = _when(store, record)
        if when is None or not same_month(when, start, store.tz):
            continue
        day = in_zone(when, store.tz).day - 1
        signed = money(record.get("amount"))
        saving[day] += signed if record.get("kind") == "deposit" else -signed
    days = []
    for index in range(count):
        day_date = start.replace(day=index + 1)
        days.append({
            "date": cocoa_json(day_date),
            "day": index + 1,
            "expense": money_number(expense[index]),
            "income": money_number(income[index]),
            "saving": money_number(saving[index]),
        })
    return days


def deposited_this_month(store, currency: str) -> float:
    total = money(0)
    for record in records(store):
        goal = next((row for row in goals(store) if row.get("id") == record.get("goalID")), None)
        when = _when(store, record)
        if record.get("kind") == "deposit" and goal and goal.get("currency") == currency and when and same_month(when, store.now(), store.tz):
            total += money(record.get("amount"))
    return money_number(total)


def saving_streak(store) -> int:
    days = set()
    for record in records(store):
        if record.get("kind") != "deposit":
            continue
        when = _when(store, record)
        if when:
            local = start_of_day(when, store.tz)
            days.add((local.year, local.month, local.day))
    if not days:
        return 0
    cursor = start_of_day(store.now(), store.tz)
    local = in_zone(cursor, store.tz)
    key = (local.year, local.month, local.day)
    if key not in days:
        cursor = add_days(cursor, -1, store.tz)
        local = in_zone(cursor, store.tz)
        key = (local.year, local.month, local.day)
        if key not in days:
            return 0
    count = 0
    while key in days:
        count += 1
        cursor = add_days(cursor, -1, store.tz)
        local = in_zone(cursor, store.tz)
        key = (local.year, local.month, local.day)
    return count
