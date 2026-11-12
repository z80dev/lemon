import unittest
from inventory.api import make_service
from inventory.engine import Engine

class LockerLegacyTest(unittest.TestCase):
    def test_legacy_booking(self):
        engine = Engine({'locker:one': 4})
        service = make_service('locker', engine)
        service.book({'request_id': 'old-locker', 'locker_code': 'locker:one', 'locker_count': 2})
        self.assertEqual(engine.stock['locker:one'], 2)
