import unittest
from analytics.api import ingest
from analytics.ledger import Ledger

class RenderLegacyTest(unittest.TestCase):
    def test_positive_event(self):
        rows = [{'render_id': 'one', 'render_tenant': 't', 'render_day': '2026-01-01', 'render_value': 9}]
        self.assertEqual(ingest('render', Ledger(), rows), [{'tenant':'t','day':'2026-01-01','value':9,'count':1}])
