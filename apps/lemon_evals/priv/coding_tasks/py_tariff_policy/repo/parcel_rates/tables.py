from decimal import Decimal

# (base up to 1 kg, each extra half kg)
RATES = {
    "local": (Decimal("4.00"), Decimal("0.80")),
    "regional": (Decimal("6.50"), Decimal("1.10")),
    "remote": (Decimal("10.00"), Decimal("1.75")),
}
FUEL_FACTOR = Decimal("1.075")
EXPRESS_FACTOR = Decimal("1.35")
