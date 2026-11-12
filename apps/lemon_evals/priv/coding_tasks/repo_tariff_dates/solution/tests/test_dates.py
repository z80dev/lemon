import unittest
from datetime import date,datetime
from postroom.catalog import lookup
from postroom.invoice import quote_invoice
class DateTests(unittest.TestCase):
    def test_date_boundary(self):
        self.assertEqual(lookup('NW-03',250,date(2024,12,31)).cents,266)
        self.assertEqual(lookup('NW-03',250,date(2025,1,1)).cents,297)
        self.assertEqual(lookup('NW-03',251,date(2025,1,1)).cents,342)
    def test_consumer(self):
        invoice={'lane':'NW-03','grams':250,'shipping_date':'2025-01-01','billed_on':'2026-01-01','handling_cents':10}
        self.assertEqual(quote_invoice(invoice),{'postage_cents':297,'handling_cents':10,'total_cents':307})
    def test_errors(self):
        with self.assertRaisesRegex(ValueError,'NO_EFFECTIVE_RATE'): lookup('NW-00',1,date(2023,12,31))
        with self.assertRaisesRegex(ValueError,'OVERWEIGHT'): lookup('NW-00',5001,date(2026,1,1))
