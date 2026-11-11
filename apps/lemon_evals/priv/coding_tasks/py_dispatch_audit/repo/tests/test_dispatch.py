import unittest
from dispatch.billing import quote
from dispatch.models import Shipment
from dispatch.report import summarize
from dispatch.weights import billable_kg


def sample(**changes):
    fields = dict(shipment_id="example", account="demo", status="ready", zone="local",
                  actual_g=2000, dimensions_cm=(10, 10, 10), fragile=False)
    fields.update(changes)
    return Shipment(**fields)


class DispatchTests(unittest.TestCase):
    def test_actual_weight(self):
        self.assertEqual(billable_kg(sample()), 2)

    def test_quote(self):
        charge = quote(sample(), 0)
        self.assertTrue(charge.billed)
        self.assertEqual(charge.net_cents, 280)

    def test_held(self):
        charge = quote(sample(status="held"), 0)
        self.assertFalse(charge.billed)
        self.assertEqual(charge.net_cents, 0)

    def test_account_grouping(self):
        result = summarize([sample(), sample(shipment_id="another")], {"demo": 0})
        self.assertEqual(result["totals"]["billed"], 2)
        self.assertEqual(result["accounts"][0]["account"], "demo")
