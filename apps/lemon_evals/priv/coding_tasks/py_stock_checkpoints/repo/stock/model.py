from dataclasses import dataclass

@dataclass(frozen=True)
class Movement:
    event_id: str
    revision: int
    sku: str
    at: int
    delta: int

@dataclass(frozen=True)
class Checkpoint:
    sku: str
    at: int
