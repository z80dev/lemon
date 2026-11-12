import unittest
from inventory.api import make_service
from inventory.engine import Engine

class HotelLegacyTest(unittest.TestCase):
    def test_legacy_booking(self):
        engine = Engine({'hotel:one': 4})
        service = make_service('hotel', engine)
        service.book({'request_id': 'old-hotel', 'hotel_code': 'hotel:one', 'hotel_count': 2})
        self.assertEqual(engine.stock['hotel:one'], 2)
