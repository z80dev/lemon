import unittest
from inventory.api import make_service
from inventory.engine import Engine

class TourLegacyTest(unittest.TestCase):
    def test_legacy_booking(self):
        engine = Engine({'tour:one': 4})
        service = make_service('tour', engine)
        service.book({'request_id': 'old-tour', 'tour_code': 'tour:one', 'tour_count': 2})
        self.assertEqual(engine.stock['tour:one'], 2)
