from . import policy
from .validation import validate_quantity


def make_line(reference, weight_kg, zone, quantity=1, express=False):
    validate_quantity(quantity)
    amount = policy.calculate(weight_kg, zone, express)
    return {"reference": reference, "unit_amount": amount, "quantity": quantity,
            "total": amount * quantity, "currency": "USD"}
