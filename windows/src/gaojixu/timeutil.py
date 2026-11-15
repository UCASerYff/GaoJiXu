"""Mac JSONEncoder 默认日期：自 2001-01-01 00:00:00 UTC 起的秒数。"""

from __future__ import annotations

import calendar
from datetime import datetime, timedelta, timezone

from gaojixu.errors import AppError

COCOA_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)


def cocoa(dt: datetime) -> float:
    if dt.tzinfo is None:
        raise ValueError("datetime must be timezone-aware")
    return (dt.astimezone(timezone.utc) - COCOA_EPOCH).total_seconds()


def cocoa_json(dt: datetime):
    value = cocoa(dt)
    if value == int(value):
        return int(value)
    return value


def from_cocoa(seconds: float) -> datetime:
    return COCOA_EPOCH + timedelta(seconds=float(seconds))


def ensure_aware(dt: datetime, tz=None) -> datetime:
    if dt.tzinfo is not None:
        return dt
    zone = tz or datetime.now().astimezone().tzinfo or timezone.utc
    return dt.replace(tzinfo=zone)


def in_zone(dt: datetime, tz) -> datetime:
    return ensure_aware(dt, tz).astimezone(tz)


def start_of_day(dt: datetime, tz) -> datetime:
    local = in_zone(dt, tz)
    return local.replace(hour=0, minute=0, second=0, microsecond=0)


def month_key(dt: datetime, tz) -> str:
    local = in_zone(dt, tz)
    return f"{local.year:04d}-{local.month:02d}"


def month_title(dt: datetime, tz) -> str:
    local = in_zone(dt, tz)
    return f"{local.year}年{local.month}月"


def parse_month_key(text: str):
    if not isinstance(text, str) or len(text) != 7 or text[4] != "-":
        return None
    if not (text[:4].isdigit() and text[5:].isdigit()):
        return None
    year, month = int(text[:4]), int(text[5:])
    if year <= 0 or not 1 <= month <= 12:
        return None
    return year, month


def days_in_month(year: int, month: int) -> int:
    return calendar.monthrange(year, month)[1]


def add_months(dt: datetime, months: int, anchor_day: int, tz) -> datetime:
    local = in_zone(dt, tz)
    index = local.year * 12 + (local.month - 1) + months
    year, month = index // 12, index % 12 + 1
    day = min(anchor_day, days_in_month(year, month))
    return datetime(year, month, day, local.hour, local.minute, local.second, local.microsecond, tzinfo=tz)


def add_days(dt: datetime, days: int, tz) -> datetime:
    return in_zone(dt, tz) + timedelta(days=days)


def same_month(left: datetime, right: datetime, tz) -> bool:
    return month_key(left, tz) == month_key(right, tz)


def same_day(left: datetime, right: datetime, tz) -> bool:
    a, b = in_zone(left, tz), in_zone(right, tz)
    return (a.year, a.month, a.day) == (b.year, b.month, b.day)


def parse_instant(value, tz) -> datetime:
    if isinstance(value, bool):
        raise AppError("时间格式无法识别。", "invalid")
    if isinstance(value, (int, float)):
        return from_cocoa(float(value)).astimezone(tz)
    if isinstance(value, str):
        text = value.strip()
        if not text:
            raise AppError("时间格式无法识别。", "invalid")
        for fmt in ("%Y-%m-%d %H:%M", "%Y-%m-%d"):
            try:
                parsed = datetime.strptime(text, fmt)
                return parsed.replace(tzinfo=tz)
            except ValueError:
                continue
        iso = text.replace("Z", "+00:00")
        try:
            parsed = datetime.fromisoformat(iso)
        except ValueError as exc:
            raise AppError("时间格式无法识别。", "invalid") from exc
        return ensure_aware(parsed, tz).astimezone(tz)
    raise AppError("时间格式无法识别。", "invalid")


def read_cocoa(value, tz) -> datetime | None:
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, (int, float)):
        return from_cocoa(float(value)).astimezone(tz)
    if isinstance(value, str):
        try:
            return parse_instant(value, tz)
        except AppError:
            return None
    return None


def format_minute(dt: datetime, tz) -> str:
    local = in_zone(dt, tz)
    return local.strftime("%Y-%m-%d %H:%M")


def unix_minute(dt: datetime) -> int:
    return int(dt.timestamp() // 60) * 60


def week_start(dt: datetime, tz) -> datetime:
    """Gregorian，周一为一周起点，与 Mac 月供日历 firstWeekday = 2 一致。"""
    local = start_of_day(dt, tz)
    return local - timedelta(days=local.weekday())
