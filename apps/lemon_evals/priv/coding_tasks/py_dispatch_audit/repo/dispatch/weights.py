"""Carrier chargeable-weight policy, using integer ceiling division."""


def _ceil_div(value, divisor):
    return (value + divisor - 1) // divisor


def billable_kg(shipment):
    length, width, height = shipment.dimensions_cm
    volumetric = _ceil_div(length * width * height, 5000)
    actual = _ceil_div(shipment.actual_g, 1000)
    return max(actual, volumetric)
