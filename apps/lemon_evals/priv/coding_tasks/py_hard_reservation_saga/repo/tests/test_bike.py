import unittest
from inventory.api import make_service
from inventory.engine import Engine

class BikeLegacyTest(unittest.TestCase):
    def test_legacy_booking(self):
        engine = Engine({'bike:one': 4})
        service = make_service('bike', engine)
        service.book({'request_id': 'old-bike', 'bike_code': 'bike:one', 'bike_count': 2})
        self.assertEqual(engine.stock['bike:one'], 2)
