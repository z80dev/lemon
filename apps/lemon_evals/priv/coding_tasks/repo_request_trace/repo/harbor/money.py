from decimal import Decimal, InvalidOperation
from .errors import Rejection
def cents(raw):
    try:
        value = Decimal(raw)
        if not value.is_finite() or value <= 0 or value * 100 != int(value * 100):
            raise ValueError()
        return int(value * 100)
    except (InvalidOperation, TypeError, ValueError):
        raise Rejection(400, 'AMOUNT_INVALID', 'harbor.money.cents')
