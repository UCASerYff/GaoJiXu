"""财务金额按 2 位小数归一化，半进远离零，与 Mac MoneyValue 一致。"""

from __future__ import annotations

from decimal import Decimal, ROUND_HALF_UP

SCALE = Decimal("0.01")
ZERO = Decimal("0.00")


def money(value) -> Decimal:
    if isinstance(value, bool) or value is None:
        return ZERO
    try:
        number = Decimal(str(value))
    except Exception:
        return ZERO
    if not number.is_finite():
        return ZERO
    return number.quantize(SCALE, rounding=ROUND_HALF_UP)


def money_number(value) -> float:
    return float(money(value))


def money_text(value, digits: int = 2) -> str:
    quantized = money(value)
    if digits <= 0:
        return str(int(quantized.quantize(Decimal("1"), rounding=ROUND_HALF_UP)))
    return f"{quantized:.{digits}f}"


def currency_digits(code: str) -> int:
    return 0 if code in {"JPY", "KRW"} else 2


def valid_fixed_amount(value, code: str) -> bool:
    number = Decimal(str(value))
    if not number.is_finite() or number <= 0:
        return False
    if number > Decimal("999999999999.99"):
        return False
    digits = currency_digits(code)
    quantum = Decimal("1") if digits == 0 else Decimal("0.01")
    rounded = number.quantize(quantum, rounding=ROUND_HALF_UP)
    return number == rounded
