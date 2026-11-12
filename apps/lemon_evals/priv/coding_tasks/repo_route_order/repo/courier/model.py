from dataclasses import dataclass
@dataclass(frozen=True)
class Rule:
    code: str
    country: str
    tiers: tuple
    max_weight: int
    hazmat: bool
    base: int
    per_kg: int
    priority: int
@dataclass(frozen=True)
class Request:
    country: str
    tier: str
    weight: int
    hazmat: bool
