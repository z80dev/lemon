import io
import unittest
from credit_rollup import RowError, rollup


class RollupTests(unittest.TestCase):
    def test_sale_and_refund(self):
        report = rollup(io.StringIO("account,currency,kind,amount,memo\nAcme,USD,sale,12.50,invoice\nAcme,USD,refund,2.25,return\n"))
        self.assertEqual(report["totals"], {"count": 2, "sales": "12.50", "refunds": "2.25", "net": "10.25"})
        self.assertEqual(report["groups"][0]["account"], "Acme")

    def test_header(self):
        with self.assertRaises(RowError) as caught:
            rollup(io.StringIO("amount,account\n"))
        self.assertEqual(str(caught.exception), "record 0, line 1: expected header account,currency,kind,amount,memo")

    def test_empty_report(self):
        self.assertEqual(rollup(io.StringIO("account,currency,kind,amount,memo\n"))["groups"], [])
