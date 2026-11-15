"""流水 CSV。UTF-8 BOM、CRLF，列与 Mac 导出一致。"""

from __future__ import annotations

from datetime import datetime

from gaojixu import catalog, finance
from gaojixu.money import currency_digits, money, money_number, money_text
from gaojixu.timeutil import format_minute, parse_instant, read_cocoa, unix_minute


def export_ledger(store) -> str:
    lines = ["日期,类型,账户,目标账户,分类,备注,金额,币种"]
    kind_title = {"expense": "支出", "income": "收入", "transfer": "转账"}
    by_id = {row.get("id"): row for row in finance.accounts(store)}
    for entry in finance.entries(store):
        source = by_id.get(entry.get("accountID"))
        currency = (source or {}).get("currency") or "CNY"
        when = read_cocoa(entry.get("date"), store.tz)
        target = by_id.get(entry.get("targetAccountID"))
        fields = [
            format_minute(when, store.tz) if when else "",
            kind_title.get(entry.get("kind"), entry.get("kind") or ""),
            (source or {}).get("name") or "已归档账户",
            (target or {}).get("name") or "",
            catalog.category_name(entry.get("categoryID") or ""),
            entry.get("note") or "",
            money_text(entry.get("amount"), currency_digits(currency)),
            currency,
        ]
        lines.append(",".join(_escape(field) for field in fields))
    return "\ufeff" + "\r\n".join(lines) + "\r\n"


def _escape(field: str) -> str:
    text = str(field)
    if any(char in text for char in ",\"\n\r"):
        return '"' + text.replace('"', '""') + '"'
    return text


def _tokenize(text: str) -> list[list[str]]:
    records = []
    fields = []
    field = []
    in_quotes = False
    index = 0
    chars = text

    def end_field():
        fields.append("".join(field))
        field.clear()

    def end_record():
        end_field()
        records.append(list(fields))
        fields.clear()

    while index < len(chars):
        char = chars[index]
        if in_quotes:
            if char == '"':
                if index + 1 < len(chars) and chars[index + 1] == '"':
                    field.append('"')
                    index += 2
                    continue
                in_quotes = False
                index += 1
                continue
            field.append(char)
            index += 1
            continue
        if char == '"':
            if not field:
                in_quotes = True
            else:
                field.append('"')
            index += 1
        elif char == ",":
            end_field()
            index += 1
        elif char == "\r":
            end_record()
            index += 2 if index + 1 < len(chars) and chars[index + 1] == "\n" else 1
        elif char == "\n":
            end_record()
            index += 1
        else:
            field.append(char)
            index += 1
    if field or fields:
        end_record()
    return records


def import_ledger(store, text: str) -> dict:
    store.require_ready()
    stripped = text[1:] if text.startswith("\ufeff") else text
    rows = []
    skipped = 0
    kind_map = {"收入": "income", "income": "income", "支出": "expense", "expense": "expense", "转账": "transfer", "transfer": "transfer"}
    for index, fields in enumerate(_tokenize(stripped)):
        if all(not item.strip() for item in fields):
            continue
        if index == 0 and fields and fields[0].strip() == "日期":
            continue
        if len(fields) < 8:
            skipped += 1
            continue
        cleaned = [item.strip() for item in fields]
        kind = kind_map.get(cleaned[1].lower()) or kind_map.get(cleaned[1])
        if not kind or not cleaned[2]:
            skipped += 1
            continue
        try:
            when = parse_instant(cleaned[0], store.tz)
            amount = money(cleaned[6].replace(",", "").replace("¥", "").replace("$", ""))
        except Exception:
            skipped += 1
            continue
        if amount <= 0:
            skipped += 1
            continue
        rows.append({
            "date": when, "kind": kind, "accountName": cleaned[2], "targetAccountName": cleaned[3],
            "categoryName": cleaned[4], "note": cleaned[5], "amount": amount, "currency": cleaned[7].upper() or "CNY",
        })
    existing = set()
    for entry in finance.entries(store):
        when = read_cocoa(entry.get("date"), store.tz)
        if when is None:
            continue
        existing.add((unix_minute(when), entry.get("kind"), entry.get("accountID"), money_number(entry.get("amount")), entry.get("note") or ""))
    created_accounts = 0
    imported = 0
    duplicates = 0
    by_name = {row.get("name"): row for row in finance.active_accounts(store)}
    for row in rows:
        source = by_name.get(row["accountName"])
        if source is None:
            currency = row["currency"] if row["currency"] in catalog.CURRENCIES else "CNY"
            created = finance.save_account(store, {"name": row["accountName"], "type": "cash", "currency": currency, "balance": 0})
            by_name[row["accountName"]] = created
            source = created
            created_accounts += 1
        target_id = None
        target_amount = None
        if row["kind"] == "transfer":
            target = by_name.get(row["targetAccountName"])
            if target is None and row["targetAccountName"]:
                currency = row["currency"] if row["currency"] in catalog.CURRENCIES else "CNY"
                target = finance.save_account(store, {"name": row["targetAccountName"], "type": "cash", "currency": currency, "balance": 0})
                by_name[row["targetAccountName"]] = target
                created_accounts += 1
            if target is None or target.get("id") == source.get("id"):
                skipped += 1
                continue
            target_id = target["id"]
            target_amount = money_number(row["amount"])
        key = (unix_minute(row["date"]), row["kind"], source["id"], money_number(row["amount"]), row["note"])
        if key in existing:
            duplicates += 1
            continue
        if row["kind"] == "transfer":
            category = "account-transfer"
        else:
            found = catalog.CATEGORY_BY_NAME.get(row["categoryName"])
            if found and found[2] == row["kind"]:
                category = found[0]
            else:
                category = catalog.categories_for(row["kind"])[0][0]
        payload = {
            "kind": row["kind"],
            "accountID": source["id"],
            "amount": money_number(row["amount"]),
            "categoryID": category,
            "date": format_minute(row["date"], store.tz),
            "note": row["note"],
        }
        if target_id:
            payload["targetAccountID"] = target_id
            payload["targetAmount"] = target_amount
        finance.save_entry(store, payload)
        existing.add(key)
        imported += 1
    return {"imported": imported, "duplicates": duplicates, "skipped": skipped, "newAccounts": created_accounts}
