from . import validation


class Service:
    def __init__(self, repository):
        self.repository = repository

    def add_stock(self, sku, quantity):
        return self.repository.add(
            validation.sku(sku), validation.positive_quantity(quantity)
        )

    def inventory(self):
        return self.repository.all()
