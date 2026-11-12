import unittest
from analytics.api import ingest
from analytics.ledger import Ledger

class IndexLegacyTest(unittest.TestCase):
    def test_positive_event(self):
        rows = [{'index_id': 'one', 'index_tenant': 't', 'index_day': '2026-01-01', 'index_value': 14}]
        self.assertEqual(ingest('index', Ledger(), rows), [{'tenant':'t','day':'2026-01-01','value':14,'count':1}])
