import unittest
from inventory.api import make_service
from inventory.engine import Engine

class ShuttleLegacyTest(unittest.TestCase):
    def test_legacy_booking(self):
        engine = Engine({'shuttle:one': 4})
        service = make_service('shuttle', engine)
        service.book({'request_id': 'old-shuttle', 'shuttle_code': 'shuttle:one', 'shuttle_count': 2})
        self.assertEqual(engine.stock['shuttle:one'], 2)
