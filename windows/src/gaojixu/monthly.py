"""固定支出与权益。沿用 Mac 的 monthly.sqlite 单行 JSON，不在缺失时新建空库。"""

from __future__ import annotations

import json
import sqlite3
import uuid
from datetime import datetime, timedelta
from decimal import Decimal, InvalidOperation
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from gaojixu.errors import AppError
from gaojixu.money import money_number
from gaojixu.timeutil import add_months, cocoa_json, days_in_month, month_key, parse_instant, parse_month_key, read_cocoa, start_of_day, week_start

OWNER = "com.gaojixu.savings"
CURRENCIES = {"CNY", "USD", "EUR", "HKD", "JPY", "GBP"}


def new_id() -> str:
    return str(uuid.uuid4()).upper()


def directory_for(root: Path) -> Path:
    return root / "IntegratedFinance" / "Monthly"


def _dumps(payload: dict) -> bytes:
    return json.dumps(payload, ensure_ascii=False, sort_keys=True).encode("utf-8")


def _authority_path(directory: Path) -> Path:
    return directory / "authority.json"


def _database_path(directory: Path) -> Path:
    return directory / "monthly.sqlite"


def _read_authority(directory: Path) -> dict | None:
    path = _authority_path(directory)
    if not path.is_file():
        return None
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    if not isinstance(payload, dict):
        return None
    if payload.get("schemaVersion") != 1 or payload.get("ownerBundleID") != OWNER or payload.get("module") != "monthly":
        return None
    if not payload.get("transactionID"):
        return None
    return payload


def _marker_ok(root: Path, receipt: dict) -> bool:
    if receipt.get("mode") == "new":
        return receipt.get("sourceBundleID") in (None, "") and receipt.get("commitMarkerPath") in (None, "")
    if receipt.get("mode") != "migrated":
        return False
    if not receipt.get("sourceFrozen") or receipt.get("sourceBundleID") != "com.gaoseries.GaoYueGong":
        return False
    reference = receipt.get("commitMarkerPath") or ""
    if not isinstance(reference, str):
        return False
    transaction = receipt.get("transactionID")
    if reference.startswith("app-group:"):
        relative = reference[len("app-group:"):]
        path = root / relative
    elif reference.startswith("/") or (len(reference) > 2 and reference[1] == ":"):
        path = Path(reference)
    else:
        return False
    if not path.is_file():
        return False
    try:
        marker = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return False
    if not isinstance(marker, dict):
        return False
    modules = marker.get("modules")
    expected = receipt.get("expectedModules")
    return (
        marker.get("schemaVersion") == 1
        and marker.get("ownerBundleID") == OWNER
        and marker.get("transactionID") == transaction
        and isinstance(modules, list)
        and isinstance(expected, list)
        and all(isinstance(value, str) for value in modules + expected)
        and "monthly" in expected
        and set(modules) == set(expected)
    )


def load_state(root: Path):
    directory = directory_for(root)
    database = _database_path(directory)
    if not database.exists():
        return "missing", None, "固定支出库尚未创建。缺失时不会新建空库。"
    if not database.is_file() or database.is_symlink():
        return "protected", None, "固定支出库不是普通文件，未创建或替换。"
    try:
        connection = sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True)
        try:
            rows = connection.execute("SELECT id, json FROM state").fetchall()
        finally:
            connection.close()
        if len(rows) != 1 or rows[0][0] != 1 or not isinstance(rows[0][1], (bytes, bytearray)):
            return "protected", None, "月供业务库行数不符，原文件未改。"
        payload = json.loads(bytes(rows[0][1]).decode("utf-8"))
        if not isinstance(payload, dict) or payload.get("schemaVersion") != 1 or payload.get("rulesVersion") != 1:
            return "protected", None, "月供业务库版本不受支持，原文件未改。"
        for key in ("subscriptions", "payments", "claims", "benefits", "events", "reviews"):
            if key in payload and (not isinstance(payload[key], list) or not all(isinstance(row, dict) for row in payload[key])):
                return "protected", None, "月供业务记录格式有误，原文件未改。"
    except (sqlite3.Error, OSError, UnicodeError, json.JSONDecodeError):
        return "protected", None, "月供业务库无法读取，原文件未改。"
    receipt = _read_authority(directory)
    if receipt is None or not _marker_ok(root, receipt):
        return "readonly", payload, "固定支出可以查看。写入凭据不在这台电脑上，未改原库。"
    return "ready", payload, ""


def _write_state(root: Path, payload: dict) -> None:
    status, _current, notice = load_state(root)
    if status != "ready":
        raise AppError(notice or "固定支出库不能写入。", "protected")
    database = _database_path(directory_for(root))
    blob = _dumps(payload)
    connection = sqlite3.connect(database)
    try:
        connection.execute("BEGIN IMMEDIATE")
        cursor = connection.execute("UPDATE state SET json=? WHERE id=1", (blob,))
        if cursor.rowcount != 1:
            connection.execute("ROLLBACK")
            raise AppError("月供业务记录未落盘。", "persistence")
        connection.execute("COMMIT")
    except sqlite3.Error as exc:
        try:
            connection.execute("ROLLBACK")
        except sqlite3.Error:
            pass
        raise AppError("月供业务记录未落盘。", "persistence") from exc
    finally:
        connection.close()


def create_new(root: Path, now) -> dict:
    directory = directory_for(root)
    if directory.exists() and any(directory.iterdir()):
        raise AppError("目标已有资料，不能重新初始化。", "protected")
    parent = directory.parent
    parent.mkdir(parents=True, exist_ok=True)
    staging = parent / f".monthly-new-{uuid.uuid4().hex}"
    staging.mkdir()
    try:
        moment = cocoa_json(now())
        receipt = {
            "activatedAt": moment,
            "mode": "new",
            "module": "monthly",
            "ownerBundleID": OWNER,
            "schemaVersion": 1,
            "sourceFrozen": True,
            "transactionID": new_id(),
        }
        _authority_path(staging).write_text(json.dumps(receipt, ensure_ascii=False, sort_keys=True), encoding="utf-8")
        state = _empty_state(now)
        connection = sqlite3.connect(_database_path(staging))
        try:
            connection.execute("CREATE TABLE state(id INTEGER PRIMARY KEY CHECK(id=1), json BLOB NOT NULL)")
            connection.execute("INSERT INTO state(id, json) VALUES(1, ?)", (_dumps(state),))
            connection.commit()
        finally:
            connection.close()
        if directory.exists():
            directory.rmdir()
        staging.rename(directory)
    except Exception:
        if staging.exists():
            for child in staging.iterdir():
                if child.is_file():
                    child.unlink()
            staging.rmdir()
        raise
    return state


def _empty_state(now) -> dict:
    zone = getattr(now().tzinfo, "key", None) or ""
    return {
        "schemaVersion": 1,
        "rulesVersion": 1,
        "updatedAt": cocoa_json(now()),
        "subscriptions": [],
        "payments": [],
        "claims": [],
        "reviews": [],
        "events": [],
        "benefits": [],
        "tombstones": [],
        "legacyRewardIDs": [],
        "preferences": {
            "timezone": zone,
            "language": "zh",
            "appearance": "system",
            "backgroundHex": "",
            "notifications": False,
            "reminderDays": 3,
            "reminderHour": 9,
            "privacy": False,
            "onboarded": False,
        },
    }


def _require(root: Path):
    status, state, notice = load_state(root)
    if status != "ready" or state is None:
        raise AppError(notice or "固定支出库不能写入。", "protected")
    return state


def business_zone(state: dict, fallback):
    name = (state.get("preferences") or {}).get("timezone")
    if isinstance(name, str) and name:
        try:
            return ZoneInfo(name)
        except (ZoneInfoNotFoundError, ValueError):
            pass
    return fallback


def _row(state, key, ident):
    return next((row for row in state.get(key, []) if str(row.get("id")).casefold() == str(ident).casefold()), None)


def _calendar_day(value, zone):
    moment = read_cocoa(value, zone)
    return moment.date().isoformat() if moment else ""


def _save(root, state, now):
    state["updatedAt"] = cocoa_json(now())
    _write_state(root, state)


def _amount(value, currency, *, zero=False):
    if currency not in CURRENCIES:
        raise AppError("这个币种不在固定支出支持范围内。", "invalid")
    try:
        amount = Decimal(str(value))
        quantum = Decimal("1") if currency == "JPY" else Decimal("0.01")
        valid = (amount.is_finite() and 0 <= amount <= 999_999_999 and (zero or amount > 0)
                 and amount == amount.quantize(quantum))
    except InvalidOperation:
        valid = False
    if not valid:
        raise AppError("请填写有效金额，并使用该币种支持的小数位。", "invalid")
    return money_number(amount)


def save_subscription(root: Path, payload: dict, now) -> dict:
    state = _require(root)
    name = str(payload.get("name") or "").strip()
    if not name:
        raise AppError("请填写订阅名称。", "invalid")
    currency = payload.get("currency") or "CNY"
    price = _amount(payload.get("price"), currency)
    cycle = payload.get("cycle") or "monthly"
    if cycle not in {"weekly", "monthly", "quarterly", "yearly", "days"}:
        raise AppError("扣费周期无法识别。", "invalid")
    try:
        interval = int(payload.get("interval") or (30 if cycle == "days" else 1))
    except (TypeError, ValueError):
        interval = 0
    if not 1 <= interval <= 3650:
        raise AppError("周期间隔无效。", "invalid")
    zone = business_zone(state, now().tzinfo)
    start = start_of_day(parse_instant(payload.get("start"), zone) if payload.get("start") else now(), zone)
    benefit = payload.get("benefit") or "none"
    if benefit not in {"none", "daily", "weekly"}:
        raise AppError("权益类型无法识别。", "invalid")
    existing = _row(state, "subscriptions", payload.get("id")) if payload.get("id") else None
    if payload.get("id") and not existing:
        raise AppError("这项订阅已变化。", "conflict")
    anchor = parse_instant(payload["anchor"], zone) if payload.get("anchor") else start
    plan_values = {
        "anchor": cocoa_json(start_of_day(anchor, zone)), "price": price, "currency": currency,
        "cycle": cycle, "interval": interval, "monthEnd": bool(payload.get("monthEnd")), "benefit": benefit,
    }
    if existing:
        plan = (existing.get("plans") or [{}])[-1]
        if not payload.get("anchor"):
            plan_values["anchor"] = plan.get("anchor", plan_values["anchor"])
        if any(plan.get(key) != value for key, value in plan_values.items()):
            effective = start_of_day(parse_instant(payload["effective"], zone), zone) if payload.get("effective") else start_of_day(now(), zone)
            previous_start = read_cocoa(plan.get("start"), zone)
            if previous_start and effective.date() < previous_start.date():
                raise AppError("变更生效日不能早于当前计划开始日。", "invalid")
            plan["end"] = cocoa_json(effective)
            existing["plans"].append({"id": new_id(), "start": cocoa_json(effective), **plan_values})
        existing["name"] = name
        existing["category"] = payload.get("category") or existing.get("category") or "影音"
        existing["note"] = str(payload.get("note") or "")
        existing["link"] = str(payload.get("link") or "")
        existing["updatedAt"] = cocoa_json(now())
        existing["autoRenew"] = bool(payload.get("autoRenew", True))
        row = existing
    else:
        subscription_id = new_id()
        row = {
            "id": subscription_id,
            "name": name,
            "category": payload.get("category") or "影音",
            "symbol": payload.get("symbol") or "repeat.circle",
            "color": payload.get("color") or "blue",
            "createdAt": cocoa_json(now()),
            "updatedAt": cocoa_json(now()),
            "plans": [{
                "id": new_id(),
                "start": cocoa_json(start),
                **plan_values,
            }],
            "autoRenew": bool(payload.get("autoRenew", True)),
            "cancelIntent": False,
            "trialResolved": False,
            "archived": False,
            "link": str(payload.get("link") or ""),
            "note": str(payload.get("note") or ""),
        }
        state.setdefault("subscriptions", []).append(row)
        if benefit != "none":
            state.setdefault("benefits", []).append({
                "id": new_id(),
                "name": name,
                "kind": benefit,
                "subscriptionID": subscription_id,
                "createdAt": cocoa_json(now()),
                "archived": False,
                "note": "",
            })
    for key in ("cancelIntent", "trialResolved", "stacking"):
        if key in payload:
            row[key] = bool(payload[key])
    for key in ("trialEnd", "cancelDeadline", "cancelledAt", "serviceEnd"):
        if key in payload:
            if payload[key]:
                date = parse_instant(payload[key], zone)
                if key == "cancelledAt" and date.date() > now().astimezone(zone).date():
                    raise AppError("取消日期不能是未来日期。", "invalid")
                row[key] = cocoa_json(date)
            else:
                row.pop(key, None)
    if "reminderDays" in payload:
        value = payload.get("reminderDays")
        if value in (None, ""):
            row.pop("reminderDays", None)
        else:
            days = int(value)
            if not 0 <= days <= 365:
                raise AppError("提前提醒天数无效。", "invalid")
            row["reminderDays"] = days
    _save(root, state, now)
    return row


def record_payment(root: Path, payload: dict, now, ledger_writer=None, *, validate=None) -> dict:
    state = _require(root)
    subscription = _row(state, "subscriptions", payload.get("subscriptionID"))
    if subscription is None:
        raise AppError("没有这项订阅。", "invalid")
    zone = business_zone(state, now().tzinfo)
    due = start_of_day(parse_instant(payload.get("due"), zone) if payload.get("due") else now(), zone)
    paid = parse_instant(payload.get("paidAt"), zone) if payload.get("paidAt") else now()
    if paid.astimezone(zone).date() > now().astimezone(zone).date():
        raise AppError("实际日期不能是未来日期。", "invalid")
    existing = _row(state, "payments", payload.get("id")) if payload.get("id") else None
    if payload.get("id") and (not existing or existing["subscriptionID"] != subscription["id"]):
        raise AppError("这笔支付已变化。", "conflict")
    if existing:
        due = start_of_day(parse_instant(existing["due"], zone), zone)
    bill = next((row for row in _bills(subscription, state, due, due, zone) if row["due"] == due.date().isoformat()), None)
    if payload.get("billID") and (not bill or payload["billID"] != bill["id"]):
        raise AppError("本账期已变化，请重新选择。", "conflict")
    plan = bill or (subscription.get("plans") or [{}])[-1]
    currency = payload.get("currency") or (existing or plan).get("currency") or "CNY"
    amount = _amount(payload.get("amount") if payload.get("amount") not in (None, "") else plan.get("price") or 0,
                     currency, zero=True)
    skipped = bool(payload.get("skipped"))
    day = due.date().isoformat()
    payment_id = existing["id"] if existing else f"{subscription['id']}|{day}"
    if not existing and (_row(state, "payments", payment_id) or (payload.get("billID") and _covered(bill, subscription, state))):
        raise AppError("这一期已经记过，没有重复入账。", "duplicate")
    periods = int(payload.get("periods") or 1)
    if not 1 <= periods <= 120:
        raise AppError("覆盖期数应在 1 到 120 之间。", "invalid")
    payment = {
        **(existing or {}),
        "id": payment_id,
        "subscriptionID": subscription["id"],
        "due": cocoa_json(due),
        "paidAt": cocoa_json(paid),
        "recordedAt": cocoa_json(now()),
        "amount": 0 if skipped else amount,
        "currency": currency,
        "skipped": skipped,
        "note": str(payload.get("note") or ""),
    }
    if skipped:
        payment.pop("periods", None)
    else:
        payment["periods"] = periods if subscription.get("stacking") else 1
    if validate:
        validate(payment, subscription)
    if existing:
        existing.update(payment)
    else:
        state.setdefault("payments", []).append(payment)
    _save(root, state, now)
    ledger_id = None
    if not skipped and ledger_writer and payload.get("accountID"):
        ledger_id = ledger_writer(payment, subscription)
    return {"payment": payment, "ledgerID": ledger_id}


def _bills(subscription, state, lower, upper, zone):
    low, high = lower.date(), upper.date()
    sequence = 0
    bills = []
    stacking = subscription.get("stacking") is True
    for plan in subscription.get("plans") or []:
        start = read_cocoa(plan.get("start"), zone)
        anchor = read_cocoa(plan.get("anchor"), zone) or start
        if anchor is None or start is None:
            continue
        calendar_anchor = start_of_day(anchor, zone)
        earliest = max(low, start.date())
        stops = [_calendar_day(value, zone) for value in (plan.get("end"), plan.get("billingStop"), subscription.get("cancelledAt"))]
        stop = min((value for value in stops if value), default="9999-12-31")
        cycle = plan.get("cycle") or "monthly"
        step = 7 if cycle == "weekly" else max(1, int(plan.get("interval") or 30)) if cycle == "days" else 0
        months = {"monthly": 1, "quarterly": 3, "yearly": 12}.get(cycle, 1)
        if stacking:
            step = step or {"monthly": 30, "quarterly": 90, "yearly": 365}.get(cycle, 30)
        i = 0
        if not stacking:
            if step:
                i = max(0, (earliest - anchor.date()).days // step - 1)
            else:
                i = max(0, ((earliest.year - anchor.year) * 12 + earliest.month - anchor.month) // months - 2)
        for index in range(i, 10000):
            if step:
                day = (calendar_anchor + timedelta(days=index * step)).date()
            else:
                day = add_months(calendar_anchor, index * months, anchor.day, zone).date()
                if plan.get("monthEnd"):
                    day = day.replace(day=days_in_month(day.year, day.month))
            if day > high or day.isoformat() >= stop:
                break
            if day >= earliest:
                bills.append({
                    "id": f"{subscription['id']}|{day.isoformat()}", "subscriptionID": subscription["id"],
                    "planID": plan.get("id"), "due": day.isoformat(), "price": plan.get("price"),
                    "currency": plan.get("currency"), "sequence": sequence if stacking else index,
                    "name": subscription.get("name"),
                })
            if stacking:
                sequence += 1
    return sorted(bills, key=lambda bill: (bill["due"], bill["id"]))


def _covered(bill, subscription, state):
    payments = state.get("payments", [])
    if subscription.get("stacking"):
        covered = sum(
            int(payment.get("periods") or 1) for payment in payments
            if payment.get("subscriptionID") == subscription.get("id") and not payment.get("skipped")
        )
        if bill["sequence"] < covered:
            return True
    return any(payment.get("id") == bill["id"] for payment in payments)


def _claim_key(benefit, state, date, zone):
    if benefit.get("archived") or benefit.get("kind") not in {"weekly", "daily"}:
        return None
    subscription_id = benefit.get("subscriptionID")
    if subscription_id:
        subscription = _row(state, "subscriptions", subscription_id)
        if not subscription or subscription.get("archived"):
            return None
        day = date.date().isoformat()
        if subscription.get("cancelledAt") and (
                not subscription.get("serviceEnd") or day > _calendar_day(subscription["serviceEnd"], zone)):
            return None
        if not any(
                _calendar_day(plan.get("start"), zone) <= day
                and (not plan.get("end") or day < _calendar_day(plan["end"], zone))
                for plan in subscription.get("plans", [])):
            return None
    period = week_start(date, zone) if benefit["kind"] == "weekly" else start_of_day(date, zone)
    return f"{benefit['id']}|{benefit['kind']}|{period.date().isoformat()}"


def save_benefit(root: Path, payload: dict, now) -> dict:
    state = _require(root)
    name = str(payload.get("name") or "").strip()
    kind = payload.get("kind") or "daily"
    if not name or kind not in {"daily", "weekly"}:
        raise AppError("请填写权益名称，并选择每日或每周。", "invalid")
    subscription_id = payload.get("subscriptionID")
    subscription = _row(state, "subscriptions", subscription_id) if subscription_id else None
    if subscription_id and not subscription:
        raise AppError("关联的订阅不存在。", "invalid")
    row = _row(state, "benefits", payload.get("id")) if payload.get("id") else None
    if payload.get("id") and not row:
        raise AppError("这项权益已变化。", "conflict")
    if row is None:
        row = {"id": new_id(), "createdAt": cocoa_json(now())}
        state.setdefault("benefits", []).append(row)
    row.update(name=name, kind=kind, archived=bool(payload.get("archived")), note=str(payload.get("note") or ""))
    if subscription:
        row["subscriptionID"] = subscription["id"]
    else:
        row.pop("subscriptionID", None)
    _save(root, state, now)
    return row


def claim_benefit(root: Path, benefit_id: str, now, date=None, expected=None) -> dict:
    state = _require(root)
    benefit = _row(state, "benefits", benefit_id)
    if benefit is None:
        raise AppError("没有这项权益。", "invalid")
    moment = now()
    zone = business_zone(state, moment.tzinfo)
    chosen = parse_instant(date, zone) if date else moment.astimezone(zone)
    if chosen.date() > moment.astimezone(zone).date():
        raise AppError("不能补记未来的权益。", "invalid")
    claim_id = _claim_key(benefit, state, chosen, zone)
    if not claim_id:
        raise AppError("对应日期的权益不可记录。", "invalid")
    if expected and claim_id != expected:
        raise AppError("领取周期已变化，请刷新后重试。", "conflict")
    if _row(state, "claims", claim_id):
        return {"claimed": False, "id": claim_id}
    state.setdefault("claims", []).append({
        "id": claim_id,
        "subscriptionID": benefit.get("subscriptionID") or benefit["id"],
        "date": cocoa_json(chosen),
        "recordedAt": cocoa_json(moment),
        "backfill": chosen.date() != moment.astimezone(zone).date(),
    })
    _save(root, state, now)
    return {"claimed": True, "id": claim_id}


def change_item(root, payload, now):
    state = _require(root)
    collection = payload.get("collection")
    operation = payload.get("operation")
    if collection not in {"subscriptions", "payments", "events", "benefits", "claims"}:
        raise AppError("记录类型无法识别。", "invalid")
    current = _row(state, collection, payload.get("id"))
    if not current:
        raise AppError("记录已变化。", "conflict")
    if operation == "archive" and collection in {"subscriptions", "benefits"}:
        current["archived"] = not current.get("archived")
        if collection == "subscriptions":
            current["updatedAt"] = cocoa_json(now())
    elif operation == "toggle" and collection == "events":
        if current.get("doneAt"):
            del current["doneAt"]
        else:
            current["doneAt"] = cocoa_json(now())
    elif operation == "delete":
        state[collection].remove(current)
        if collection == "subscriptions":
            ident = current["id"]
            state["payments"] = [row for row in state.get("payments", []) if row.get("subscriptionID") != ident]
            state["reviews"] = [row for row in state.get("reviews", []) if row.get("subscriptionID") != ident]
            detached = {row["id"].casefold(): row["id"] for row in state.get("benefits", []) if row.get("subscriptionID") == ident}
            claims = []
            for row in state.get("claims", []):
                if row.get("subscriptionID") == ident:
                    owner = detached.get(row["id"].partition("|")[0].casefold())
                    if not owner:
                        continue
                    row["subscriptionID"] = owner
                claims.append(row)
            state["claims"] = claims
            for key in ("benefits", "events"):
                for row in state.get(key, []):
                    if row.get("subscriptionID") == ident:
                        row.pop("subscriptionID", None)
            state["tombstones"] = sorted(set(state.get("tombstones", [])) | {f"deleted|{ident}"})
        if collection == "benefits":
            prefix = current["id"].casefold() + "|"
            state["claims"] = [row for row in state.get("claims", []) if not row.get("id", "").casefold().startswith(prefix)]
            state["tombstones"] = sorted(set(state.get("tombstones", [])) | {f"deleted-benefit|{current['id']}"})
    else:
        raise AppError("记录操作无效。", "invalid")
    _save(root, state, now)
    return current


def save_event(root, payload, now):
    state = _require(root)
    name = str(payload.get("name") or "").strip()
    if not name:
        raise AppError("请填写事项名称。", "invalid")
    zone = business_zone(state, now().tzinfo)
    deadline = parse_instant(payload.get("deadline"), zone)
    row = _row(state, "events", payload.get("id")) if payload.get("id") else None
    if payload.get("id") and not row:
        raise AppError("这项到期事项已变化。", "conflict")
    if row is None:
        row = {"id": new_id(), "createdAt": cocoa_json(now())}
        state.setdefault("events", []).append(row)
    row.update(name=name, deadline=cocoa_json(deadline), note=str(payload.get("note") or ""))
    subscription = _row(state, "subscriptions", payload.get("subscriptionID"))
    if subscription:
        row["subscriptionID"] = subscription["id"]
    else:
        row.pop("subscriptionID", None)
    _save(root, state, now)
    return row


def save_review(root, payload, now):
    state = _require(root)
    subscription = _row(state, "subscriptions", payload.get("subscriptionID"))
    month = payload.get("month")
    rating = int(payload.get("rating", -1))
    zone = business_zone(state, now().tzinfo)
    if not subscription or not parse_month_key(month) or month > month_key(now(), zone) or rating not in {-1, 0, 1, 2}:
        raise AppError("评价月份或使用频率无效。", "invalid")
    key = f"{subscription['id']}|{month}"
    reviews = state.setdefault("reviews", [])
    prior = _row(state, "reviews", key)
    if prior:
        reviews.remove(prior)
    if rating >= 0:
        reviews.append({"id": key, "subscriptionID": subscription["id"], "month": month, "rating": rating})
    _save(root, state, now)
    return {"saved": True}


def update_preferences(root, payload, now):
    state = _require(root)
    prefs = state.setdefault("preferences", {})
    for key in ("privacy", "notifications"):
        if isinstance(payload.get(key), bool):
            prefs[key] = payload[key]
    if payload.get("timezone"):
        name = payload["timezone"].strip()
        try:
            ZoneInfo(name)
        except (ZoneInfoNotFoundError, ValueError):
            raise AppError("请输入有效的 IANA 时区，例如 Asia/Shanghai。", "invalid") from None
        prefs["timezone"] = name
    for key, maximum in [("reminderDays", 365), ("reminderHour", 23)]:
        if payload.get(key) not in (None, ""):
            value = int(payload[key])
            if not 0 <= value <= maximum:
                raise AppError("提醒日期或时间无效。", "invalid")
            prefs[key] = value
    _save(root, state, now)
    return prefs


def _use_rating(subscription, state, now, zone, interval=None):
    ident = subscription.get("id")
    linked = [row for row in state.get("benefits", [])
              if row.get("subscriptionID") == ident and not row.get("archived")]
    if not linked:
        key = month_key(interval[0] if interval else now, zone)
        row = next((review for review in state.get("reviews", [])
                    if review.get("subscriptionID") == ident and review.get("month") == key), None)
        return {"score": row.get("rating") if row else None,
                "label": ("较少使用", "偶尔使用", "经常使用")[row["rating"]] if row else "未评估"}
    end = start_of_day(now, zone)
    start, end = interval or (end - timedelta(days=30), end)
    opportunities = set()
    daily = False
    day = start
    while day < end:
        for benefit in linked:
            key = _claim_key(benefit, state, day, zone)
            if key is None:
                continue
            if benefit["kind"] == "weekly":
                week_end = week_start(day, zone) + timedelta(days=7)
                if not start < week_end <= end:
                    continue
            else:
                daily = True
            opportunities.add(key.casefold())
        day += timedelta(days=1)
    expected = len(opportunities)
    claimed = sum(row.get("id", "").casefold() in opportunities for row in state.get("claims", []))
    if expected < (7 if daily else 4):
        return {"score": None, "label": "数据不足", "expected": expected, "claimed": claimed}
    rate = claimed / expected
    score = 2 if rate >= .7 else 1 if rate >= .3 else 0
    return {"score": score, "label": ("较少使用", "偶尔使用", "经常使用")[score],
            "expected": expected, "claimed": claimed}


def summary(root: Path, tz, now=None):
    status, state, notice = load_state(root)
    if state is None:
        return {"status": status, "notice": notice, "subscriptions": [], "payments": [], "benefits": [], "claims": []}
    zone = business_zone(state, tz)
    moment = (now() if now else datetime.now(zone)).astimezone(zone)
    today = moment.date().isoformat()
    lower = add_months(moment, -12, moment.day, zone)
    upper = moment + timedelta(days=90)
    subscriptions = []
    bills = []
    for row in state.get("subscriptions", []):
        plan = (row.get("plans") or [{}])[-1]
        renewal = None
        if not row.get("archived"):
            candidates = _bills(row, state, lower, upper, zone)
            bills.extend(bill for bill in candidates if not _covered(bill, row, state))
            start = read_cocoa((row.get("plans") or [{}])[0].get("start"), zone)
            if row.get("stacking") and start and not row.get("cancelledAt"):
                far = add_months(moment, 600, moment.day, zone)
                renewal = next((bill for bill in _bills(row, state, start, far, zone) if not _covered(bill, row, state)), None)
        first = start_of_day(moment, zone).replace(day=1)
        month_starts = [add_months(first, offset, 1, zone) for offset in (-2, -1, 0)]
        rating = _use_rating(row, state, moment, zone)
        rating["reviewRenewal"] = all(
            _use_rating(row, state, moment, zone, period)["score"] == 0
            for period in zip(month_starts, month_starts[1:])
        )
        subscriptions.append({
            **row, "nextRenewal": renewal, "planCount": len(row.get("plans", [])),
            "usage": rating,
            **{key: plan.get(key) for key in ("price", "currency", "cycle", "interval", "benefit", "monthEnd")},
            **{key: _calendar_day(row.get(key), zone) for key in ("trialEnd", "cancelDeadline", "cancelledAt", "serviceEnd")},
            "start": _calendar_day(plan.get("start"), zone), "anchor": _calendar_day(plan.get("anchor"), zone),
        })
    payments = [
        {**row, **{key: _calendar_day(row.get(key), zone) for key in ("due", "paidAt")}}
        for row in sorted(state.get("payments", []), key=lambda payment: (payment.get("paidAt", 0), payment.get("recordedAt", 0)), reverse=True)
    ]
    claims = [
        {**row, "date": _calendar_day(row.get("date"), zone)} for row in state.get("claims", [])
    ]
    claim_ids = {str(row.get("id")).casefold() for row in claims}
    benefits = []
    for row in state.get("benefits", []):
        key = _claim_key(row, state, moment, zone)
        benefits.append({**row, "periodKey": key, "claimed": bool(key and key.casefold() in claim_ids)})
    events = []
    for row in state.get("events", []):
        date = read_cocoa(row.get("deadline"), zone)
        events.append({**row, "deadline": date.strftime("%Y-%m-%dT%H:%M") if date else ""})
    updated = read_cocoa(state.get("updatedAt"), zone)
    return {
        "status": status,
        "notice": notice,
        "subscriptions": subscriptions,
        "bills": sorted({bill["id"]: bill for bill in bills}.values(), key=lambda bill: (bill["due"], bill["id"])),
        "payments": payments,
        "benefits": benefits,
        "claims": claims,
        "events": sorted(events, key=lambda row: row["deadline"]),
        "reviews": state.get("reviews", []),
        "preferences": state.get("preferences", {}),
        "today": today,
        "monthKey": today[:7],
        "updatedAt": updated.strftime("%Y-%m-%d %H:%M") if updated else "",
    }
