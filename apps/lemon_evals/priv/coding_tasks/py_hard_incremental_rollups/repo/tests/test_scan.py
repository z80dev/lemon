import unittest
from analytics.api import ingest
from analytics.ledger import Ledger

class ScanLegacyTest(unittest.TestCase):
    def test_positive_event(self):
        rows = [{'scan_id': 'one', 'scan_tenant': 't', 'scan_day': '2026-01-01', 'scan_value': 13}]
        self.assertEqual(ingest('scan', Ledger(), rows), [{'tenant':'t','day':'2026-01-01','value':13,'count':1}])
