"""Build Windows reminder notices from the authoritative monthly state."""

from __future__ import annotations

import locale
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
            language = store.settings.get("language")
            if language == "system":
                language = locale.getlocale()[0] or "zh"
            english = language == "en" or str(language).lower().startswith("en_")
            self.delivered = {key: date for key, date in self.delivered.items() if date >= earliest}
            for due, key, text in due_notices(state, now, zone, earliest, english=english):
                if key not in self.delivered:
                    title = "Gao Savings · Fixed expenses and deadlines" if english else "搞积蓄 · 固定支出与事项"
                    return title, text, lambda: self.delivered.__setitem__(key, due)
        return None


def due_notices(state, now, zone, earliest, *, english=False):
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
                    f"{subscription['name']} · {bill['currency']} {bill['price']}",
                    "A fixed expense is due for review." if english else "有固定支出待核对。")
        trial = read_cocoa(subscription.get("cancelDeadline") or subscription.get("trialEnd"), zone)
        if not subscription.get("trialResolved") and trial:
            add(trial - timedelta(days=1), f"trial|{subscription['id']}|{trial.date()}",
                f"The trial for {subscription['name']} is ending. Check with the service." if english
                else f"{subscription['name']} 的试用即将到期，请在平台核对。",
                "A trial is ending soon." if english else "试用即将到期。")
    for event in state.get("events", []):
        deadline = read_cocoa(event.get("deadline"), zone)
        if deadline and not event.get("doneAt"):
            add(deadline, f"event|{event['id']}|{deadline.isoformat()}", event["name"],
                "A deadline needs attention." if english else "有到期事项待处理。")
    return sorted(result)
