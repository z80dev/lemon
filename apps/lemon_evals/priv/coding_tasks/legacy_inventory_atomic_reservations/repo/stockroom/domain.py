from dataclasses import dataclass


@dataclass(frozen=True)
class Stock:
    sku: str
    quantity: int
