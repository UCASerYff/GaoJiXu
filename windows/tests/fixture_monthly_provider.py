"""Independent test process for the receiver-owned monthly SQLite contract."""

import argparse
import json
import sqlite3
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("root", type=Path)
parser.add_argument("operation", choices=("confirm", "correct", "withdraw", "skip", "duplicate", "incomplete"))
parser.add_argument("subscription")
args = parser.parse_args()
root = args.root.resolve(strict=True)
if not (root / ".gaojixu-provider-fixture").is_file():
    parser.error("Use a marked, synthetic test directory")
target = root / "IntegratedFinance" / "Monthly" / "monthly.sqlite"
with sqlite3.connect(target.resolve(strict=True).as_uri() + "?mode=rw", uri=True) as database:
    database.execute("BEGIN IMMEDIATE")
    document = json.loads(database.execute("SELECT json FROM state WHERE id=1").fetchone()[0])
    subscription = next(row for row in document["subscriptions"] if row["id"] == args.subscription)
    ident = f"{subscription['id']}|2026-11-27"
    plan = subscription["plans"][0]
    payment = {
        "id": ident, "subscriptionID": subscription["id"], "due": plan["start"],
        "paidAt": plan["start"] + 3600, "recordedAt": plan["start"] + 3600,
        "amount": 23.5, "currency": plan["currency"], "skipped": False, "note": "",
    }
    matching = lambda row: row["id"] == ident
    if args.operation == "confirm":
        document["payments"] = [row for row in document["payments"] if not matching(row)] + [payment]
    elif args.operation == "correct":
        payment.update(amount=42, paidAt=plan["start"] + 7200)
        document["payments"] = [row for row in document["payments"] if not matching(row)] + [payment]
    elif args.operation == "withdraw":
        document["payments"] = [row for row in document["payments"] if not matching(row)]
    elif args.operation == "skip":
        payment.update(amount=0, skipped=True)
        document["payments"] = [row for row in document["payments"] if not matching(row)] + [payment]
    elif args.operation == "duplicate":
        document["payments"].append(payment)
    elif args.operation == "incomplete":
        document.pop("payments")
    document["updatedAt"] += 1
    encoded = json.dumps(document, ensure_ascii=False).encode("utf-8")
    database.execute("UPDATE state SET json=? WHERE id=1", (encoded,))
