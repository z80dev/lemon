import tempfile
import unittest
from pathlib import Path
from stockroom.repository import Repository
from stockroom.service import Service


class StockroomTests(unittest.TestCase):
    def test_add_and_list(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = Repository(Path(directory) / "stock.db")
            try:
                service = Service(repository)
                service.add_stock(" B ", 2)
                service.add_stock("B", 3)
                service.add_stock("A", 1)
                self.assertEqual([(s.sku, s.quantity) for s in service.inventory()],
                                 [("A", 1), ("B", 5)])
                with self.assertRaises(ValueError):
                    service.add_stock("A", True)
            finally:
                repository.close()
