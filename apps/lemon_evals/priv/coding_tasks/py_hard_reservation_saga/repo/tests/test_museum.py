import unittest
from inventory.api import make_service
from inventory.engine import Engine

class MuseumLegacyTest(unittest.TestCase):
    def test_legacy_booking(self):
        engine = Engine({'museum:one': 4})
        service = make_service('museum', engine)
        service.book({'request_id': 'old-museum', 'museum_code': 'museum:one', 'museum_count': 2})
        self.assertEqual(engine.stock['museum:one'], 2)
