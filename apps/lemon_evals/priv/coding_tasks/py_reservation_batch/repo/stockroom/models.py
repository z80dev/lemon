from dataclasses import dataclass


@dataclass(frozen=True)
class Stock:
    available: int
    reserved: int = 0


@dataclass(frozen=True)
class Operation:
    action: str
    sku: str
    quantity: int


class InventoryError(ValueError):
    pass


class VersionConflict(ValueError):
    def __init__(self, expected, actual):
        self.expected = expected
        self.actual = actual
        super().__init__(f"expected version {expected}, found {actual}")
