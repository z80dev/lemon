class Repository:
    def __init__(self, engine):
        self.engine = engine

    def book(self, sku, units):
        return self.engine.book(sku, units)
