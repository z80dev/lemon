"""Compute one shipment before any account aggregation."""
from .models import Quote
from .rates import FRAGILE_CENTS, RATES
from .weights import billable_kg


def quote(shipment, rebate_percent):
    if shipment.status in {"cancelled", "held"}:
        return Quote(shipment.shipment_id, False, 0, 0, 0, 0)
    kilograms = billable_kg(shipment)
    rate = RATES[shipment.zone]
    gross = rate.base_cents + kilograms * rate.per_kg_cents
    if shipment.fragile:
        gross += FRAGILE_CENTS
    discount = gross * rebate_percent // 100
    return Quote(shipment.shipment_id, True, kilograms, gross, discount, gross - discount)
