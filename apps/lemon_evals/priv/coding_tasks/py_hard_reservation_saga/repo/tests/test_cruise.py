import unittest
from inventory.api import make_service
from inventory.engine import Engine

class CruiseLegacyTest(unittest.TestCase):
    def test_legacy_booking(self):
        engine = Engine({'cruise:one': 4})
        service = make_service('cruise', engine)
        service.book({'request_id': 'old-cruise', 'cruise_code': 'cruise:one', 'cruise_count': 2})
        self.assertEqual(engine.stock['cruise:one'], 2)
