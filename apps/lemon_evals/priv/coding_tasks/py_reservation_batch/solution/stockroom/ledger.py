from .models import InventoryError, Operation, Stock, VersionConflict


class Ledger:
    """Synchronous inventory ledger with atomic, versioned batches."""

    def __init__(self, initial):
        if any(not isinstance(sku, str) or not sku or type(count) is not int or count < 0
               for sku, count in initial.items()):
            raise ValueError("invalid initial stock")
        self._stock = {sku: Stock(count) for sku, count in initial.items()}
        self._version = 0

    @property
    def version(self):
        return self._version

    def snapshot(self):
        return dict(self._stock)

    def _check_version(self, expected_version):
        if expected_version is not None:
            if type(expected_version) is not int or expected_version < 0:
                raise ValueError("invalid expected version")
            if expected_version != self._version:
                raise VersionConflict(expected_version, self._version)

    def reserve(self, sku, quantity, *, expected_version=None):
        return self.apply_batch((Operation("reserve", sku, quantity),), expected_version=expected_version)

    def release(self, sku, quantity, *, expected_version=None):
        return self.apply_batch((Operation("release", sku, quantity),), expected_version=expected_version)

    def apply_batch(self, operations, *, expected_version=None):
        self._check_version(expected_version)
        staged = dict(self._stock)
        changed = False
        for operation in operations:
            if not isinstance(operation, Operation):
                raise TypeError("expected Operation")
            if operation.action not in ("reserve", "release"):
                raise ValueError("unknown action")
            if type(operation.quantity) is not int or operation.quantity <= 0:
                raise ValueError("quantity must be a positive integer")
            stock = staged[operation.sku]
            amount = operation.quantity
            if operation.action == "reserve":
                if stock.available < amount:
                    raise InventoryError(f"insufficient available stock: {operation.sku}")
                staged[operation.sku] = Stock(stock.available - amount, stock.reserved + amount)
            else:
                if stock.reserved < amount:
                    raise InventoryError(f"insufficient reserved stock: {operation.sku}")
                staged[operation.sku] = Stock(stock.available + amount, stock.reserved - amount)
            changed = True
        if changed:
            self._stock = staged
            self._version += 1
        return self._version
