from dataclasses import dataclass, field
@dataclass
class State:
    used: int = 800
    limit: int = 2000
    events: list = field(default_factory=list)
    receipts: dict = field(default_factory=dict)
    audit: list = field(default_factory=list)
