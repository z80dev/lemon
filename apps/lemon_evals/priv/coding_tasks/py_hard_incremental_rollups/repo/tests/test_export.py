import unittest
from analytics.api import ingest
from analytics.ledger import Ledger

class ExportLegacyTest(unittest.TestCase):
    def test_positive_event(self):
        rows = [{'export_id': 'one', 'export_tenant': 't', 'export_day': '2026-01-01', 'export_value': 15}]
        self.assertEqual(ingest('export', Ledger(), rows), [{'tenant':'t','day':'2026-01-01','value':15,'count':1}])
