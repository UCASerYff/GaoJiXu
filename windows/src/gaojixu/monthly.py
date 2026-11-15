"""固定支出与权益。沿用 Mac 的 monthly.sqlite 单行 JSON，不在缺失时新建空库。"""

from __future__ import annotations

import json
import os
import sqlite3
import uuid
from pathlib import Path

from gaojixu.errors import AppError
from gaojixu.timeutil import cocoa_json, month_key, parse_instant, read_cocoa, start_of_day, week_start

OWNER = "com.gaojixu.savings"


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
    except (OSError, json.JSONDecodeError):
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
    except (OSError, json.JSONDecodeError):
        return False
    modules = marker.get("modules")
    expected = receipt.get("expectedModules")
    return (
        isinstance(marker, dict)
        and marker.get("schemaVersion") == 1
        and marker.get("ownerBundleID") == OWNER
        and marker.get("transactionID") == transaction
        and isinstance(modules, list)
        and isinstance(expected, list)
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
        connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
        try:
            rows = connection.execute("SELECT id, json FROM state").fetchall()
        finally:
            connection.close()
        if len(rows) != 1 or rows[0][0] != 1 or not isinstance(rows[0][1], (bytes, bytearray)):
            return "protected", None, "月供业务库行数不符，原文件未改。"
        payload = json.loads(bytes(rows[0][1]).decode("utf-8"))
        if not isinstance(payload, dict) or payload.get("schemaVersion") != 1 or payload.get("rulesVersion") != 1:
            return "protected", None, "月供业务库版本不受支持，原文件未改。"
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
    zone = getattr(now().tzinfo, "key", None) or "UTC"
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


def save_subscription(root: Path, payload: dict, now) -> dict:
    state = _require(root)
    name = str(payload.get("name") or "").strip()
    if not name:
        raise AppError("请填写订阅名称。", "invalid")
    try:
        price = float(payload.get("price"))
    except (TypeError, ValueError):
        price = 0
    if not price or price <= 0 or price > 999_999_999:
        raise AppError("请填写有效的正数金额。", "invalid")
    currency = payload.get("currency") or "CNY"
    if currency not in {"CNY", "USD", "EUR", "HKD", "JPY", "GBP"}:
        raise AppError("这个币种不在固定支出支持范围内。", "invalid")
    cycle = payload.get("cycle") or "monthly"
    if cycle not in {"weekly", "monthly", "quarterly", "yearly", "days"}:
        raise AppError("扣费周期无法识别。", "invalid")
    try:
        interval = int(payload.get("interval") or (30 if cycle == "days" else 1))
    except (TypeError, ValueError):
        interval = 0
    if not 1 <= interval <= 3650:
        raise AppError("周期间隔无效。", "invalid")
    start = parse_instant(payload.get("start"), now().tzinfo) if payload.get("start") else now()
    benefit = payload.get("benefit") or "none"
    if benefit not in {"none", "daily", "weekly"}:
        raise AppError("权益类型无法识别。", "invalid")
    existing = None
    if payload.get("id"):
        existing = next((row for row in state.get("subscriptions") or [] if str(row.get("id", "")).upper() == str(payload["id"]).upper()), None)
    if existing:
        plan = (existing.get("plans") or [{}])[-1]
        plan.update({
            "price": price, "currency": currency, "cycle": cycle, "interval": interval,
            "monthEnd": bool(payload.get("monthEnd")), "benefit": benefit,
        })
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
                "anchor": cocoa_json(start),
                "price": price,
                "currency": currency,
                "cycle": cycle,
                "interval": interval,
                "monthEnd": bool(payload.get("monthEnd")),
                "benefit": benefit,
            }],
            "autoRenew": bool(payload.get("autoRenew", True)),
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
    state["updatedAt"] = cocoa_json(now())
    _write_state(root, state)
    return row


def record_payment(root: Path, payload: dict, now, ledger_writer=None) -> dict:
    state = _require(root)
    subscription = next((row for row in state.get("subscriptions") or [] if str(row.get("id", "")).upper() == str(payload.get("subscriptionID", "")).upper()), None)
    if subscription is None:
        raise AppError("没有这项订阅。", "invalid")
    due = parse_instant(payload.get("due"), now().tzinfo) if payload.get("due") else now()
    paid = parse_instant(payload.get("paidAt"), now().tzinfo) if payload.get("paidAt") else now()
    plan = (subscription.get("plans") or [{}])[-1]
    try:
        amount = float(payload.get("amount") if payload.get("amount") is not None else plan.get("price") or 0)
    except (TypeError, ValueError):
        amount = 0
    if amount < 0:
        raise AppError("支付金额无效。", "invalid")
    day = start_of_day(due, now().tzinfo).strftime("%Y-%m-%d")
    payment_id = f"{subscription['id']}|{day}"
    if any(row.get("id") == payment_id for row in state.get("payments") or []):
        raise AppError("这一期已经记过，没有重复入账。", "duplicate")
    skipped = bool(payload.get("skipped"))
    payment = {
        "id": payment_id,
        "subscriptionID": subscription["id"],
        "due": cocoa_json(due),
        "paidAt": cocoa_json(paid),
        "recordedAt": cocoa_json(now()),
        "amount": 0 if skipped else amount,
        "currency": plan.get("currency") or "CNY",
        "skipped": skipped,
        "note": str(payload.get("note") or ""),
        "periods": 1,
    }
    state.setdefault("payments", []).append(payment)
    state["updatedAt"] = cocoa_json(now())
    _write_state(root, state)
    ledger_id = None
    if not skipped and ledger_writer and payload.get("accountID"):
        ledger_id = ledger_writer(payment, subscription)
    return {"payment": payment, "ledgerID": ledger_id}


def save_benefit(root: Path, payload: dict, now) -> dict:
    state = _require(root)
    name = str(payload.get("name") or "").strip()
    kind = payload.get("kind") or "daily"
    if not name or kind not in {"daily", "weekly"}:
        raise AppError("请填写权益名称，并选择每日或每周。", "invalid")
    subscription_id = payload.get("subscriptionID")
    if subscription_id and not any(str(row.get("id", "")).upper() == str(subscription_id).upper() for row in state.get("subscriptions") or []):
        raise AppError("关联的订阅不存在。", "invalid")
    row = {
        "id": new_id(),
        "name": name,
        "kind": kind,
        "createdAt": cocoa_json(now()),
        "archived": False,
        "note": str(payload.get("note") or ""),
    }
    if subscription_id:
        row["subscriptionID"] = str(subscription_id).upper()
    state.setdefault("benefits", []).append(row)
    state["updatedAt"] = cocoa_json(now())
    _write_state(root, state)
    return row


def claim_benefit(root: Path, benefit_id: str, now) -> dict:
    state = _require(root)
    benefit = next((row for row in state.get("benefits") or [] if str(row.get("id", "")).upper() == str(benefit_id).upper() and not row.get("archived")), None)
    if benefit is None:
        raise AppError("没有这项权益。", "invalid")
    moment = now()
    if benefit.get("kind") == "weekly":
        period = week_start(moment, moment.tzinfo).strftime("%Y-%m-%d")
    else:
        period = start_of_day(moment, moment.tzinfo).strftime("%Y-%m-%d")
    claim_id = f"{benefit['id']}|{benefit['kind']}|{period}"
    if any(row.get("id") == claim_id for row in state.get("claims") or []):
        return {"claimed": False, "id": claim_id}
    state.setdefault("claims", []).append({
        "id": claim_id,
        "subscriptionID": benefit.get("subscriptionID") or benefit["id"],
        "date": cocoa_json(moment),
        "recordedAt": cocoa_json(moment),
        "backfill": False,
    })
    state["updatedAt"] = cocoa_json(moment)
    _write_state(root, state)
    return {"claimed": True, "id": claim_id}


def summary(root: Path, tz, now=None):
    status, state, notice = load_state(root)
    if state is None:
        return {"status": status, "notice": notice, "subscriptions": [], "payments": [], "benefits": [], "claims": []}
    moment = now() if now else __import__("datetime").datetime.now(tz)
    subscriptions = []
    for row in state.get("subscriptions") or []:
        if not isinstance(row, dict):
            continue
        plan = (row.get("plans") or [{}])[-1] if isinstance(row.get("plans"), list) else {}
        subscriptions.append({
            "id": row.get("id"),
            "name": row.get("name"),
            "category": row.get("category"),
            "archived": bool(row.get("archived")),
            "price": plan.get("price"),
            "currency": plan.get("currency"),
            "cycle": plan.get("cycle"),
            "benefit": plan.get("benefit"),
            "note": row.get("note") or "",
        })
    payments = []
    for row in state.get("payments") or []:
        if not isinstance(row, dict):
            continue
        due = read_cocoa(row.get("due"), tz)
        payments.append({
            "id": row.get("id"),
            "subscriptionID": row.get("subscriptionID"),
            "amount": row.get("amount"),
            "currency": row.get("currency"),
            "skipped": bool(row.get("skipped")),
            "due": due.strftime("%Y-%m-%d") if due else "",
            "note": row.get("note") or "",
        })
    benefits = []
    claimed = {row.get("id") for row in state.get("claims") or [] if isinstance(row, dict)}
    daily_key = start_of_day(moment, tz).strftime("%Y-%m-%d")
    weekly_key = week_start(moment, tz).strftime("%Y-%m-%d")
    for row in state.get("benefits") or []:
        if not isinstance(row, dict) or row.get("archived"):
            continue
        period = weekly_key if row.get("kind") == "weekly" else daily_key
        benefits.append({
            "id": row.get("id"),
            "name": row.get("name"),
            "kind": row.get("kind"),
            "subscriptionID": row.get("subscriptionID"),
            "claimed": f"{row.get('id')}|{row.get('kind')}|{period}" in claimed,
        })
    return {
        "status": status,
        "notice": notice,
        "subscriptions": subscriptions,
        "payments": payments[-30:],
        "benefits": benefits,
        "claims": len(claimed),
        "monthKey": month_key(moment, tz),
    }
