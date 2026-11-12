import unittest
from analytics.api import ingest
from analytics.ledger import Ledger

class ShipmentLegacyTest(unittest.TestCase):
    def test_positive_event(self):
        rows = [{'shipment_id': 'one', 'shipment_tenant': 't', 'shipment_day': '2026-01-01', 'shipment_value': 3}]
        self.assertEqual(ingest('shipment', Ledger(), rows), [{'tenant':'t','day':'2026-01-01','value':3,'count':1}])
