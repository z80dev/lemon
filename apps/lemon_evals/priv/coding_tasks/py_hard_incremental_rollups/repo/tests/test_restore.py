import unittest
from analytics.api import ingest
from analytics.ledger import Ledger

class RestoreLegacyTest(unittest.TestCase):
    def test_positive_event(self):
        rows = [{'restore_id': 'one', 'restore_tenant': 't', 'restore_day': '2026-01-01', 'restore_value': 12}]
        self.assertEqual(ingest('restore', Ledger(), rows), [{'tenant':'t','day':'2026-01-01','value':12,'count':1}])
