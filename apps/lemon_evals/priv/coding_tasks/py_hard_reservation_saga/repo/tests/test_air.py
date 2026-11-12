import unittest
from inventory.api import make_service
from inventory.engine import Engine

class AirLegacyTest(unittest.TestCase):
    def test_legacy_booking(self):
        engine = Engine({'air:one': 4})
        service = make_service('air', engine)
        service.book({'request_id': 'old-air', 'air_code': 'air:one', 'air_count': 2})
        self.assertEqual(engine.stock['air:one'], 2)
