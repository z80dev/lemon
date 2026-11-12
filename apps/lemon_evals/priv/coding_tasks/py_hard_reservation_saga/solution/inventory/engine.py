from copy import deepcopy


def _text(value):
    return isinstance(value, str) and bool(value)


def _integer(value):
    return type(value) is int


class Engine:
    def __init__(self, stock):
        if not isinstance(stock, dict) or any(not _text(k) or not _integer(v) or v < 0 for k, v in stock.items()):
            raise ValueError('invalid stock')
        self.stock = dict(stock)
        self._receipts = {}

    def _lines(self, lines):
        if not isinstance(lines, list) or not lines:
            raise ValueError('empty lines')
        totals = {}
        for line in lines:
            if not isinstance(line, (tuple, list)) or len(line) != 2:
                raise ValueError('invalid line')
            sku, units = line
            if not _text(sku) or sku not in self.stock or not _integer(units) or units <= 0:
                raise ValueError('invalid line')
            totals[sku] = totals.get(sku, 0) + units
        return [[sku, totals[sku]] for sku in sorted(totals)]

    def reserve(self, key, lines):
        if not _text(key):
            raise ValueError('invalid key')
        normalized = self._lines(lines)
        if key in self._receipts:
            if self._receipts[key]['lines'] != normalized:
                raise ValueError('key conflict')
            return deepcopy(self._receipts[key])
        if any(self.stock[sku] < units for sku, units in normalized):
            raise ValueError('stock')
        for sku, units in normalized:
            self.stock[sku] -= units
        receipt = {'key': key, 'status': 'reserved', 'lines': normalized}
        self._receipts[key] = receipt
        return deepcopy(receipt)

    def cancel(self, key):
        if not _text(key) or key not in self._receipts:
            raise ValueError('unknown key')
        receipt = self._receipts[key]
        if receipt['status'] == 'reserved':
            for sku, units in receipt['lines']:
                self.stock[sku] += units
            receipt['status'] = 'cancelled'
        return deepcopy(receipt)

    def snapshot(self):
        return deepcopy({'version': 2, 'stock': self.stock,
                         'receipts': [self._receipts[k] for k in sorted(self._receipts)]})

    @classmethod
    def restore(cls, snapshot):
        if not isinstance(snapshot, dict) or set(snapshot) != {'version', 'stock', 'receipts'} or type(snapshot['version']) is not int or snapshot['version'] != 2:
            raise ValueError('snapshot version/schema')
        engine = cls(snapshot['stock'])
        receipts = snapshot['receipts']
        if not isinstance(receipts, list):
            raise ValueError('receipts')
        for receipt in receipts:
            if not isinstance(receipt, dict) or set(receipt) != {'key', 'status', 'lines'}:
                raise ValueError('receipt schema')
            key = receipt['key']
            if not _text(key) or key in engine._receipts or receipt['status'] not in ('reserved', 'cancelled'):
                raise ValueError('receipt identity')
            lines = engine._lines(receipt['lines'])
            if lines != receipt['lines']:
                raise ValueError('noncanonical lines')
            engine._receipts[key] = deepcopy(receipt)
        return engine

