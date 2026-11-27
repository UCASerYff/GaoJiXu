"""Read models for the financial workspaces, backed by the active local library."""

from collections import defaultdict
from decimal import Decimal, DecimalException, localcontext
import re

from gaojixu import catalog, finance
from gaojixu.errors import AppError
from gaojixu.money import currency_digits, money, money_number
from gaojixu.store import _public_entry, _public_record
from gaojixu.timeutil import add_days, add_months, month_key, read_cocoa


def view(store, query):
    store.require_ready()
    route = query.get("route", ["overview"])[0]
    if route in {"ledger", "records"}:
        try:
            page = max(0, int(query.get("page", ["0"])[0]))
        except ValueError as exc:
            raise AppError("页码无法识别。", "invalid") from exc
        return history(store, route, page, query.get("kind", [""])[0], query.get("q", [""])[0].strip().casefold())
    currency = query.get("currency", [store.currency])[0]
    if currency not in catalog.CURRENCIES:
        raise AppError("币种无法识别。", "invalid")
    if route == "overview":
        return overview(store, currency)
    if route in {"reports", "analytics", "budgets"}:
        return trends(store, currency, route)
    raise AppError("没有这个财务页面。", "invalid")


def history(store, route, page, kind, query):
    is_ledger = route == "ledger"
    rows = finance.entries(store) if is_ledger else finance.records(store)
    accounts = {row["id"]: row for row in finance.accounts(store)}
    saving_entries = {row.get("ledgerEntryID") for row in finance.records(store)}
    subtotals = defaultdict(lambda: {"income": money(0), "expense": money(0)})
    matching = []
    for row in rows:
        adjustment = row.get("categoryID") == "balance-adjustment"
        if kind and (row.get("kind") != kind or adjustment):
            continue
        account = accounts.get(row.get("accountID"), {})
        currency = account.get("currency", "CNY")
        if query:
            category = catalog.category_name(row.get("categoryID") or "")
            digits = currency_digits(currency)
            symbol = catalog.CURRENCIES.get(currency, ("", ""))[1]
            amount = row.get("amount") or 0
            searchable = (
                row.get("note"), category, account.get("name"),
                accounts.get(row.get("targetAccountID"), {}).get("name"),
                f"{amount:.{digits}f}", f"{symbol}{amount:,.{digits}f}", f"+{symbol}{amount:,.{digits}f}",
            )
            if not any(query in str(value).casefold() for value in searchable if value):
                continue
        when = read_cocoa(row.get("date"), store.tz)
        matching.append((when.timestamp() if when else float("-inf"), row))
        if is_ledger and not adjustment and account and row.get("kind") in {"income", "expense"}:
            subtotals[currency][row["kind"]] += money(row.get("amount"))
    matching.sort(key=lambda item: item[0], reverse=True)
    page = min(page, max(0, (len(matching) - 1) // 100))
    page_rows = [row for _, row in matching[page * 100:(page + 1) * 100]]
    items = ([_public_entry(store, row, accounts, saving_entries) for row in page_rows] if is_ledger
             else [_public_record(store, row) for row in page_rows])
    return {"page": page, "total": len(matching), "items": items,
            "subtotals": {code: {key: money_number(value) for key, value in amounts.items()}
                          for code, amounts in subtotals.items()}}


def overview(store, currency):
    now = store.now()
    key = month_key(now, store.tz)
    goals = [row for row in finance.goals(store) if row.get("currency") == currency and row.get("status") != "archived"]
    recent = finance.entries(store)[:4]
    return {
        "date": now.date().isoformat(), "month": key, "days": finance.daily_summary(store, currency, now),
        "netWorth": finance.net_worth(store, currency), "income": finance.month_income(store, currency, now),
        "expense": finance.month_expense(store, currency, now),
        "allocated": money_number(sum(money(finance.goal_balance(store, goal)) for goal in goals)),
        "budget": money_number(sum(money(row.get("amount")) for row in finance.budgets(store)
                                   if row.get("monthKey") == key and row.get("currency") == currency)),
        "recent": [_public_entry(store, row) for row in recent],
    }


def trends(store, currency, route):
    now = store.now()
    month_start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    starts = [add_months(month_start, offset, 1, store.tz) for offset in range(-5, 2)]
    months = [month_key(date, store.tz) for date in starts[:-1]]
    points = {key: {"month": key, "income": money(0), "expense": money(0), "deposits": money(0), "netWorth": money(0)}
              for key in months}
    if route == "analytics":
        goals = {row["id"]: row.get("currency") for row in finance.goals(store)}
        days = {(add_days(now, offset, store.tz)).date().isoformat(): money(0) for offset in range(-34, 1)}
        deposited_days = set()
        for row in finance.records(store):
            date = read_cocoa(row.get("date"), store.tz)
            if date is None or row.get("kind") != "deposit":
                continue
            day = date.date().isoformat()
            deposited_days.add(day)
            if goals.get(row.get("goalID")) != currency:
                continue
            key = month_key(date, store.tz)
            amount = money(row.get("amount"))
            if key in points:
                points[key]["deposits"] += amount
            if day in days:
                days[day] += amount
        result = {"savingDays": len(deposited_days), "streak": finance.saving_streak(store),
                  "days": {key: money_number(value) for key, value in days.items()}}
    else:
        accounts = {row["id"]: row for row in finance.accounts(store) if row.get("currency") == currency}
        included = {row["id"]: row for row in accounts.values() if row.get("includeInNetWorth") and not row.get("isArchived")}
        opening = sum((-1 if row.get("type") == "credit" else 1) * money(row.get("openingBalance")) for row in included.values())
        for point in points.values():
            point["netWorth"] = opening
        category_months = defaultdict(lambda: defaultdict(lambda: money(0)))
        income_categories = defaultdict(lambda: money(0))
        month_count = 0
        for row in finance.entries(store):
            date = read_cocoa(row.get("date"), store.tz)
            if date is None or date >= starts[-1]:
                continue
            source, target = row.get("accountID"), row.get("targetAccountID")
            amount = money(row.get("amount"))
            kind, category = row.get("kind"), row.get("categoryID")
            if kind not in {"income", "expense", "transfer"}:
                continue
            key = month_key(date, store.tz)
            if key == months[-1]:
                month_count += 1
            if key in points and source in accounts and category != "balance-adjustment":
                if kind in {"income", "expense"}:
                    points[key][kind] += amount
                if kind == "expense" and category in catalog.CATEGORY_BY_ID:
                    category_months[category][key] += amount
                if kind == "income" and key == months[-1] and category in catalog.CATEGORY_BY_ID:
                    income_categories[category] += amount
            source_is_credit_transfer = kind == "transfer" and included.get(source, {}).get("type") == "credit"
            delta = (amount if kind == "income" or source_is_credit_transfer else -amount) if source in included else money(0)
            if kind == "transfer" and target in included and source != target:
                delta += money(row.get("targetAmount") if row.get("targetAmount") is not None else amount)
            if delta:
                for key, end in zip(months, starts[1:]):
                    if date < end:
                        points[key]["netWorth"] += delta
        top = sorted(category_months, key=lambda key: sum(category_months[key].values()), reverse=True)[:5]
        result = {"entryCount": month_count,
                  "incomeCategories": {key: money_number(value) for key, value in income_categories.items()},
                  "expenseCategories": {key: money_number(values[months[-1]]) for key, values in category_months.items() if values[months[-1]] > 0},
                  "previousExpenseCategories": {key: money_number(values[months[-2]]) for key, values in category_months.items() if values[months[-2]] > 0},
                  "categorySeries": [{"id": key, "values": [money_number(category_months[key][month]) for month in months]} for key in top]}
    result["months"] = [{key: value if key == "month" else money_number(value) for key, value in point.items()}
                        for point in points.values()]
    return result


_AMOUNT_TOKEN = re.compile(r"[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)")


def evaluate_amount(value):
    expression = str(value or "").translate(str.maketrans({" ": None, "×": "*", "÷": "/", "−": "-"}))
    if not expression or len(expression) > 120:
        raise AppError("请选择账户并填写有效金额。", "invalid")
    index = 0

    def number():
        nonlocal index
        match = _AMOUNT_TOKEN.match(expression, index)
        if match is None or sum(character.isdigit() for character in match[0]) > 16:
            raise AppError("请完善算式，除数不能为 0。", "invalid")
        index = match.end()
        return Decimal(match[0])

    def term():
        nonlocal index
        current = number()
        while index < len(expression) and expression[index] in "*/":
            operator = expression[index]
            index += 1
            right = number()
            current = current * right if operator == "*" else current / right
        return current

    try:
        with localcontext() as context:
            context.prec = 38
            result = term()
            while index < len(expression):
                operator = expression[index]
                if operator not in "+-":
                    raise AppError("请完善算式，除数不能为 0。", "invalid")
                index += 1
                right = term()
                result = result + right if operator == "+" else result - right
            result = money(result)
    except DecimalException as exc:
        raise AppError("请完善算式，除数不能为 0。", "invalid") from exc
    if abs(result) > Decimal("999999999999.99"):
        raise AppError("金额超出可记账范围。", "invalid")
    return float(result)
