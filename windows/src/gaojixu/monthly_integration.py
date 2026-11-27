"""Reconcile confirmed payments from the verified receiver-owned monthly database."""

from __future__ import annotations

import json
import math
import re
import threading
import time
import uuid
from datetime import date
from pathlib import Path

from gaojixu import finance, monthly, monthly_bridge, monthly_signal
from gaojixu.errors import AppError
from gaojixu.store import dumps, monthly_ledger_entry
from gaojixu.timeutil import from_cocoa

HISTORY = "__integratedMonthly"
HISTORY_REQUIRED = "monthlyIntegrationHistoryRequired"
PERIOD_SECONDS = 60


def _trusted_receipt(directory, receipt):
    """Legacy receipts remain readable; automated writes require a portable, verified owner."""
    _cocoa(receipt.get("activatedAt"))
    transaction = receipt.get("transactionID")
    try:
        uuid.UUID(transaction)
    except (AttributeError, ValueError):
        return False
    if receipt.get("mode") == "new":
        return (receipt.get("sourceFrozen") is True and not any(receipt.get(key) for key in
                ("sourceBundleID", "sourceRevision", "commitMarkerPath", "expectedModules")))
    revision = receipt.get("sourceRevision")
    expected = f"IntegratedFinance/Migrations/{transaction}/committed.json"
    modules = receipt.get("expectedModules", [])
    if (not isinstance(revision, str) or not re.fullmatch("[0-9a-f]{64}", revision)
            or not isinstance(modules, list) or len(modules) != len(set(modules))
            or not set(modules) <= {"monthly", "research-funding"}
            or receipt.get("sourceFrozen") is not True or receipt.get("commitMarkerPath") != "app-group:" + expected):
        return False
    marker = directory / Path(expected)
    if marker.resolve() != directory.resolve() / Path(expected) or marker.is_symlink():
        return False
    committed = json.loads(marker.read_text(encoding="utf-8"))
    _cocoa(committed.get("committedAt"))
    return True


def _cocoa(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError("invalid paid date")
    from_cocoa(value)
    return value


def _confirmed(state):
    _cocoa(state.get("updatedAt"))
    if not isinstance(state.get("preferences"), dict) or any(not isinstance(state.get(key), list)
            for key in ("claims", "benefits", "events", "reviews", "tombstones", "legacyRewardIDs")):
        raise ValueError("incomplete source")
    rows = state.get("payments")
    subscriptions = state.get("subscriptions")
    if not isinstance(rows, list) or not isinstance(subscriptions, list):
        raise ValueError("incomplete source")
    names = {}
    for subscription in subscriptions:
        identifier = uuid.UUID(subscription["id"])
        title = subscription["name"]
        if identifier in names or not isinstance(title, str) or not title.strip():
            raise ValueError("invalid subscription")
        plans = subscription.get("plans")
        if not isinstance(plans, list) or not plans or not all(isinstance(plan, dict) for plan in plans):
            raise ValueError("invalid subscription plans")
        names[identifier] = subscription
    seen = set()
    confirmed = {}
    for row in rows:
        ident = row["id"]
        owner, separator, due = ident.partition("|")
        identifier = uuid.UUID(owner)
        day = date.fromisoformat(due)
        unique = identifier, day
        if not separator or day.isoformat() != due or unique in seen or uuid.UUID(row["subscriptionID"]) != identifier:
            raise ValueError("invalid payment id")
        subscription = names[identifier]
        if type(row["skipped"]) is not bool:
            raise ValueError("invalid payment state")
        _cocoa(row["due"])
        _cocoa(row["paidAt"])
        amount = monthly._amount(row["amount"], row["currency"], zero=True)
        seen.add(unique)
        if not row["skipped"] and amount > 0:
            confirmed[ident] = ({**row, "amount": amount}, subscription)
    return confirmed


def _valid_account(store, identifier, currency):
    row = finance.account(store, identifier) if isinstance(identifier, str) and identifier else None
    if row and not row.get("isArchived") and row.get("currency") == currency:
        return row


def _matches(store, existing, payment, subscription):
    if not existing:
        return False
    account = _valid_account(store, existing.get("accountID"), payment["currency"])
    return account and monthly_ledger_entry(store, payment, subscription, account["id"], existing) == existing


def reconcile(store, state, confirmed):
    """Apply a complete verified revision. Withdrawals only affect tracked payment IDs."""
    directory = store.directory
    meta_name = monthly_bridge.RECONCILIATION_FILE
    data = monthly_bridge._read_metadata(store, meta_name)
    transaction = state.authority["transactionID"]
    history = data.get(HISTORY)
    if history is None and store.doc.get(HISTORY_REQUIRED):
        return "unverified"
    if history is not None:
        if not isinstance(history, dict) or not isinstance(history.get("managed"), list) or not all(
                isinstance(value, str) for value in history["managed"]):
            raise ValueError("invalid reconciliation history")
        if history.get("authority") != transaction:
            return "authority-changed"
    before = finance.entries(store)
    existing = {row["id"][len("auto-monthly|"):]: row for row in before
                if str(row.get("id", "")).startswith("auto-monthly|")}
    if not confirmed and history is None:
        return "ready"
    bindings = monthly_bridge._read_metadata(store, "monthly-account-bindings.json")
    previously_managed = set(history["managed"]) if history else set()
    managed = previously_managed.copy()
    replacements = {}
    for identifier, (payment, subscription) in confirmed.items():
        current = existing.get(identifier)
        currency = payment["currency"]
        if _matches(store, current, payment, subscription):
            managed.add(identifier)
        if data.get(identifier):
            continue
        bound = bindings.get(monthly_bridge._binding_key(subscription["id"]))
        account = _valid_account(store, bound, currency)
        if not account and not bound and current and identifier in previously_managed:
            account = _valid_account(store, current.get("accountID"), currency)
        if account:
            replacement = monthly_ledger_entry(store, payment, subscription, account["id"], current)
            managed.add(identifier)
            if replacement != current:
                replacements[replacement["id"]] = replacement

    withdrawn = previously_managed.difference(confirmed)
    current_authority = monthly._read_authority(monthly.directory_for(directory))
    if current_authority != state.authority or not monthly._marker_ok(directory, current_authority):
        return "readonly"
    status, latest, _ = monthly.load_state(directory)
    if status != "ready" or latest.authority != state.authority or latest.original != state.original:
        return "retry"
    if managed and (history is None or managed != previously_managed):
        data[HISTORY] = {"authority": transaction, "managed": sorted(managed)}
        store._atomic(directory / meta_name, dumps(data))
    removed = {f"auto-monthly|{identifier}" for identifier in withdrawn}
    if replacements or any(entry.get("id") in removed for entry in before):
        retained = [entry for entry in before if entry.get("id") not in removed and entry.get("id") not in replacements]
        store.doc["ledgerEntries"] = sorted([*replacements.values(), *retained],
            key=lambda row: finance._when(store, row) or from_cocoa(0), reverse=True)
        had_history = store.doc.get(HISTORY_REQUIRED)
        store.doc[HISTORY_REQUIRED] = True
        store.mark_financial()
        try:
            store.save()
        except OSError:
            store.doc["ledgerEntries"] = before
            if not had_history:
                store.doc.pop(HISTORY_REQUIRED, None)
            raise
    if withdrawn:
        data[HISTORY] = {"authority": transaction, "managed": sorted(managed.difference(withdrawn))}
        store._atomic(directory / meta_name, dumps(data))
    return "ready"


class MonthlyIntegration:
    def __init__(self, store, lock, shutdown):
        self.store, self.lock, self.shutdown = store, lock, shutdown
        self.state = {"transport": "starting", "source": "checking", "generation": 0, "externalProvider": "unverified"}
        self.signature = None
        self.wake = threading.Event()
        self.thread = threading.Thread(target=self._run, name="gaojixu-monthly", daemon=True)

    def notify(self):
        self.wake.set()
        monthly_signal.signal(self.store.directory)

    def _run(self):
        try:
            with monthly_signal.listener(self.store.directory, self.shutdown) as (transport, wait):
                self.state = {**self.state, "transport": transport}
                self._loop(wait)
        except OSError:
            self.state = {**self.state, "transport": "poll"}
            self._loop(lambda: self.wake.wait(1))

    def _loop(self, wait):
        elapsed = 0
        while not self.shutdown.is_set():
            if not elapsed or elapsed >= PERIOD_SECONDS or self.wake.is_set():
                self.wake.clear()
                with self.lock:
                    self.sync()
                elapsed = .001
            started = time.monotonic()
            if wait():
                self.wake.set()
            elapsed += time.monotonic() - started

    def sync(self):
        source = "library-protected"
        revision = None
        if self.store.status == "ready" and not self.store.readonly:
            source, state, _ = monthly.load_state(self.store.directory)
            if source == "ready":
                try:
                    revision = state.revision
                    if _trusted_receipt(self.store.directory, state.authority):
                        source = reconcile(self.store, state, _confirmed(state))
                    else:
                        source = "readonly"
                except (AppError, OSError, ValueError, TypeError, OverflowError, AttributeError, KeyError):
                    source = "unverified"
        signature = (source, revision, self.store.financial_revision)
        if signature != self.signature:
            self.signature = signature
            self.state = {**self.state, "source": source, "generation": self.state["generation"] + 1}
