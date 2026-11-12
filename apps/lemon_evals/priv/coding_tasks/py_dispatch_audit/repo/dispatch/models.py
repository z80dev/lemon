from dataclasses import dataclass


@dataclass(frozen=True)
class Shipment:
    shipment_id: str
    account: str
    status: str
    zone: str
    actual_g: int
    dimensions_cm: tuple[int, int, int]
    fragile: bool


@dataclass(frozen=True)
class Quote:
    shipment_id: str
    billed: bool
    billable_kg: int
    gross_cents: int
    discount_cents: int
    net_cents: int
