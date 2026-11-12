import unittest
from analytics.api import ingest
from analytics.ledger import Ledger

class ImportLegacyTest(unittest.TestCase):
    def test_positive_event(self):
        rows = [{'import_id': 'one', 'import_tenant': 't', 'import_day': '2026-01-01', 'import_value': 16}]
        self.assertEqual(ingest('import', Ledger(), rows), [{'tenant':'t','day':'2026-01-01','value':16,'count':1}])
