import unittest
from analytics.api import ingest
from analytics.ledger import Ledger

class RefundLegacyTest(unittest.TestCase):
    def test_positive_event(self):
        rows = [{'refund_id': 'one', 'refund_tenant': 't', 'refund_day': '2026-01-01', 'refund_value': 2}]
        self.assertEqual(ingest('refund', Ledger(), rows), [{'tenant':'t','day':'2026-01-01','value':2,'count':1}])
