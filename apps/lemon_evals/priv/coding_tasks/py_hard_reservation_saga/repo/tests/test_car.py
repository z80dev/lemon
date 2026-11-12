import unittest
from inventory.api import make_service
from inventory.engine import Engine

class CarLegacyTest(unittest.TestCase):
    def test_legacy_booking(self):
        engine = Engine({'car:one': 4})
        service = make_service('car', engine)
        service.book({'request_id': 'old-car', 'car_code': 'car:one', 'car_count': 2})
        self.assertEqual(engine.stock['car:one'], 2)
