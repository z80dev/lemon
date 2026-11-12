import unittest
from inventory.api import make_service
from inventory.engine import Engine

class RailLegacyTest(unittest.TestCase):
    def test_legacy_booking(self):
        engine = Engine({'rail:one': 4})
        service = make_service('rail', engine)
        service.book({'request_id': 'old-rail', 'rail_code': 'rail:one', 'rail_count': 2})
        self.assertEqual(engine.stock['rail:one'], 2)
