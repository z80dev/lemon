import unittest
from inventory.api import make_service
from inventory.engine import Engine

class ParkingLegacyTest(unittest.TestCase):
    def test_legacy_booking(self):
        engine = Engine({'parking:one': 4})
        service = make_service('parking', engine)
        service.book({'request_id': 'old-parking', 'parking_code': 'parking:one', 'parking_count': 2})
        self.assertEqual(engine.stock['parking:one'], 2)
