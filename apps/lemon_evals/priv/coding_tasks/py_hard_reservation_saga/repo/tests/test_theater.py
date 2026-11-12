import unittest
from inventory.api import make_service
from inventory.engine import Engine

class TheaterLegacyTest(unittest.TestCase):
    def test_legacy_booking(self):
        engine = Engine({'theater:one': 4})
        service = make_service('theater', engine)
        service.book({'request_id': 'old-theater', 'theater_code': 'theater:one', 'theater_count': 2})
        self.assertEqual(engine.stock['theater:one'], 2)
