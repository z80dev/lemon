from . import policy


def quote(weight_kg, zone, express=False):
    amount = policy.calculate(weight_kg, zone, express)
    return {"service": "express" if express else "standard", "amount": amount, "currency": "USD"}
