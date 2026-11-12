import unittest
from money import format_money
from invoice import invoice_total
from receipt import receipt_total


class MoneyTests(unittest.TestCase):
    def test_consumers_preserve_formatting(self):
        for cents, expected in [(0, "$0.00"), (123, "$1.23"), (-450, "$-4.50")]:
            with self.subTest(cents=cents):
                for formatter in [format_money, invoice_total, receipt_total]:
                    self.assertEqual(formatter(cents), expected)
