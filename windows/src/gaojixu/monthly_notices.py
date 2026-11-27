"""Build Windows reminder notices from the authoritative monthly state."""

from __future__ import annotations

from datetime import timedelta

from gaojixu import monthly
from gaojixu.timeutil import parse_instant, read_cocoa


class MonthlyNotices:
    def __init__(self, server):
        self.server = server
        self.delivered = {}

    def next_notice(self):
        with self.server.lock:
            store = self.server.store
            if store.status != "ready":
                return None
            status, state, _ = monthly.load_state(store.directory)
            if status not in {"ready", "readonly"}:
                return None
            current = store.now()
            zone = monthly.business_zone(state, store.tz)
            now = current.astimezone(zone)
            earliest = now - timedelta(hours=12)
            self.delivered = {key: date for key, date in self.delivered.items() if date >= earliest}
            for due, key, text in due_notices(state, now, zone, earliest):
                if key not in self.delivered:
                    self.delivered[key] = due
                    return "搞积蓄 · 固定支出与事项", text
        return None


def due_notices(state, now, zone, earliest):
    prefs = state.get("preferences", {})
    if not prefs.get("notifications"):
        return []
    result = []
    privacy = prefs.get("privacy")
    hour = int(prefs.get("reminderHour", 9))
    default_advance = int(prefs.get("reminderDays", 3))

    def add(date, key, public, private):
        if earliest <= date <= now:
            result.append((date, key, private if privacy else public))

    for subscription in state.get("subscriptions", []):
        if subscription.get("archived") or subscription.get("cancelledAt"):
            continue
        advance = int(subscription.get("reminderDays", default_advance))
        advances = {advance, 0} if subscription.get("autoRenew", True) else {advance}
        for day_count in advances:
            lower = (earliest + timedelta(days=day_count)).astimezone(zone)
            upper = (now + timedelta(days=day_count)).astimezone(zone)
            for bill in monthly._bills(subscription, state, lower, upper, zone):
                if monthly._covered(bill, subscription, state):
                    continue
                bill_date = parse_instant(bill["due"], zone)
                notice_at = (bill_date - timedelta(days=day_count)).replace(hour=hour)
                add(notice_at, f"bill|{bill['id']}|{day_count}",
                    f"{subscription['name']} · {bill['currency']} {bill['price']}", "有固定支出待核对。")
        trial = read_cocoa(subscription.get("cancelDeadline") or subscription.get("trialEnd"), zone)
        if not subscription.get("trialResolved") and trial:
            add(trial - timedelta(days=1), f"trial|{subscription['id']}|{trial.date()}",
                f"{subscription['name']} 的试用即将到期，请在平台核对。", "试用即将到期。")
    for event in state.get("events", []):
        deadline = read_cocoa(event.get("deadline"), zone)
        if deadline and not event.get("doneAt"):
            add(deadline, f"event|{event['id']}|{deadline.isoformat()}", event["name"], "有到期事项待处理。")
    return sorted(result)
