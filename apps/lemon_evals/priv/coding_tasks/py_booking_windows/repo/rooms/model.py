from dataclasses import dataclass

@dataclass(frozen=True)
class Booking:
    id: str
    room: str
    start: int
    end: int
    cancelled: bool = False
