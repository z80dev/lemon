import unittest
from inventory.api import make_service
from inventory.engine import Engine

class LoungeLegacyTest(unittest.TestCase):
    def test_legacy_booking(self):
        engine = Engine({'lounge:one': 4})
        service = make_service('lounge', engine)
        service.book({'request_id': 'old-lounge', 'lounge_code': 'lounge:one', 'lounge_count': 2})
        self.assertEqual(engine.stock['lounge:one'], 2)
