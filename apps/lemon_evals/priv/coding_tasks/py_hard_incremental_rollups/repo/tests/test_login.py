import unittest
from analytics.api import ingest
from analytics.ledger import Ledger

class LoginLegacyTest(unittest.TestCase):
    def test_positive_event(self):
        rows = [{'login_id': 'one', 'login_tenant': 't', 'login_day': '2026-01-01', 'login_value': 6}]
        self.assertEqual(ingest('login', Ledger(), rows), [{'tenant':'t','day':'2026-01-01','value':6,'count':1}])
