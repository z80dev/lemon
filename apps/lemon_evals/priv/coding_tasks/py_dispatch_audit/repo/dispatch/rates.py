"""Carrier tariff: base charge and charge per whole billable kilogram."""
from dataclasses import dataclass


@dataclass(frozen=True)
class Rate:
    base_cents: int
    per_kg_cents: int


RATES = {"local": Rate(120, 80), "remote": Rate(250, 140)}
FRAGILE_CENTS = 90
