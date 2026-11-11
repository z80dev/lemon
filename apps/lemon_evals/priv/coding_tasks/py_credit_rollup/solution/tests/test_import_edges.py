import io
import unittest
from credit_rollup import RowError, rollup


class ImportEdges(unittest.TestCase):
    def test_quoted_memo_and_refund(self):
        result = rollup(io.StringIO('account,currency,kind,amount,memo\nB,USD,refund,0.1,"return, approved"\nA,USD,sale,0.03,x\n'))
        self.assertEqual([g["account"] for g in result["groups"]], ["A", "B"])
        self.assertEqual(result["totals"]["net"], "-0.07")

    def test_start_line(self):
        with self.assertRaises(RowError) as caught:
            rollup(io.StringIO('account,currency,kind,amount,memo\n\nA,USD,sale,1,"a\nb"\nB,USD,sale,-1,x\n'))
        self.assertEqual((caught.exception.record, caught.exception.line), (2, 5))
