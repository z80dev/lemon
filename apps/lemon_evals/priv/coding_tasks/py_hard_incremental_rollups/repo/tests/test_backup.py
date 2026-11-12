import unittest
from analytics.api import ingest
from analytics.ledger import Ledger

class BackupLegacyTest(unittest.TestCase):
    def test_positive_event(self):
        rows = [{'backup_id': 'one', 'backup_tenant': 't', 'backup_day': '2026-01-01', 'backup_value': 11}]
        self.assertEqual(ingest('backup', Ledger(), rows), [{'tenant':'t','day':'2026-01-01','value':11,'count':1}])
