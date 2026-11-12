import unittest
from inventory.api import make_service
from inventory.engine import Engine

class CampLegacyTest(unittest.TestCase):
    def test_legacy_booking(self):
        engine = Engine({'camp:one': 4})
        service = make_service('camp', engine)
        service.book({'request_id': 'old-camp', 'camp_code': 'camp:one', 'camp_count': 2})
        self.assertEqual(engine.stock['camp:one'], 2)
