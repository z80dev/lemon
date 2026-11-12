import unittest
from inventory.api import make_service
from inventory.engine import Engine

class FerryLegacyTest(unittest.TestCase):
    def test_legacy_booking(self):
        engine = Engine({'ferry:one': 4})
        service = make_service('ferry', engine)
        service.book({'request_id': 'old-ferry', 'ferry_code': 'ferry:one', 'ferry_count': 2})
        self.assertEqual(engine.stock['ferry:one'], 2)
