import unittest
from analytics.api import ingest
from analytics.ledger import Ledger

class QueryLegacyTest(unittest.TestCase):
    def test_positive_event(self):
        rows = [{'query_id': 'one', 'query_tenant': 't', 'query_day': '2026-01-01', 'query_value': 10}]
        self.assertEqual(ingest('query', Ledger(), rows), [{'tenant':'t','day':'2026-01-01','value':10,'count':1}])
