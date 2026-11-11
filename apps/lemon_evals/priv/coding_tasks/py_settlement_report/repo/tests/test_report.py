import json
import unittest
from settlement.report import build_report

class ReportTests(unittest.TestCase):
    def test_sample(self):
        with open('data/sample.json') as source:
            result = build_report(json.load(source),'2025-03','America/New_York')
        self.assertEqual(result['merchants'], [
            {'merchant':'Harbor','gross_cents':10000,'refund_cents':2500,'net_cents':7500},
            {'merchant':'Willow','gross_cents':0,'refund_cents':500,'net_cents':-500}])
    def test_empty(self):
        self.assertEqual(build_report({'charges':[],'refunds':[]},'2025-01','UTC')['merchants'], [])
