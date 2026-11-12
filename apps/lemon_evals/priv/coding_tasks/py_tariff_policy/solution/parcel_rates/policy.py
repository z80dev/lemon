"""The shared parcel pricing policy used by checkout and invoicing."""
from decimal import Decimal, ROUND_CEILING, ROUND_HALF_UP
from .tables import EXPRESS_FACTOR, FUEL_FACTOR, RATES
from .validation import validate_shipment


def calculate(weight_kg, zone, express=False):
    validate_shipment(weight_kg, zone, express)
    bands = (weight_kg * 2).to_integral_value(rounding=ROUND_CEILING)
    base, additional = RATES[zone]
    amount = base + max(Decimal(0), bands - 2) * additional
    if express:
        amount *= EXPRESS_FACTOR
    return (amount * FUEL_FACTOR).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
