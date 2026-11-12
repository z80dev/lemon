import unittest
from analytics.api import ingest
from analytics.ledger import Ledger

class UploadLegacyTest(unittest.TestCase):
    def test_positive_event(self):
        rows = [{'upload_id': 'one', 'upload_tenant': 't', 'upload_day': '2026-01-01', 'upload_value': 8}]
        self.assertEqual(ingest('upload', Ledger(), rows), [{'tenant':'t','day':'2026-01-01','value':8,'count':1}])
