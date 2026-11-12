import unittest
from analytics.api import ingest
from analytics.ledger import Ledger

class DownloadLegacyTest(unittest.TestCase):
    def test_positive_event(self):
        rows = [{'download_id': 'one', 'download_tenant': 't', 'download_day': '2026-01-01', 'download_value': 7}]
        self.assertEqual(ingest('download', Ledger(), rows), [{'tenant':'t','day':'2026-01-01','value':7,'count':1}])
