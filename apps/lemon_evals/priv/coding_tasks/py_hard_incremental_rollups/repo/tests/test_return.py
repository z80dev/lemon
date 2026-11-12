import unittest
from analytics.api import ingest
from analytics.ledger import Ledger

class ReturnLegacyTest(unittest.TestCase):
    def test_positive_event(self):
        rows = [{'return_id': 'one', 'return_tenant': 't', 'return_day': '2026-01-01', 'return_value': 4}]
        self.assertEqual(ingest('return', Ledger(), rows), [{'tenant':'t','day':'2026-01-01','value':4,'count':1}])
