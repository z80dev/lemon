from dataclasses import dataclass
from datetime import date
@dataclass(frozen=True)
class Rate:
    lane: str
    lower: int
    upper: int
    effective: date
    cents: int
