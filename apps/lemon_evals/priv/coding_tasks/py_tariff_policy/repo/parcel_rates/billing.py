from decimal import Decimal, ROUND_CEILING, ROUND_HALF_UP
from .tables import EXPRESS_FACTOR, FUEL_FACTOR, RATES
from .validation import validate_quantity, validate_shipment


def _charge(weight_kg, zone, express):
    validate_shipment(weight_kg, zone, express)
    bands = (weight_kg * 2).to_integral_value(rounding=ROUND_CEILING)
    base, additional = RATES[zone]
    amount = base + max(Decimal(0), bands - 2) * additional
    if express:
        amount *= EXPRESS_FACTOR
    return (amount * FUEL_FACTOR).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)


def make_line(reference, weight_kg, zone, quantity=1, express=False):
    validate_quantity(quantity)
    amount = _charge(weight_kg, zone, express)
    return {"reference": reference, "unit_amount": amount, "quantity": quantity,
            "total": amount * quantity, "currency": "USD"}
