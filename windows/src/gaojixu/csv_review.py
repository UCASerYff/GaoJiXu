"""Stage, review and commit statement imports without writing partial batches."""

from __future__ import annotations

from collections import defaultdict
from copy import copy, deepcopy
import csv
from dataclasses import dataclass
from datetime import datetime
from decimal import Decimal
import hashlib
import io
import json
import re
import unicodedata

from gaojixu import catalog, finance
from gaojixu.errors import AppError
from gaojixu.money import currency_digits, money
from gaojixu.timeutil import read_cocoa, unix_minute

KEY = "windowsCSVReview"
MAX_ROWS = 2000
MAX_TEXT = 2_000_000
FIELDS = ("date", "kind", "accountName", "targetAccountName", "categoryName", "note",
          "amount", "currency", "targetAmount", "targetCurrency")
HEADERS = {
    "date": ("日期", "时间", "交易日期", "交易时间", "记账日期", "date", "datetime", "timestamp", "transaction date"),
    "kind": ("类型", "交易类型", "方向", "收支", "kind", "type", "direction"),
    "accountName": ("账户", "来源账户", "转出账户", "账户名称", "account", "account name", "source account", "accountName"),
    "targetAccountName": ("目标账户", "转入账户", "对方账户", "target account", "destination account", "targetAccountName"),
    "categoryName": ("分类", "类别", "category", "categoryName"),
    "note": ("备注", "说明", "摘要", "描述", "note", "memo", "description"),
    "amount": ("金额", "交易金额", "原币金额", "转出金额", "amount", "signed amount", "source amount"),
    "currency": ("币种", "货币", "原币币种", "转出币种", "currency", "source currency"),
    "targetAmount": ("转入金额", "目标金额", "target amount", "destination amount", "received amount"),
    "targetCurrency": ("转入币种", "目标币种", "target currency", "destination currency", "received currency"),
}
KINDS = {
    "支出": "expense", "expense": "expense", "debit": "expense", "outflow": "expense",
    "收入": "income", "income": "income", "credit": "income", "inflow": "income",
    "转账": "transfer", "转帐": "transfer", "账户互转": "transfer", "transfer": "transfer",
    "转出": "expense", "转账转出": "expense", "transfer out": "expense", "transfer-out": "expense",
    "转入": "income", "转账转入": "income", "transfer in": "income", "transfer-in": "income",
}
LEGS = {"转出", "转账转出", "transfer out", "transfer-out", "转入", "转账转入", "transfer in", "transfer-in"}
TRANSFER_CATEGORIES = {"转账", "转帐", "账户互转", "transfer", "account-transfer"}
TRANSFER_WORD = re.compile(r"转账|转帐|互转|转入|转出|\b(?:transfer|xfer)\b", re.I)
NUMBER = re.compile(r"[+-]?(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(?:\.[0-9]+)?\Z")
MAX_AMOUNT = Decimal("999999999999.99")
SYMBOLS = {
    "¥": {"CNY", "JPY"}, "$": {"USD", "HKD", "TWD", "SGD", "AUD", "CAD"},
    "€": {"EUR"}, "£": {"GBP"}, "₩": {"KRW"},
}


def _normalized(text):
    return unicodedata.normalize("NFKC", text).strip()


def _heading(text):
    return re.sub(r"[\s_-]", "", _normalized(text).casefold())


HEADER_INDEX = {_heading(alias): key for key, aliases in HEADERS.items() for alias in aliases}


def _digest(value):
    encoded = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _book(store):
    if store.status != "ready" or store.doc is None:
        raise AppError(store.notice or "资料库无法读取。", "protected")
    if KEY not in store.doc:
        return {}
    value = store.doc[KEY]
    if not isinstance(value, dict) or value.get("version") != 1 or not isinstance(value.get("batches"), dict):
        raise AppError("导入审核记录无法读取，原资料已保留。", "csv-review-protected")
    return value["batches"]


def _lookup(store, batch_id):
    item = _book(store).get(batch_id) if isinstance(batch_id, str) else None
    if not item:
        raise AppError("没有找到这个导入批次。", "csv-review-not-found")
    return item


def _save_draft(store, draft, updated_batch):
    # The library replace commits both the ledger and its receipt. A later snapshot failure
    # must not roll back the in-memory receipt after the ledger is already on disk.
    previous = vars(store).copy()
    store.doc = draft.doc
    store.finances_dirty = draft.finances_dirty
    try:
        store.save()
    except OSError:
        try:
            committed = json.loads(store.library_path().read_bytes()).get(KEY, {}).get("batches", {}).get(updated_batch["id"])
        except (OSError, ValueError, TypeError, AttributeError):
            committed = None
        if committed == updated_batch:
            store.notice = "导入审核已保存。财务快照将在后续写入时刷新。"
            return
        vars(store).update(previous)
        raise


def _draft(store):
    draft = copy(store)
    draft.doc = deepcopy(store.doc)
    draft.save = lambda: None
    return draft


def _date(value, timezone):
    if not value:
        return None, "missing-date", False
    try:
        when = datetime.fromisoformat(value.removesuffix("Z") + "+00:00" if value.endswith("Z") else value)
        if when.tzinfo is not None:
            when.astimezone(timezone)
            return when.isoformat(), None, False
        first, second = when.replace(tzinfo=timezone, fold=0), when.replace(tzinfo=timezone, fold=1)
        if first.utcoffset() != second.utcoffset():
            return None, "ambiguous-local-time", False
        return first.isoformat(), None, True
    except (ValueError, OverflowError, OSError):
        return None, "invalid-date", False


def _stamp(row, timezone):
    row["timestamp"], row["dateProblem"], row["dateLocal"] = _date(row["values"]["date"], timezone)
    row["dateTimezone"] = _zone_name(timezone) if row["dateLocal"] else None


def _zone_name(timezone):
    return getattr(timezone, "key", None) or str(timezone)


def _parse(text, timezone):
    if not isinstance(text, str) or not text.strip() or "\0" in text:
        raise AppError("请选择含有效流水的 CSV 文件。", "csv-review-empty")
    if len(text) > MAX_TEXT:
        raise AppError("CSV 文件过大，请拆成较小的批次。", "csv-review-limit")
    records = []
    reader = csv.reader(io.StringIO(text.removeprefix("\ufeff"), newline=""), strict=True)
    try:
        while True:
            start = reader.line_num + 1
            cells = next(reader, None)
            if cells is None:
                break
            if any(value.strip() for value in cells):
                records.append((start, [value.strip() for value in cells]))
            if len(records) > MAX_ROWS + 1 or len(cells) > 100:
                raise AppError(f"每批最多审核 {MAX_ROWS} 行，请拆分 CSV。", "csv-review-limit")
    except csv.Error as exc:
        raise AppError("CSV 的引号或列格式无法读取。", "csv-review-format") from exc
    if not records:
        raise AppError("CSV 中没有可审核的流水。", "csv-review-empty")
    positions = [HEADER_INDEX.get(_heading(field)) for field in records[0][1]]
    known = [field for field in positions if field]
    if len(known) >= 2:
        if len(set(known)) != len(known):
            raise AppError("CSV 中有重复列名，请为每一列保留唯一列名。", "csv-review-format")
        records = records[1:]
    elif len(positions) >= 8 and _date(records[0][1][0], timezone)[0]:
        positions = list(FIELDS[:8])
    else:
        raise AppError("未识别 CSV 列名，请至少提供两项可识别的流水列。", "csv-review-header")
    if not records:
        raise AppError("CSV 中没有可审核的流水。", "csv-review-empty")
    if len(records) > MAX_ROWS:
        raise AppError(f"每批最多审核 {MAX_ROWS} 行，请拆分 CSV。", "csv-review-limit")
    rows = []
    for index, (line, cells) in enumerate(records, 1):
        values = dict.fromkeys(FIELDS, "")
        for field, value in zip(positions, cells):
            if field:
                values[field] = value
        row = {"id": str(index), "line": line, "status": "pending", "values": values,
               "extra": any(cells[len(positions):])}
        _stamp(row, timezone)
        rows.append(row)
    return rows


def _number(raw, code, target=False):
    prefix = "target-" if target else ""
    if not raw:
        return None, "", "missing-target-amount" if target else "missing-amount"
    value = _normalized(raw).replace("−", "-")
    if value.startswith("(") and value.endswith(")"):
        value = "-" + value[1:-1].strip()
    sign = value[0] if value.startswith(("+", "-")) else ""
    body = value[1:] if sign else value
    symbol = body[:1]
    if symbol in SYMBOLS:
        if code and code not in SYMBOLS[symbol]:
            return None, sign, "invalid-" + prefix + "amount"
        body = body[1:].strip()
        if not sign and body.startswith(("+", "-")):
            sign, body = body[0], body[1:]
    if not NUMBER.fullmatch(sign + body):
        return None, sign, "invalid-" + prefix + "amount"
    amount = Decimal(body.replace(",", "")).copy_abs()
    if not amount or amount > MAX_AMOUNT or target and sign == "-":
        return None, sign, "invalid-" + prefix + "amount"
    quantum = Decimal("1").scaleb(-currency_digits(code))
    if amount != amount.quantize(quantum):
        return None, sign, prefix + "amount-precision"
    return amount, sign, None


@dataclass(frozen=True)
class Account:
    id: str | None
    name: str
    currency: str

    @property
    def key(self):
        return self.id or (self.name, self.currency)


@dataclass
class Item:
    row: dict
    source: Account | None
    target: Account | None
    when: datetime | None
    amount: Decimal | None
    target_amount: Decimal | None
    category: str | None
    kind: str
    has_transfer_evidence: bool
    problems: list
    notices: list
    duplicates: list


def _account_index(store):
    result = defaultdict(list)
    for row in finance.accounts(store):
        result[row.get("name")].append(row)
    return result


def _account_for(index, name, code, *, target=False):
    if not name:
        return None, "missing-target-account" if target else "missing-account"
    matches = index.get(name, ())
    active = [candidate for candidate in matches if not candidate.get("isArchived")]
    if code and code not in catalog.CURRENCIES:
        return None, "invalid-currency"
    if code:
        matching_currency = [candidate for candidate in active if candidate.get("currency") == code]
        if active and not matching_currency:
            return None, "target-currency-mismatch" if target else "currency-mismatch"
        active = matching_currency
    if len(active) > 1:
        return None, "ambiguous-account"
    if active:
        candidate = active[0]
        if candidate.get("currency") not in catalog.CURRENCIES:
            return None, "invalid-currency"
        return Account(candidate["id"], name, candidate["currency"]), None
    if matches:
        return None, "archived-account"
    if not code:
        return None, "missing-target-currency" if target else "missing-currency"
    return Account(None, name, code), None


def _prepare(row, account_index):
    values = row["values"]
    source, source_error = _account_for(account_index, values["accountName"], values["currency"].upper())
    amount, sign, amount_error = _number(values["amount"], source.currency if source else values["currency"].upper())
    raw_kind = _normalized(values["kind"]).casefold()
    kind = KINDS.get(raw_kind, "")
    kind_error = None
    if not kind:
        if not raw_kind and sign in {"+", "-"}:
            kind = "expense" if sign == "-" else "income"
        else:
            kind_error = "invalid-kind" if raw_kind else "missing-kind"
    elif (kind, sign) in {("expense", "+"), ("income", "-"), ("transfer", "+")}:
        kind_error = "direction-conflict"
    problems = [problem for problem in (row["dateProblem"], source_error, amount_error, kind_error) if problem]
    if row["extra"]:
        problems.append("extra-columns")
    notices = ["local-time"] if row["dateLocal"] else []
    if source and not source.id:
        notices.append("new-account")
    target, target_amount, category = None, None, None
    transfer_category = _normalized(values["categoryName"]).casefold() in TRANSFER_CATEGORIES
    if kind == "transfer":
        category = "account-transfer"
        target, target_error = _account_for(account_index, values["targetAccountName"],
                                            values["targetCurrency"].upper(), target=True)
        if target_error:
            problems.append(target_error)
        if target and not target.id:
            notices.append("new-target-account")
        if source and target:
            if source.key == target.key or source.name == target.name and not (source.id and target.id):
                problems.append("same-account")
            if values["targetAmount"] or source.currency != target.currency:
                target_amount, _, target_amount_error = _number(values["targetAmount"], target.currency, target=True)
                if target_amount_error:
                    problems.append(target_amount_error)
                elif source.currency == target.currency and amount != target_amount:
                    problems.append("same-currency-amount-mismatch")
            else:
                target_amount = amount
    elif kind in {"expense", "income"}:
        if raw_kind in LEGS or transfer_category:
            problems.append("transfer-leg")
        if transfer_category:
            category = "account-transfer"
        elif not values["categoryName"]:
            category = "other-" + kind
            notices.append("default-category")
        else:
            found = catalog.CATEGORY_BY_NAME.get(values["categoryName"]) or catalog.CATEGORY_BY_ID.get(values["categoryName"])
            if found and found[2] == kind:
                category = found[0]
            else:
                problems.append("invalid-category")
    evidence = raw_kind in LEGS or transfer_category or bool(TRANSFER_WORD.search(values["note"]))
    when = datetime.fromisoformat(row["timestamp"]) if row["timestamp"] else None
    return Item(row, source, target, when, amount, target_amount, category, kind, evidence, problems, notices, [])


def _note(value):
    return " ".join(_normalized(value).casefold().split())


def _keys(when, timezone, kind, source, amount, note, category, target, target_amount, currency):
    day = (when.astimezone(timezone).date(), kind, source, currency, amount, target, target_amount)
    minute = (unix_minute(when), *day[1:], _note(note), category)
    return day, minute


def _item_keys(item, timezone):
    if not item.when or not item.source or not item.amount or not item.kind or item.kind == "transfer" and not item.target:
        return None
    return _keys(item.when, timezone, item.kind, item.source.key, item.amount, item.row["values"]["note"],
                 item.category, item.target.key if item.target else None, item.target_amount, item.source.currency)


def _ledger_keys(store):
    currencies = {row.get("id"): row.get("currency") for row in finance.accounts(store)}
    index = defaultdict(list)
    for entry in finance.entries(store):
        source, target = entry.get("accountID"), entry.get("targetAccountID")
        when = read_cocoa(entry.get("date"), store.tz)
        if not when or not source:
            continue
        amount = money(entry.get("amount"))
        target_amount = money(entry.get("targetAmount") if entry.get("targetAmount") is not None else amount) if target else None
        day, minute = _keys(when, store.tz, entry.get("kind"), source, amount, entry.get("note") or "",
                            entry.get("categoryID"), target, target_amount, currencies.get(source))
        index[day].append((minute, entry["id"]))
    return index


def _ledger_duplicates(keys, ledger):
    if not keys:
        return []
    day, minute = keys
    found = sorted(ledger.get(day, ()), key=lambda row: row[0] != minute)
    return [{"code": "ledger-exact" if other == minute else "ledger-same-day", "entryID": entry}
            for other, entry in found[:5]]


def _memo(item, matched):
    memo = item.row["values"]["note"]
    if matched:
        counterpart = matched.row["values"]["note"]
        if counterpart and counterpart != memo:
            return " · ".join(part for part in (memo, counterpart) if part)
    return memo


def _pairs(items, timezone, ledger, batch_keys):
    grouped = defaultdict(lambda: {"expense": [], "income": []})
    for item in items:
        if (item.row["status"] == "pending" and item.kind in {"expense", "income"} and item.has_transfer_evidence
                and item.source and item.source.id and item.when and item.amount
                and set(item.problems) <= {"transfer-leg", "invalid-category"}):
            grouped[(item.when.astimezone(timezone).date(), item.amount, item.source.currency)][item.kind].append(item)
    result = {}
    for group in grouped.values():
        # More than one candidate on either side can encode several valid pairings.
        # Decline the whole group instead of suggesting an arbitrary match.
        if len(group["expense"]) != 1 or len(group["income"]) != 1:
            continue
        expense, income = group["expense"][0], group["income"][0]
        if (expense.source.id == income.source.id
                or expense.row["values"]["targetAccountName"] not in {"", income.source.name}
                or income.row["values"]["targetAccountName"] not in {"", expense.source.name}
                or expense.row["values"]["targetCurrency"].upper() not in {"", income.source.currency}
                or income.row["values"]["targetCurrency"].upper() not in {"", expense.source.currency}):
            continue
        pair_id = expense.row["id"] + ":" + income.row["id"]
        keys = _keys(expense.when, timezone, "transfer", expense.source.key, expense.amount, _memo(expense, income),
                     "account-transfer", income.source.key, income.amount, expense.source.currency)
        prior = _ledger_duplicates(keys, ledger) + _batch_duplicates(keys, batch_keys)
        for item in (expense, income):
            item.duplicates.extend(reason for reason in prior if reason not in item.duplicates)
        result[pair_id] = {
            "id": pair_id, "expenseID": expense.row["id"], "incomeID": income.row["id"],
            "reason": "unique-transfer", "amount": _amount_text(expense.amount, expense.source.currency),
            "currency": expense.source.currency, "duplicates": prior,
        }
    return result


def _batch_duplicates(keys, seen):
    day, minute = keys
    previous = sorted(seen.get(day, ()), key=lambda row: row[0] != minute)
    return [{"code": "batch-exact" if other == minute else "batch-same-day", "line": line}
            for other, line in previous[:5]]


def _analysis(store, batch, indices=None):
    names, ledger = indices if indices is not None else (_account_index(store), _ledger_keys(store))
    items = {row["id"]: _prepare(row, names) for row in batch["rows"]}
    seen = defaultdict(list)
    for item in items.values():
        if item.row["status"] != "pending":
            continue
        keys = _item_keys(item, store.tz)
        item.duplicates = _ledger_duplicates(keys, ledger)
        if keys and set(item.problems) <= {"transfer-leg", "invalid-category"}:
            day, minute = keys
            item.duplicates.extend(_batch_duplicates(keys, seen))
            seen[day].append((minute, item.row["line"]))
    return items, _pairs(items.values(), store.tz, ledger, seen)


def _amount_text(amount, code):
    return f"{amount:.{currency_digits(code)}f}" if amount is not None else ""


def _row(item):
    values, status = item.row["values"], item.row["status"]
    source_currency = item.source.currency if item.source else values["currency"].upper()
    target_currency = item.target.currency if item.target else values["targetCurrency"].upper()
    return {
        **values, "id": item.row["id"], "line": item.row["line"], "status": status, "values": values.copy(),
        "date": item.row["timestamp"] or values["date"], "kind": item.kind or values["kind"],
        "amount": _amount_text(item.amount, source_currency) or values["amount"], "currency": source_currency,
        "targetAmount": _amount_text(item.target_amount, target_currency) or values["targetAmount"], "targetCurrency": target_currency,
        "categoryName": catalog.category_name(item.category) if item.category else values["categoryName"],
        "dateTimezone": item.row.get("dateTimezone"),
        "notices": item.notices if status == "pending" else [], "problems": item.problems if status == "pending" else [],
        "duplicates": item.duplicates if status == "pending" else [], "canApply": status == "pending" and not item.problems,
        "entryID": item.row.get("entryID"),
    }


def _revision(store, batch):
    return str(batch["version"]) + ":" + _digest([store.financial_revision, _zone_name(store.tz)])


def _summary(store, batch, items):
    counts = dict.fromkeys(("pending", "applied", "skipped", "undone", "duplicates", "blocked", "entries"), 0)
    counts["total"] = len(items)
    for item in items:
        status = item.row["status"]
        counts[status] += 1
        if status == "pending":
            counts["duplicates"] += bool(item.duplicates)
            counts["blocked"] += bool(item.problems)
    counts["entries"] = len(batch["entries"])
    if counts["pending"]:
        status = "partial" if counts["applied"] or counts["skipped"] or counts["undone"] else "pending"
    else:
        status = "applied" if counts["applied"] else "undone" if counts["undone"] else "resolved"
    return {"id": batch["id"], "name": batch["name"], "status": status, "revision": _revision(store, batch),
            "createdAt": batch["createdAt"], "timezone": _zone_name(store.tz),
            "createdTimezone": batch["timezone"], "counts": counts,
            "canUndo": bool(batch["entries"])}


def _detail(store, batch):
    items, pairs = _analysis(store, batch)
    return {"batch": _summary(store, batch, list(items.values())), "rows": [_row(item) for item in items.values()],
            "pairs": list(pairs.values())}


def list_batches(store):
    batches = sorted(_book(store).values(), key=lambda batch: batch["createdAt"], reverse=True)
    indices = (_account_index(store), _ledger_keys(store))
    return {"batches": [_summary(store, batch, list(_analysis(store, batch, indices)[0].values())) for batch in batches]}


def detail(store, batch_id):
    return _detail(store, _lookup(store, batch_id))


def stage(store, payload):
    store.require_ready()
    rows = _parse(payload.get("text"), store.tz)
    batch_id = _digest([[row["values"], row["extra"]] for row in rows])
    if batch_id in _book(store):
        return detail(store, batch_id)
    name = payload.get("name")
    name = name.strip()[:160] if isinstance(name, str) else ""
    batch = {"id": batch_id, "name": name or "CSV", "createdAt": store.now().isoformat(),
             "timezone": _zone_name(store.tz), "rows": rows, "entries": {},
             "version": 1, "requests": []}
    draft = _draft(store)
    draft.doc.setdefault(KEY, {"version": 1, "batches": {}})["batches"][batch_id] = batch
    _save_draft(store, draft, batch)
    return _detail(store, batch)


def _validated_request(store, payload, action):
    store.require_ready()
    batch = _lookup(store, payload.get("batchID"))
    if payload.get("confirmed") is not True:
        raise AppError("请先确认审核操作。", "csv-review-confirmation")
    digest = _digest([action, payload])
    if digest in batch["requests"]:
        return batch, digest, True
    if payload.get("revision") != _revision(store, batch):
        raise AppError("审核内容或账本已更新，请重新读取批次后确认。", "csv-review-stale")
    return batch, digest, False


def _remember(batch, digest):
    batch["version"] += 1
    batch["requests"] = [*batch["requests"][-255:], digest]


def _edits(batch, overrides, timezone):
    if not isinstance(overrides, dict):
        raise AppError("审核修改格式无法读取。", "csv-review-decision")
    pending = {row["id"]: row for row in batch["rows"] if row["status"] == "pending"}
    for row_id, patch in overrides.items():
        if row_id not in pending or not isinstance(patch, dict) or set(patch) - set(FIELDS):
            raise AppError("只能修改批次中待审核的流水。", "csv-review-decision")
        row = pending[row_id]
        for column, value in patch.items():
            if not isinstance(value, str) or "\0" in value or len(value) > 2000:
                raise AppError("审核修改中的字段无法读取。", "csv-review-decision")
            row["values"][column] = value.strip()
        if "date" in patch:
            _stamp(row, timezone)


def _account_id(draft, selected, created, names):
    if selected.id:
        return selected.id
    if selected.name in names and names[selected.name] != selected.currency:
        raise AppError("同一新账户名称对应多个币种，请先核对并区分账户。", "csv-review-account")
    if selected.key not in created:
        names[selected.name] = selected.currency
        created[selected.key] = finance.save_account(
            draft, {"name": selected.name, "type": "cash", "currency": selected.currency, "balance": 0},
        )["id"]
    return created[selected.key]


def _save_item(draft, item, matched, created, names):
    kind = "transfer" if matched else item.kind
    target = matched.source if matched else item.target
    payload = {"kind": kind, "accountID": _account_id(draft, item.source, created, names), "amount": str(item.amount),
               "categoryID": "account-transfer" if matched else item.category, "date": item.when.isoformat(),
               "note": _memo(item, matched)}
    if target:
        payload["targetAccountID"] = _account_id(draft, target, created, names)
        payload["targetAmount"] = str(matched.amount if matched else item.target_amount)
    return finance.save_entry(draft, payload)


def apply(store, payload):
    original, digest, replay = _validated_request(store, payload, "apply")
    if replay:
        return _detail(store, original)
    decisions, accepted_pairs = payload.get("decisions", {}), payload.get("pairs", [])
    overrides = payload.get("overrideDuplicates", [])
    if (not isinstance(decisions, dict) or any(action not in ("apply", "skip", "pending") for action in decisions.values())
            or not isinstance(accepted_pairs, list) or not all(isinstance(key, str) for key in accepted_pairs)
            or len(set(accepted_pairs)) != len(accepted_pairs)
            or not isinstance(overrides, list) or not all(isinstance(key, str) for key in overrides)):
        raise AppError("审核选择格式无法读取。", "csv-review-decision")
    draft = _draft(store)
    batch = _lookup(draft, original["id"])
    _edits(batch, payload.get("edits", {}), draft.tz)
    items, pairs = _analysis(draft, batch)
    pending = {item.row["id"] for item in items.values() if item.row["status"] == "pending"}
    if set(decisions) - pending or set(accepted_pairs) - set(pairs) or set(overrides) - pending:
        raise AppError("审核选择与当前待审核流水不一致，请重新读取。", "csv-review-decision")
    matched = {}
    for key in accepted_pairs:
        pair = pairs[key]
        first, second = pair["expenseID"], pair["incomeID"]
        if any(decisions.get(row) in {"apply", "skip"} for row in (first, second)):
            raise AppError("合并转账的两行不能同时单独入账或跳过。", "csv-review-decision")
        matched[first], matched[second] = second, None
    to_post = set(matched) | {key for key, decision in decisions.items() if decision == "apply"}
    for key in to_post:
        item = items[key]
        if key not in matched and item.problems:
            raise AppError("有流水仍缺少必填信息，请修改或留待审核。", "csv-review-blocked")
        if item.duplicates and key not in overrides:
            raise AppError("疑似重复需要单独确认覆盖。", "csv-review-duplicate")
    for key, action in decisions.items():
        if action == "skip":
            items[key].row["status"] = "skipped"
    created, names = {}, {}
    for key, item in items.items():
        if key not in to_post or key in matched and matched[key] is None:
            continue
        other = items[matched[key]] if key in matched else None
        saved = _save_item(draft, item, other, created, names)
        batch["entries"][saved["id"]] = _digest(saved)
        for posted in (item, other) if other else (item,):
            posted.row.update({"status": "applied", "entryID": saved["id"]})
    if batch["rows"] == original["rows"]:
        return _detail(store, original)
    _remember(batch, digest)
    _save_draft(store, draft, batch)
    return _detail(store, batch)


def undo(store, payload):
    original, digest, replay = _validated_request(store, payload, "undo")
    if replay:
        return _detail(store, original)
    receipts = original["entries"]
    if not receipts:
        return _detail(store, original)
    current = {row.get("id"): row for row in finance.entries(store)}
    related = {row.get("ledgerEntryID") for row in finance.records(store)}
    if any(entry_id in related or entry_id not in current or _digest(current[entry_id]) != signature
           for entry_id, signature in receipts.items()):
        raise AppError("本批次有流水已经修改、删除或关联积蓄记录，无法整批撤销。", "csv-review-undo-conflict")
    draft = _draft(store)
    batch = _lookup(draft, original["id"])
    draft.doc["ledgerEntries"] = [row for row in finance.entries(draft) if row.get("id") not in receipts]
    for row in batch["rows"]:
        if row["status"] == "applied":
            row["status"] = "undone"
    batch["entries"] = {}
    _remember(batch, digest)
    draft.mark_financial()
    _save_draft(store, draft, batch)
    return _detail(store, batch)
