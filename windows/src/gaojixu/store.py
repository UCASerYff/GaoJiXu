"""资料库生命周期。未知字段保留，损坏或更高版本不覆盖原文件。"""

from __future__ import annotations

import json
import os
import random
import re
import uuid
from datetime import datetime, timezone
from pathlib import Path

from gaojixu import adventure, adventure_view, catalog, csvutil, finance, monthly, widget
from gaojixu.errors import AppError
from gaojixu.timeutil import add_months, cocoa_json, in_zone, month_key, read_cocoa
from gaojixu.version import SCHEMA_VERSION, VERSION_LABEL

LIBRARY_NAME = "library.json"
READ_ONLY_MARKER = "library.json.read-only"
REQUIRED = ("version", "goals", "records", "adventure", "equipment", "techniques", "rewardEvents", "drawHistory")


def new_id() -> str:
    return str(uuid.uuid4()).upper()


def default_data_dir() -> Path:
    override = os.environ.get("GAOJIXU_DATA_DIR")
    if override:
        return Path(override)
    appdata = os.environ.get("APPDATA")
    if appdata:
        return Path(appdata) / "GaoSeries" / "Savings"
    xdg = os.environ.get("XDG_DATA_HOME")
    base = Path(xdg) if xdg else Path.home() / ".local" / "share"
    return base / "GaoSeries" / "Savings"


def dumps(payload: dict) -> bytes:
    text = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True)
    return (text + "\n").encode("utf-8")


class Store:
    def __init__(self, directory: Path | str, now=None, tz=None, rng=None, readonly: bool = False):
        self.directory = Path(directory)
        self.readonly = readonly
        self.tz = tz or datetime.now().astimezone().tzinfo or timezone.utc
        self._now = now or (lambda: datetime.now(self.tz))
        self.rng = rng or random.Random()
        self.doc = None
        self.status = "missing"
        self.notice = ""
        self.currency = "CNY"
        self.settings = {"appearance": "system", "language": "zh", "currency": "CNY",
                         "backgroundHex": "", "budgetRolloverEnabled": False}
        self.financial_revision = None
        self.persisted_fingerprint = None
        self.financial_updated_at = None
        self.source_saved_at = None
        self.finances_dirty = False
        self._load_settings()
        self.load()

    def now(self):
        current = self._now()
        if current.tzinfo is None:
            current = current.replace(tzinfo=self.tz)
        return current.astimezone(self.tz)

    def require_ready(self):
        if self.readonly or self.status != "ready" or self.doc is None:
            raise AppError(self.notice or "资料库不能写入。", "protected")

    def library_path(self) -> Path:
        return self.directory / LIBRARY_NAME

    def _load_settings(self):
        path = self.directory / "settings.json"
        if not path.is_file():
            return
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return
        if isinstance(payload, dict):
            self.settings.update(payload)
        if self.settings.get("currency") in catalog.CURRENCIES:
            self.currency = self.settings["currency"]

    def update_settings(self, payload: dict) -> dict:
        if self.status != "ready":
            self.require_ready()
        if payload.get("appearance") in {"system", "light", "dark"}:
            self.settings["appearance"] = payload["appearance"]
        if payload.get("language") in {"system", "zh", "en"}:
            self.settings["language"] = payload["language"]
        if payload.get("currency") in catalog.CURRENCIES:
            self.settings["currency"] = payload["currency"]
            self.currency = payload["currency"]
            self.finances_dirty = True
        tint = payload.get("backgroundHex")
        if isinstance(tint, str) and (not tint or re.fullmatch(r"#[0-9a-fA-F]{6}", tint)):
            self.settings["backgroundHex"] = tint
        rollover = payload.get("budgetRolloverEnabled", payload.get("budgetRollover"))
        if isinstance(rollover, bool):
            self.settings["budgetRolloverEnabled"] = rollover
        self._atomic(self.directory / "settings.json", dumps(self.settings))
        if self.status == "ready":
            widget.publish(self)
        return self.settings

    def load(self):
        marker = self.directory / READ_ONLY_MARKER
        path = self.library_path()
        if marker.exists():
            self.status = "protected"
            self.notice = "资料库处于只读保护，原文件未改动。"
            return
        if not path.exists():
            if _blank(self.directory):
                self.status = "missing"
                self.notice = ""
                return
            self._protect("资料目录已有其他文件，但没有 library.json。未把缺失当成空白库。")
            return
        try:
            raw = path.read_bytes()
            document = json.loads(raw.decode("utf-8"))
            if not isinstance(document, dict):
                raise ValueError("shape")
            version = document.get("version")
            if isinstance(version, bool) or not isinstance(version, int):
                raise ValueError("version")
            if version > SCHEMA_VERSION:
                self._protect(f"资料库版本 {version} 高于本程序支持的 schema {SCHEMA_VERSION}，未写入。")
                return
            for key in REQUIRED:
                if key not in document:
                    raise ValueError(key)
            if not isinstance(document.get("adventure"), dict):
                raise ValueError("adventure")
            for key in ("goals", "records", "equipment", "techniques", "rewardEvents", "drawHistory"):
                if not isinstance(document.get(key), list):
                    raise ValueError(key)
            _validate_fixed_income(document)
        except (OSError, UnicodeError, json.JSONDecodeError, ValueError, TypeError):
            self._protect("library.json 无法读取。原文件已保留，写入已停止。")
            return
        self.doc = document
        self.status = "ready"
        self._ensure_optional()
        changed = adventure.normalize_loaded(self)
        if version < 23 and finance.backfill_record_currency(self):
            changed = True
        if version < SCHEMA_VERSION:
            self.doc["version"] = SCHEMA_VERSION
            changed = True
        self.financial_updated_at = read_cocoa(self.doc.get("financialUpdatedAt"), self.tz)
        self.persisted_fingerprint = finance.financial_fingerprint(self)
        self.financial_revision = self.persisted_fingerprint
        if self.readonly:
            return
        if changed or self.finances_dirty:
            self.finances_dirty = True
            self.save()
        else:
            widget_file = self.directory / "gaojixu-widget.json"
            if not widget_file.exists():
                self.finances_dirty = True
                widget.publish(self)
                self.finances_dirty = False
        finance.materialize_recurring(self)

    def _ensure_optional(self):
        if self.doc.get("accounts") is None:
            moment = self.now()
            self.doc["accounts"] = [
                _account("现金", "cash", "green", moment, 0),
                _account("银行卡", "bank", "blue", moment, 1),
            ]
            self.finances_dirty = True
        for key in ("ledgerEntries", "budgets", "pets", "equippedPetIDs", "recurringRules", "fixedIncomePlans", "fixedIncomeReceipts"):
            if self.doc.get(key) is None:
                self.doc[key] = []

    def create_library(self) -> dict:
        if self.status == "ready":
            return {"created": False}
        if self.status == "protected" or (self.directory / READ_ONLY_MARKER).exists() or self.library_path().exists() or not _blank(self.directory):
            raise AppError(self.notice or "不能在已有资料上创建空白库。", "protected")
        self.doc = _starter(self)
        self.status = "ready"
        self.notice = ""
        self.persisted_fingerprint = None
        self.financial_updated_at = None
        self.finances_dirty = True
        self.save()
        return {"created": True}

    def mark_financial(self):
        self.finances_dirty = True

    def save(self):
        self.require_ready()
        fingerprint = finance.financial_fingerprint(self)
        if self.persisted_fingerprint is not None and fingerprint != self.persisted_fingerprint:
            self.financial_updated_at = self.now()
        self.doc["version"] = SCHEMA_VERSION
        self.doc["financialRevision"] = fingerprint
        if self.financial_updated_at is None:
            self.doc.pop("financialUpdatedAt", None)
        else:
            self.doc["financialUpdatedAt"] = cocoa_json(self.financial_updated_at)
        events = self.doc.get("rewardEvents")
        if isinstance(events, list) and len(events) > catalog.REWARD_CAP:
            self.doc["rewardEvents"] = events[:catalog.REWARD_CAP]
        history = self.doc.get("drawHistory")
        if isinstance(history, list) and len(history) > catalog.DRAW_CAP:
            self.doc["drawHistory"] = history[:catalog.DRAW_CAP]
        self._atomic(self.library_path(), dumps(self.doc))
        self.financial_revision = fingerprint
        self.persisted_fingerprint = fingerprint
        self.source_saved_at = datetime.fromtimestamp(self.library_path().stat().st_mtime, self.tz)
        if self.finances_dirty:
            widget.publish(self)
            self.finances_dirty = False

    def save_game(self):
        self.save()

    def save_preserve_finance_time(self):
        self.save()

    def _protect(self, notice: str):
        self.status = "protected"
        self.doc = None
        self.notice = notice
        if self.readonly:
            return
        marker = self.directory / READ_ONLY_MARKER
        if marker.exists():
            return
        try:
            self.directory.mkdir(parents=True, exist_ok=True)
            marker.write_text(notice + "\n", encoding="utf-8")
        except OSError:
            return

    def _atomic(self, path: Path, data: bytes):
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(path.name + ".tmp")
        temporary.write_bytes(data)
        os.replace(temporary, path)

    def goal_rows(self) -> list:
        rows = []
        for goal in finance.goals(self):
            balance = finance.goal_balance(self, goal)
            target = float(goal.get("targetAmount") or 0)
            rows.append({
                **{key: goal.get(key) for key in ("id", "title", "currency", "status", "notes", "symbol", "colorKey", "savingsAccountID")},
                "targetAmount": goal.get("targetAmount"),
                "startingAmount": goal.get("startingAmount"),
                "balance": balance,
                "progress": min(1, max(0, balance / target)) if target else 0,
                "deadline": _display_date(self, goal.get("deadline")),
            })
        return rows

    def adventure_snapshot(self, goal_rows=None):
        self.require_ready()
        if goal_rows is None:
            goal_rows = self.goal_rows()
        return adventure_view.snapshot(self, goal_rows)

    def snapshot(self) -> dict:
        if self.status == "ready":
            finance.materialize_recurring(self)
        monthly_view = monthly.summary(self.directory, self.tz, self.now)
        from gaojixu import monthly_bridge
        if self.status == "ready":
            try:
                monthly_bridge.flush_cleanup(self, monthly_view)
            except (AppError, OSError):
                self.notice = "月供自动流水尚待对账，恢复资料写入后将重试。"
            monthly_view["reconciliation"] = monthly_bridge.pending(self, monthly_view)
        base = {
            "status": self.status,
            "notice": self.notice,
            "version": VERSION_LABEL,
            "schema": SCHEMA_VERSION,
            "currency": self.currency,
            "today": self.now().date().isoformat(),
            "financeUpdatedAt": self.financial_updated_at.strftime("%Y-%m-%d %H:%M") if self.financial_updated_at else "",
            "settings": {key: self.settings[key] for key in ("appearance", "language", "currency", "backgroundHex", "budgetRolloverEnabled")},
            "monthly": monthly_view,
            "categories": [{"id": item[0], "name": item[1], "kind": item[2]} for item in catalog.CATEGORIES],
            "accountTypes": [{"id": key, "name": value[0]} for key, value in catalog.ACCOUNT_TYPES.items()],
            "currencies": [{"id": key, "name": value[0], "symbol": value[1]} for key, value in catalog.CURRENCIES.items()],
        }
        if self.status != "ready" or self.doc is None:
            return base
        currency = self.currency
        adventure_state = self.doc.get("adventure") or {}
        goal_rows = self.goal_rows()
        return {
            **base,
            "lastLedgerAccountID": self.doc.get("lastLedgerAccountID"),
            "financeRevision": self.financial_revision,
            "summary": {
                "netWorth": finance.net_worth(self, currency),
                "monthIncome": finance.month_income(self, currency),
                "monthExpense": finance.month_expense(self, currency),
                "monthKey": month_key(self.now(), self.tz),
                "deposited": finance.deposited_this_month(self, currency),
                "streak": finance.saving_streak(self),
                "level": adventure_state.get("level"),
                "coins": adventure_state.get("coins"),
                "tickets": adventure_state.get("tickets"),
                "stardust": adventure_state.get("stardust"),
                "insight": adventure_state.get("insight"),
            },
            "accounts": [_public_account(self, row) for row in finance.accounts(self)],
            "entries": [_public_entry(self, row) for row in finance.entries(self)[:300]],
            "budgets": [
                {**row, "spent": finance.category_expense(self, row.get("categoryID"), row.get("monthKey"), row.get("currency"))}
                for row in finance.budgets(self)
            ],
            "goals": goal_rows,
            "records": [_public_record(self, row) for row in finance.records(self)[:300]],
            "recurring": [
                {**row, "nextDue": _display_date(self, row.get("nextDueDate"))}
                for row in finance.rules(self)
            ],
            "fixedIncome": {
                "categories": {key: catalog.category_name(key) for key in sorted(catalog.FIXED_INCOME_CATEGORIES)},
                "plans": list(self.doc.get("fixedIncomePlans") or []),
                "receipts": [
                    {**row, "received": _display_date(self, row.get("receivedOn")),
                     "ledgerStatus": _fixed_income_ledger_status(self, row)}
                    for row in self.doc.get("fixedIncomeReceipts") or []
                ],
            },
            "adventure": self.adventure_snapshot(goal_rows),
            "days": finance.daily_summary(self, currency),
        }

    def search_catalog(self, kind: str, query: str = "", slot: str = "") -> list:
        query = (query or "").strip()
        if kind == "equipment":
            source = catalog.EQUIPMENT
            if slot:
                source = [item for item in source if item.slot == slot]
            if query:
                source = [item for item in source if query in item.name or query in item.id]
            return [{"id": item.id, "name": item.name, "slot": item.slot, "rarity": item.rarity} for item in source[:40]]
        if kind == "technique":
            source = catalog.TECHNIQUES
            if query:
                source = [item for item in source if query in item.name or query in item.id]
            return [{"id": item.id, "name": item.name, "rarity": item.rarity, "school": item.school} for item in source[:40]]
        return []

    def counts(self) -> dict:
        if self.doc is None:
            return {"accounts": 0, "entries": 0, "goals": 0, "records": 0, "level": 0}
        adventure_state = self.doc.get("adventure") or {}
        return {
            "accounts": len(self.doc.get("accounts") or []),
            "entries": len(self.doc.get("ledgerEntries") or []),
            "goals": len(self.doc.get("goals") or []),
            "records": len(self.doc.get("records") or []),
            "level": adventure_state.get("level") or 0,
        }

    def export_ledger(self) -> str:
        self.require_ready()
        return csvutil.export_ledger(self)

    def import_ledger(self, text: str) -> dict:
        return csvutil.import_ledger(self, text)

    def create_monthly(self):
        self.require_ready()
        state = monthly.create_new(self.directory, self.now)
        return {"created": True, "subscriptions": len(state.get("subscriptions") or [])}

def _blank(directory: Path) -> bool:
    if not directory.exists():
        return True
    for entry in directory.iterdir():
        if entry.name in {".DS_Store", READ_ONLY_MARKER} or entry.name.startswith(".com.apple."):
            continue
        return False
    return True


def _validate_fixed_income(document: dict):
    plans = document.get("fixedIncomePlans") or []
    receipts = document.get("fixedIncomeReceipts") or []
    if plans is None:
        plans = []
    if not isinstance(plans, list) or not isinstance(receipts, list):
        raise ValueError("fixed income")
    plan_ids = [str(row.get("id")) for row in plans if isinstance(row, dict)]
    receipt_ids = [str(row.get("planID")) + "|" + str(row.get("month")) for row in receipts if isinstance(row, dict)]
    if len(plan_ids) != len(set(plan_ids)) or len(receipt_ids) != len(set(receipt_ids)):
        raise ValueError("duplicate fixed income")


def _account(name, account_type, color, moment, offset):
    from datetime import timedelta
    created = moment + timedelta(seconds=offset)
    return {
        "id": new_id(),
        "name": name,
        "type": account_type,
        "currency": "CNY",
        "openingBalance": 0,
        "symbol": catalog.ACCOUNT_TYPES[account_type][1],
        "colorKey": color,
        "includeInNetWorth": True,
        "isArchived": False,
        "createdAt": cocoa_json(created),
    }


def _starter(store: Store) -> dict:
    moment = store.now()
    goal_deadline = add_months(moment, 6, in_zone(moment, store.tz).day, store.tz)
    return {
        "accounts": [
            _account("现金", "cash", "green", moment, 0),
            _account("银行卡", "bank", "blue", moment, 1),
        ],
        "adventure": {
            "attackCount": 0,
            "battleAttempts": 0,
            "coins": 10000,
            "defeatedMonsters": 0,
            "equippedArmorID": "cloth-vest",
            "equippedItems": {"chest": "cloth-vest", "mainHand": "wood-sword"},
            "equippedTechniqueIDs": ["steady-heart"],
            "equippedWeaponID": "wood-sword",
            "experience": 0,
            "insight": 10000,
            "lastBattleMessage": "每秒自动战斗，失败会在原关重开",
            "level": 1,
            "monsterHP": catalog.MONSTERS[0].max_hp,
            "monsterIndex": 0,
            "pityCount": 0,
            "stardust": 10000,
            "tickets": 10000,
        },
        "budgets": [],
        "drawHistory": [],
        "equipment": [
            {"count": 1, "definitionID": "wood-sword"},
            {"count": 1, "definitionID": "cloth-vest"},
        ],
        "equippedPetIDs": [],
        "fixedIncomePlans": [],
        "fixedIncomeReceipts": [],
        "goals": [{
            "id": new_id(),
            "title": "第一桶金",
            "targetAmount": 10000,
            "startingAmount": 0,
            "currency": "CNY",
            "deadline": cocoa_json(goal_deadline),
            "symbol": "flag.checkered",
            "colorKey": "blue",
            "notes": "从第一笔目标分配开始，让勇者陪你抵达目标。",
            "status": "active",
            "createdAt": cocoa_json(moment),
        }],
        "ledgerEntries": [],
        "pets": [],
        "records": [],
        "recurringRules": [],
        "rewardEvents": [{
            "id": new_id(),
            "date": cocoa_json(moment),
            "title": "冒险开始",
            "detail": "记账整理生活，给目标分配积蓄，勇者便会随你成长。",
            "symbol": "sparkles",
        }],
        "techniques": [{"level": 1, "techniqueID": "steady-heart"}],
        "version": SCHEMA_VERSION,
    }


def _public_account(store, row):
    return {
        "id": row.get("id"),
        "name": row.get("name"),
        "type": row.get("type"),
        "currency": row.get("currency"),
        "archived": bool(row.get("isArchived")),
        "includeInNetWorth": bool(row.get("includeInNetWorth")),
        "balance": finance.account_balance(store, row),
        "contribution": finance.net_worth_contribution(store, row),
        "symbol": row.get("symbol"),
        "colorKey": row.get("colorKey"),
    }


def _public_entry(store, row, account_index=None, savings_entry_ids=None):
    source = (account_index.get(row.get("accountID")) if account_index is not None
              else finance.account(store, row.get("accountID")))
    target = (account_index.get(row.get("targetAccountID")) if account_index is not None
              else finance.account(store, row.get("targetAccountID")))
    if savings_entry_ids is None:
        savings_entry_ids = {record.get("ledgerEntryID") for record in finance.records(store)}
    return {
        "id": row.get("id"),
        "kind": row.get("kind"),
        "accountID": row.get("accountID"),
        "accountName": (source or {}).get("name") or "已归档账户",
        "targetAccountID": row.get("targetAccountID"),
        "targetAccountName": (target or {}).get("name") or "",
        "targetCurrency": (target or {}).get("currency"),
        "amount": row.get("amount"),
        "targetAmount": row.get("targetAmount"),
        "categoryID": row.get("categoryID"),
        "categoryName": catalog.category_name(row.get("categoryID") or ""),
        "note": row.get("note") or "",
        "date": _display_date(store, row.get("date")),
        "timestamp": row.get("date"),
        "currency": (source or {}).get("currency") or "CNY",
        "balanceAdjustment": row.get("categoryID") == "balance-adjustment",
        "savings": row.get("id") in savings_entry_ids,
    }


def _public_record(store, row):
    goal = next((item for item in finance.goals(store) if item.get("id") == row.get("goalID")), None)
    return {
        "id": row.get("id"),
        "goalID": row.get("goalID"),
        "goalTitle": (goal or {}).get("title") or "",
        "kind": row.get("kind"),
        "amount": row.get("amount"),
        "category": row.get("category"),
        "categoryName": catalog.SAVINGS_CATEGORIES.get(row.get("category"), row.get("category")),
        "note": row.get("note") or "",
        "date": _display_date(store, row.get("date")),
        "timestamp": row.get("date"),
        "currency": row.get("currency") or (goal or {}).get("currency") or "CNY",
        "fundingAccountID": row.get("fundingAccountID"),
        "savingsAccountID": row.get("savingsAccountID"),
    }


def _display_date(store, value) -> str:
    when = read_cocoa(value, store.tz)
    if when is None:
        return ""
    local = in_zone(when, store.tz)
    return local.strftime("%Y-%m-%d %H:%M")


def _fixed_income_ledger_status(store, receipt) -> str:
    entry_id = f"fixed-income|{str(receipt.get('planID')).lower()}|{receipt.get('month')}"
    entry = next((row for row in finance.entries(store) if row.get("id") == entry_id), None)
    if entry is None:
        return "原流水已删除，保留确认记录"
    pairs = (("amount", "amount"), ("accountID", "accountID"), ("date", "receivedOn"), ("categoryID", "category"))
    if entry.get("kind") == "income" and all(entry.get(key) == receipt.get(value) for key, value in pairs):
        return "已入账"
    return "原流水已调整"


def post_monthly_to_ledger(store: Store, payment: dict, subscription: dict, account_id: str):
    store.require_ready()
    entry_id = f"auto-monthly|{payment['id']}"
    existing = next((row for row in finance.entries(store) if row.get("id") == entry_id), None)
    owner = finance.account(store, account_id)
    currency = payment.get("currency")
    if owner is None or owner.get("isArchived") or owner.get("currency") != currency:
        raise AppError("请选择一个仍在使用、且与订阅同币种的扣款账户。", "invalid")
    when = read_cocoa(payment.get("paidAt"), store.tz) or store.now()
    updated = {
        **(existing or {}),
        "id": entry_id,
        "kind": "expense",
        "accountID": owner["id"],
        "amount": payment.get("amount"),
        "categoryID": "subscription",
        "date": cocoa_json(when),
        "note": f"月供·{subscription.get('name') or '订阅'}",
        "createdAt": (existing or {}).get("createdAt", cocoa_json(store.now())),
    }
    if existing == updated:
        return entry_id
    if existing is None:
        finance._insert_entry(store, updated)
    else:
        existing.update(updated)
    store.mark_financial()
    store.save()
    return entry_id
