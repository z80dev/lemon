from dataclasses import dataclass


@dataclass(frozen=True)
class Stock:
    sku: str
    quantity: int
    reserved: int = 0

    @property
    def available(self):
        return self.quantity - self.reserved
