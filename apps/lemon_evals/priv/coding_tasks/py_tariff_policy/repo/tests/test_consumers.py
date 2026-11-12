from decimal import Decimal
import unittest
from unittest.mock import patch
from parcel_rates import make_line, quote


class ConsumerTests(unittest.TestCase):
    def test_checkout_prices(self):
        self.assertEqual(quote(Decimal("1"), "local"),
                         {"service": "standard", "amount": Decimal("4.30"), "currency": "USD"})
        self.assertEqual(quote(Decimal("1.01"), "local")["amount"], Decimal("5.16"))
        self.assertEqual(quote(Decimal("1"), "local", True)["amount"], Decimal("5.81"))

    def test_invoice_uses_rounded_unit_price(self):
        self.assertEqual(make_line("ORDER-17", Decimal("1"), "local", 2, True),
                         {"reference": "ORDER-17", "unit_amount": Decimal("5.81"),
                          "quantity": 2, "total": Decimal("11.62"), "currency": "USD"})

    def test_errors(self):
        with self.assertRaisesRegex(ValueError, "^weight must be a positive finite Decimal$"):
            quote(1.5, "local")
        with self.assertRaisesRegex(ValueError, "^unknown zone$"):
            quote(Decimal("1"), "moon")
        with self.assertRaisesRegex(ValueError, "^quantity must be a positive integer$"):
            make_line("x", Decimal("1"), "local", True)

    def test_both_consumers_use_live_policy(self):
        from parcel_rates import policy
        with patch.object(policy, "calculate", return_value=Decimal("12.345")) as replacement:
            self.assertEqual(quote(Decimal("1"), "local")["amount"], Decimal("12.345"))
            line = make_line("x", Decimal("1"), "local", quantity=3)
            self.assertEqual(line["unit_amount"], Decimal("12.345"))
            self.assertEqual(line["total"], Decimal("37.035"))
            self.assertEqual(replacement.call_count, 2)


if __name__ == "__main__":
    unittest.main()
