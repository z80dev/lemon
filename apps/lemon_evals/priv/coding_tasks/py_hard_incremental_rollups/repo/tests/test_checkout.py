import unittest
from analytics.api import ingest
from analytics.ledger import Ledger

class CheckoutLegacyTest(unittest.TestCase):
    def test_positive_event(self):
        rows = [{'checkout_id': 'one', 'checkout_tenant': 't', 'checkout_day': '2026-01-01', 'checkout_value': 1}]
        self.assertEqual(ingest('checkout', Ledger(), rows), [{'tenant':'t','day':'2026-01-01','value':1,'count':1}])
