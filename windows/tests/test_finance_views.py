from datetime import datetime, timezone

import pytest

from gaojixu import finance, finance_views
from gaojixu.errors import AppError
from gaojixu.store import Store
from gaojixu.timeutil import cocoa_json
from gaojixu.web import dispatch


def library(tmp_path):
    now = datetime(2026, 11, 15, 9, tzinfo=timezone.utc)
    store = Store(tmp_path, now=lambda: now, tz=timezone.utc)
    store.create_library()
    return store


def test_ledger_history_includes_older_pages_and_counts_per_currency(tmp_path):
    store = library(tmp_path)
    cash = store.doc["accounts"][0]["id"]
    date = cocoa_json(store.now())
    store.doc["ledgerEntries"] = [{"id": str(index), "accountID": cash, "date": date - index*60,
                                   "kind": "expense", "amount": 1.11, "categoryID": "food", "note": "午饭"}
                                  for index in range(315)]
    store.doc["ledgerEntries"].append({"id": "adjustment", "accountID": cash, "date": date,
                                      "kind": "expense", "amount": 9, "categoryID": "balance-adjustment"})
    history = finance_views.view(store, {"route": ["ledger"], "page": ["10"], "kind": ["expense"], "q": ["午饭"]})
    assert history["page"] == 3 and history["total"] == 315
    assert history["items"][-1]["id"] == "314"
    assert history["subtotals"] == {"CNY": {"income": 0, "expense": 349.65}}


def test_report_values_match_the_live_ledger_and_split_original_currencies(tmp_path):
    store = library(tmp_path)
    bank = store.doc["accounts"][1]["id"]
    credit = finance.save_account(store, {"name": "信用卡", "type": "credit", "currency": "CNY", "balance": 50})["id"]
    usd = finance.save_account(store, {"name": "美元账户", "type": "bank", "currency": "USD", "balance": 0})["id"]
    dispatch(store, "/api/ledger/save", {"kind": "income", "accountID": bank, "amountExpression": "100+25.25×2", "categoryID": "salary-income", "date": "2026-10-01"})
    dispatch(store, "/api/ledger/save", {"kind": "expense", "accountID": bank, "amountExpression": "10.005", "categoryID": "food", "date": "2026-10-03"})
    dispatch(store, "/api/ledger/save", {"kind": "expense", "accountID": usd, "amountExpression": "2", "categoryID": "food", "date": "2026-11-02"})
    finance.save_entry(store, {"kind": "transfer", "accountID": credit, "targetAccountID": bank, "amount": 3, "date": "2026-11-03"})
    cny = finance_views.view(store, {"route": ["reports"], "currency": ["CNY"]})
    assert cny["months"][-2]["income"] == 150.5
    assert cny["months"][-2]["expense"] == 10.01
    assert cny["months"][-2]["netWorth"] == 140.49
    assert cny["months"][-1]["netWorth"] == finance.net_worth(store, "CNY")
    assert cny["entryCount"] == 3
    assert cny["previousExpenseCategories"] == {"food": 10.01}
    usd_summary = finance_views.view(store, {"route": ["overview"], "currency": ["USD"]})
    assert usd_summary["expense"] == 2
    assert usd_summary["days"][1]["expense"] == 2


def test_selected_calendar_month_and_day_filter_preserve_overview_period(tmp_path):
    store = library(tmp_path)
    cash = store.doc["accounts"][0]["id"]
    for when, amount in [("2026-10-08", 24.75), ("2026-10-09", 8), ("2026-11-08", 13)]:
        dispatch(store, "/api/ledger/save", {"kind": "expense", "accountID": cash, "amount": amount,
                                             "categoryID": "food", "date": when, "note": "午饭"})
    overview = finance_views.view(store, {"route": ["overview"], "calendarMonth": ["2026-10"]})
    assert overview["month"] == "2026-11"
    assert overview["calendarMonth"] == "2026-10"
    assert overview["expense"] == 13
    assert overview["days"][7]["expense"] == 24.75
    day = finance_views.view(store, {"route": ["ledger"], "day": ["2026-10-08"], "q": ["午饭"]})
    assert day["total"] == 1
    assert day["items"][0]["date"].startswith("2026-10-08")
    assert day["subtotals"]["CNY"]["expense"] == 24.75
    with pytest.raises(AppError):
        finance_views.view(store, {"route": ["ledger"], "day": ["2026-02-30"]})
    with pytest.raises(AppError):
        finance_views.view(store, {"route": ["overview"], "calendarMonth": ["2026-13"]})


def test_budget_batch_rejects_an_invalid_category_before_writing(tmp_path):
    store = library(tmp_path)
    request = {"monthKey": "2026-11", "currency": "CNY"}
    finance.save_budgets(store, {**request,"amounts": {"food": 70,"groceries": 45}})
    raw = store.library_path().read_bytes()
    with pytest.raises(AppError):
        finance.save_budgets(store, {**request,"amounts": {"food": 100,"salary-income": 90}})
    assert store.library_path().read_bytes() == raw
    finance.save_budgets(store, {**request,"amounts": {"food": 0,"groceries": "40.55"}})
    assert [(row["categoryID"], row["amount"]) for row in store.doc["budgets"]] == [("groceries", 40.55)]


def test_csv_preview_and_confirmation_agree_without_early_writes(tmp_path):
    store = library(tmp_path)
    opening = store.library_path().read_bytes()
    csv = ("日期,类型,账户,目标账户,分类,备注,金额,币种\n"
           "2026-11-04 12:15,支出,新账户,,餐饮,午饭,42,CNY\n"
           "2026-11-04 12:15,支出,新账户,,餐饮,午饭,42,CNY\n"
           "2026-11-04 12:16,转账,不应创建,,账户互转,,10,CNY\n")
    plan = dispatch(store, "/api/csv/preview", {"text": csv})
    assert store.library_path().read_bytes() == opening
    assert plan["importable"] == plan["duplicates"] == plan["skipped"] == plan["newAccounts"] == 1
    assert plan["preview"][0]["amount"] == 42
    assert dispatch(store, "/api/csv/import", {"text": csv}) == {"imported": 1, "duplicates": 1, "skipped": 1, "newAccounts": 1}


@pytest.mark.parametrize("expression", ["1÷0", "1e6", "(1+2)", "5%%", "999999999999.995"])
def test_calculator_rejects_invalid_or_out_of_range_amounts(expression):
    with pytest.raises(AppError):
        finance_views.evaluate_amount(expression)
