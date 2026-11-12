class Engine:
    def __init__(self, stock):
        self.stock = dict(stock)

    def book(self, sku, units):
        if self.stock.get(sku, 0) < units:
            raise ValueError('stock')
        self.stock[sku] -= units
        return {'sku': sku, 'units': units}
