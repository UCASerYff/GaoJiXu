import csv
from datetime import datetime, timedelta, timezone
import io
from zoneinfo import ZoneInfo

import pytest

from gaojixu import csv_review, finance, widget
from gaojixu.errors import AppError
from gaojixu.store import Store


HEADER = ["日期", "类型", "账户", "目标账户", "分类", "备注", "金额", "币种", "转入金额", "转入币种"]
ZONE = timezone(timedelta(hours=8))
MOMENT = datetime(2026, 11, 27, 10, tzinfo=ZONE)


def create_store(path, tz=ZONE):
    result = Store(path, now=lambda: MOMENT, tz=tz)
    result.create_library()
    return result


def upload(rows, header=HEADER):
    output = io.StringIO(newline="")
    output.write("\ufeff")
    writer = csv.writer(output)
    writer.writerow(header)
    writer.writerows(rows)
    return output.getvalue()


def action(staged, **fields):
    batch = staged["batch"]
    return {"batchID": batch["id"], "revision": batch["revision"], "confirmed": True, **fields}


def test_duplicates_are_explained_and_override_is_explicit(tmp_path):
    store = create_store(tmp_path)
    cash = finance.active_accounts(store)[0]
    original = finance.save_entry(store, {
        "kind": "expense", "accountID": cash["id"], "amount": "18.37", "categoryID": "food", "note": "午饭",
        "date": "2026-11-27T00:15:00Z",
    })
    text = upload([
        ["2026-11-27 08:15", "支出", "现金", "", "餐饮", "午饭", "18.37", "CNY"],
        ["2026-11-27 12:30", "支出", "现金", "", "日用购物", "便当袋", "18.37", "CNY"],
        ["2026-11-28 09:30", "支出", "现金", "", "餐饮", "次日早餐", "10.01", "CNY"],
        ["2026-11-28 09:30", "支出", "现金", "", "餐饮", "次日早餐", "10.01", "CNY"],
    ])
    staged = csv_review.stage(store, {"text": text, "name": "示例.csv"})
    assert len(finance.entries(store)) == 1
    assert staged["rows"][0]["duplicates"] == [{"code": "ledger-exact", "entryID": original["id"]}]
    assert staged["rows"][1]["duplicates"][0]["code"] == "ledger-same-day"
    assert staged["rows"][3]["duplicates"] == [{"code": "batch-exact", "line": 4}]
    assert csv_review.stage(store, {"text": text.removeprefix("\ufeff").replace("\r\n", "\n"), "name": "重试.csv"}) == staged
    with pytest.raises(AppError) as denied:
        csv_review.apply(store, action(staged, decisions={"1": "apply"}))
    assert denied.value.code == "csv-review-duplicate"
    request = action(staged, decisions={"1": "apply", "2": "skip", "3": "apply"}, overrideDuplicates=["1"])
    applied = csv_review.apply(store, request)
    assert applied["batch"]["counts"]["entries"] == 2
    assert applied["batch"]["status"] == "partial"
    assert len(finance.entries(store)) == 3
    restarted = Store(tmp_path, now=lambda: MOMENT, tz=ZONE)
    assert csv_review.list_batches(restarted)["batches"][0]["id"] == staged["batch"]["id"]
    assert csv_review.apply(restarted, request) == applied
    assert len(finance.entries(restarted)) == 3
    undone = csv_review.undo(restarted, action(applied))
    assert len(finance.entries(restarted)) == 1
    assert finance.entries(restarted)[0] == original
    assert undone["batch"]["counts"]["undone"] == 2
    assert csv_review.apply(restarted, request)["batch"] == undone["batch"]


def test_unique_transfer_uses_existing_same_currency_accounts(tmp_path):
    store = create_store(tmp_path)
    text = upload([
        ["2026-11-27T15:50:00Z", "支出", "现金", "", "转账", "转出到银行卡", "-13.42", "CNY"],
        ["2026-11-27T23:55:00+08:00", "收入", "银行卡", "", "转账", "转入自现金", "+13.42", "CNY"],
        ["2026-11-27 14:40", "支出", "现金", "", "餐饮", "普通借方", "8.12", "CNY"],
        ["2026-11-27 14:50", "收入", "银行卡", "", "工资", "普通贷方", "8.12", "CNY"],
        ["2026-11-27 04:10", "转出", "现金", "", "", "", "20.00", "CNY"],
        ["2026-11-27 04:12", "转入", "银行卡", "", "", "", "20.00", "CNY"],
        ["2026-11-27 04:15", "转入", "现金", "", "", "", "20.00", "CNY"],
    ])
    staged = csv_review.stage(store, {"text": text})
    pair, = staged["pairs"]
    assert (pair["expenseID"], pair["incomeID"], pair["amount"], pair["currency"]) == ("1", "2", "13.42", "CNY")
    assert staged["rows"][4]["problems"] == ["transfer-leg"]
    with pytest.raises(AppError) as blocked:
        csv_review.apply(store, action(staged, decisions={"5": "apply"}))
    assert blocked.value.code == "csv-review-blocked"
    applied = csv_review.apply(store, action(staged, pairs=[pair["id"]]))
    transfer, = finance.entries(store)
    assert (transfer["kind"], transfer["amount"], transfer["targetAmount"]) == ("transfer", 13.42, 13.42)
    assert transfer["note"] == "转出到银行卡 · 转入自现金"
    assert applied["batch"]["counts"]["applied"] == 2
    assert applied["rows"][0]["entryID"] == applied["rows"][1]["entryID"]
    repeated = csv_review.stage(store, {"text": upload([
        ["2026-11-27T15:50:00Z", "支出", "现金", "", "转账", "转出到银行卡", "-13.42", "CNY"],
        ["2026-11-27T23:55:00+08:00", "收入", "银行卡", "", "转账", "转入自现金", "+13.42", "CNY"],
    ])})
    assert repeated["pairs"][0]["duplicates"] == [{"code": "ledger-exact", "entryID": transfer["id"]}]
    with pytest.raises(AppError) as duplicate:
        csv_review.apply(store, action(repeated, pairs=[pair["id"]], overrideDuplicates=["1"]))
    assert duplicate.value.code == "csv-review-duplicate"


def test_same_batch_direct_transfer_and_pair_also_require_override(tmp_path):
    store = create_store(tmp_path)
    staged = csv_review.stage(store, {"text": upload([
        ["2026-11-27 05:00", "转账", "现金", "银行卡", "账户互转", "", "45", "CNY"],
        ["2026-11-27 05:00", "转出", "现金", "银行卡", "", "", "45", "CNY"],
        ["2026-11-27 05:00", "转入", "银行卡", "现金", "", "", "45", "CNY"],
    ])})
    pair, = staged["pairs"]
    assert pair["duplicates"] == [{"code": "batch-exact", "line": 2}]
    with pytest.raises(AppError) as denied:
        csv_review.apply(store, action(staged, decisions={"1": "apply"}, pairs=[pair["id"]]))
    assert denied.value.code == "csv-review-duplicate"
    assert not finance.entries(store)


def test_cross_currency_and_missing_columns_remain_pending_until_corrected(tmp_path):
    store = create_store(tmp_path)
    foreign = finance.save_account(store, {"name": "美元钱包", "currency": "USD", "balance": 0})
    data = upload([
        ["2026-11-27 08:15", "转账", "现金", "美元钱包", "120.13"],
        ["2026-11-27 09:20", "支出", "现金", "", ""],
        ["2026-11-27 12:01", "支出", "现金", "", "0.015"],
        ["2026-11-27 12:02", "支出", "现金", "", "1.000000000000000000000000000000000001"],
    ], ["日期", "类型", "账户", "目标账户", "金额"])
    staged = csv_review.stage(store, {"text": data})
    assert staged["rows"][0]["problems"] == ["missing-target-amount"]
    assert staged["rows"][0]["targetCurrency"] == "USD"
    assert staged["rows"][1]["problems"] == ["missing-amount"]
    assert staged["rows"][2]["problems"] == ["amount-precision"]
    assert staged["rows"][3]["problems"] == ["amount-precision"]
    assert not staged["pairs"]
    edited = csv_review.apply(store, action(staged, edits={"1": {"targetAmount": "17.83"}, "2": {"amount": "12.30"}}))
    assert edited["rows"][0]["canApply"] and edited["rows"][1]["canApply"]
    assert edited["rows"][0]["targetAmount"] == "17.83"
    restarted = Store(tmp_path, now=lambda: MOMENT, tz=ZONE)
    applied = csv_review.apply(restarted, action(edited, decisions={"1": "apply", "2": "apply"}))
    assert applied["batch"]["counts"]["pending"] == 2
    transfer = next(row for row in finance.entries(restarted) if row["kind"] == "transfer")
    assert transfer["targetAccountID"] == foreign["id"]
    assert (transfer["amount"], transfer["targetAmount"]) == (120.13, 17.83)


def test_timezone_is_anchored_and_ambiguous_wall_time_is_reviewed(tmp_path):
    store = create_store(tmp_path, ZoneInfo("America/New_York"))
    staged = csv_review.stage(store, {"text": upload([
        ["2026-11-01 01:30", "支出", "现金", "", "", "", "3", "CNY"],
        ["2026-11-01 05:30:14Z", "支出", "现金", "", "", "", "4", "CNY"],
        ["2026-11-02 12:30", "支出", "银行卡", "", "", "", "5", "CNY"],
    ])})
    assert staged["rows"][0]["problems"] == ["ambiguous-local-time"]
    assert staged["rows"][1]["date"] == "2026-11-01T05:30:14+00:00"
    assert staged["rows"][2]["date"] == "2026-11-02T12:30:00-05:00"
    restarted = Store(tmp_path, now=lambda: MOMENT, tz=ZONE)
    reopened = csv_review.detail(restarted, staged["batch"]["id"])
    assert reopened["rows"][2]["date"] == staged["rows"][2]["date"]
    assert reopened["rows"][2]["dateTimezone"] == "America/New_York"
    assert reopened["batch"]["timezone"] == str(ZONE)
    assert reopened["batch"]["createdTimezone"] == "America/New_York"
    with pytest.raises(AppError) as stale:
        csv_review.apply(restarted, action(staged, decisions={"2": "apply"}))
    assert stale.value.code == "csv-review-stale"


def test_undo_conflict_protects_edited_entry_and_ledger_changes_stale_review(tmp_path):
    store = create_store(tmp_path)
    staged = csv_review.stage(store, {"text": upload([
        ["2026-11-27", "支出", "现金", "", "餐饮", "待核对", "45.75", "CNY"],
    ])})
    cash = finance.active_accounts(store)[0]
    finance.save_entry(store, {"kind": "income", "accountID": cash["id"], "amount": 20, "categoryID": "other-income"})
    with pytest.raises(AppError) as stale:
        csv_review.apply(store, action(staged, decisions={"1": "apply"}))
    assert stale.value.code == "csv-review-stale"
    refreshed = csv_review.detail(store, staged["batch"]["id"])
    applied = csv_review.apply(store, action(refreshed, decisions={"1": "apply"}))
    own_id = applied["rows"][0]["entryID"]
    finance.save_entry(store, {"id": own_id, "kind": "expense", "accountID": cash["id"], "amount": 45.75,
                               "categoryID": "food", "note": "人工修改过"})
    refreshed = csv_review.detail(store, staged["batch"]["id"])
    with pytest.raises(AppError) as conflict:
        csv_review.undo(store, action(refreshed))
    assert conflict.value.code == "csv-review-undo-conflict"
    assert len(finance.entries(store)) == 2


def test_library_replace_is_atomic_even_if_widget_refresh_fails(tmp_path, monkeypatch):
    store = create_store(tmp_path)
    staged = csv_review.stage(store, {"text": upload([
        ["2026-11-27", "支出", "新记账账户", "", "餐饮", "", "10.95", "CNY"],
    ])})
    request = action(staged, decisions={"1": "apply"})

    def failed(*_args):
        raise OSError("synthetic I/O failure")

    with monkeypatch.context() as patches:
        patches.setattr(store, "_atomic", failed)
        with pytest.raises(OSError):
            csv_review.apply(store, request)
    assert not finance.entries(store)
    assert len(finance.accounts(store)) == 2
    assert csv_review.detail(store, staged["batch"]["id"]) == staged
    with monkeypatch.context() as patches:
        patches.setattr(widget, "publish", failed)
        applied = csv_review.apply(store, request)
        restarted = Store(tmp_path, now=lambda: MOMENT, tz=ZONE)
        assert csv_review.apply(restarted, request) == applied
    assert len(finance.entries(restarted)) == 1
    assert len(finance.accounts(restarted)) == 3
    csv_review.undo(restarted, action(applied))
    assert len(finance.accounts(restarted)) == 3
    assert not finance.entries(restarted)
