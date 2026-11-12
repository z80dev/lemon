from dataclasses import dataclass


@dataclass(frozen=True)
class Transaction:
    account: str
    currency: str
    kind: str
    cents: int
