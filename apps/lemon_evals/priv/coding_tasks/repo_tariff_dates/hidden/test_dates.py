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

class CatalogMatrix(unittest.TestCase):
    def test_data_unchanged(self):
        import json
        from pathlib import Path
        from postroom.catalog import ROWS
        actual=[[r.lane,r.lower,r.upper,r.effective.isoformat(),r.cents] for r in ROWS]
        self.assertEqual(actual,json.loads(Path('/verify/rows.json').read_text()))
    def test_full_matrix(self):
        bounds=[0,100,250,500,1000,2000,5000]
        for lane in range(60):
            for year in (2024,2025,2026,2030):
                published=min(year,2026)
                for band,(lower,upper) in enumerate(zip(bounds,bounds[1:])):
                    for grams in {lower+1,upper}:
                        rate=lookup(f'NW-{lane:02d}',grams,date(year,1,1))
                        self.assertEqual((rate.lower,rate.upper,rate.effective,rate.cents),(lower,upper,date(published,1,1),200+lane*7+(published-2024)*31+band*45))
    def test_error_contract(self):
        valid=date(2025,1,1)
        for weight in (0,-1,True,1.5,'100',None):
            with self.subTest(weight=weight):
                with self.assertRaisesRegex(ValueError,'^INVALID_WEIGHT$'): lookup('missing',weight,'bad')
        for day in ('2025-01-01',None,datetime(2025,1,1)):
            with self.assertRaisesRegex(ValueError,'^INVALID_DATE$'): lookup('missing',1,day)
        with self.assertRaisesRegex(LookupError,'^UNKNOWN_LANE$'): lookup('nw-00',1,valid)
        with self.assertRaisesRegex(ValueError,'^NO_EFFECTIVE_RATE$'): lookup('NW-00',99999,date(2020,1,1))
        with self.assertRaisesRegex(ValueError,'^OVERWEIGHT$'): lookup('NW-00',5001,valid)
    def test_invoice_invalid_date_and_handling(self):
        for raw in ('bad','2025-02-30',None):
            with self.assertRaisesRegex(ValueError,'INVALID_DATE'):
                quote_invoice({'lane':'NW-00','grams':1,'shipping_date':raw,'billed_on':'2025-01-01'})
        with self.assertRaisesRegex(ValueError,'INVALID_HANDLING'):
            quote_invoice({'lane':'NW-00','grams':1,'shipping_date':'2025-01-01','handling_cents':-1})
