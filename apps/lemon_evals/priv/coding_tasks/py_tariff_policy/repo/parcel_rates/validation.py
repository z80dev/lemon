from decimal import Decimal
from .tables import RATES


def validate_shipment(weight_kg, zone, express):
    if not isinstance(weight_kg, Decimal) or not weight_kg.is_finite() or weight_kg <= 0:
        raise ValueError("weight must be a positive finite Decimal")
    if not isinstance(zone, str) or zone not in RATES:
        raise ValueError("unknown zone")
    if not isinstance(express, bool):
        raise ValueError("express must be a bool")


def validate_quantity(quantity):
    if type(quantity) is not int or quantity <= 0:
        raise ValueError("quantity must be a positive integer")
