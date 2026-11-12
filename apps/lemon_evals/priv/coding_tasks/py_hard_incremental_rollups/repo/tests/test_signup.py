import unittest
from analytics.api import ingest
from analytics.ledger import Ledger

class SignupLegacyTest(unittest.TestCase):
    def test_positive_event(self):
        rows = [{'signup_id': 'one', 'signup_tenant': 't', 'signup_day': '2026-01-01', 'signup_value': 5}]
        self.assertEqual(ingest('signup', Ledger(), rows), [{'tenant':'t','day':'2026-01-01','value':5,'count':1}])
