import json
import sqlite3
from .domain import Stock


class Repository:
    def __init__(self, path):
        self.connection = sqlite3.connect(path)
        try:
            with self.connection:
                # Serialize schema inspection and migration across openers too.
                self.connection.execute("BEGIN IMMEDIATE")
                self.connection.execute(
                    "CREATE TABLE IF NOT EXISTS stocks "
                    "(sku TEXT PRIMARY KEY, quantity INTEGER NOT NULL, "
                    "reserved INTEGER NOT NULL DEFAULT 0)"
                )
                columns = {row[1] for row in self.connection.execute("PRAGMA table_info(stocks)")}
                if "reserved" not in columns:
                    self.connection.execute(
                        "ALTER TABLE stocks ADD COLUMN reserved INTEGER NOT NULL DEFAULT 0"
                    )
                self.connection.execute(
                    "CREATE TABLE IF NOT EXISTS reservation_orders "
                    "(order_id TEXT PRIMARY KEY, items TEXT NOT NULL)"
                )
        except Exception:
            self.connection.close()
            raise

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
            "SELECT sku, quantity, reserved FROM stocks WHERE sku=?", (sku,)
        ).fetchone()
        if row is None:
            raise KeyError(sku)
        return Stock(*row)

    def all(self):
        return [Stock(*row) for row in self.connection.execute(
            "SELECT sku, quantity, reserved FROM stocks ORDER BY sku"
        )]

    def reserve(self, order_id, items):
        with self.connection:
            # Acquire the write lock before replay and availability checks, so
            # concurrent connections cannot both reserve the same availability.
            self.connection.execute("BEGIN IMMEDIATE")
            previous = self.connection.execute(
                "SELECT items FROM reservation_orders WHERE order_id=?", (order_id,)
            ).fetchone()
            if previous is not None:
                saved_items = json.loads(previous[0])
                if saved_items != items:
                    raise ValueError("order ID already has a different reservation")
                return {"order_id": order_id, "items": saved_items}

            for item in items:
                stock = self.stock(item["sku"])
                if stock.available < item["quantity"]:
                    raise ValueError("insufficient available stock for " + stock.sku)
                self.connection.execute(
                    "UPDATE stocks SET reserved=reserved+? WHERE sku=?",
                    (item["quantity"], stock.sku),
                )
            self.connection.execute(
                "INSERT INTO reservation_orders(order_id, items) VALUES (?, ?)",
                (order_id, json.dumps(items, sort_keys=True)),
            )
        return {"order_id": order_id, "items": items}

    def close(self):
        self.connection.close()
