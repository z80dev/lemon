from dataclasses import dataclass
@dataclass(frozen=True)
class Entry:
    account: str
    entry_id: str
    revision: int
    amount: int
    expires_at: int | None = None
    void: bool = False
