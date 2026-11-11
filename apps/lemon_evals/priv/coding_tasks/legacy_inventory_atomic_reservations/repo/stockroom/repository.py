import sqlite3
from .domain import Stock


class Repository:
    def __init__(self, path):
        self.connection = sqlite3.connect(path)
        self.connection.execute(
            "CREATE TABLE IF NOT EXISTS stocks "
            "(sku TEXT PRIMARY KEY, quantity INTEGER NOT NULL)"
        )
        self.connection.commit()

    def add(self, sku, quantity):
        with self.connection:
            self.connection.execute(
                "INSERT INTO stocks(sku, quantity) VALUES (?, ?) "
                "ON CONFLICT(sku) DO UPDATE SET quantity=quantity+excluded.quantity",
                (sku, quantity),
            )
        return self.stock(sku)

    def stock(self, sku):
        row = self.connection.execute(
            "SELECT sku, quantity FROM stocks WHERE sku=?", (sku,)
        ).fetchone()
        if row is None:
            raise KeyError(sku)
        return Stock(*row)

    def all(self):
        return [Stock(*row) for row in self.connection.execute(
            "SELECT sku, quantity FROM stocks ORDER BY sku"
        )]

    def close(self):
        self.connection.close()
