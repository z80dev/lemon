import unittest
from inventory.api import make_service
from inventory.engine import Engine

class WorkspaceLegacyTest(unittest.TestCase):
    def test_legacy_booking(self):
        engine = Engine({'workspace:one': 4})
        service = make_service('workspace', engine)
        service.book({'request_id': 'old-workspace', 'workspace_code': 'workspace:one', 'workspace_count': 2})
        self.assertEqual(engine.stock['workspace:one'], 2)
