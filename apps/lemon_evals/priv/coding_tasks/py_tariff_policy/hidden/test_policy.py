from decimal import Decimal, ROUND_CEILING, ROUND_HALF_UP
import inspect
import unittest
from unittest.mock import patch
from parcel_rates import make_line, quote
from parcel_rates import billing, policy, quotes


D = Decimal


class PolicyTests(unittest.TestCase):
    def test_weight_boundaries_zones_and_express(self):
        rates = {"local": (D("4.00"), D("0.80")), "regional": (D("6.50"), D("1.10")),
                 "remote": (D("10.00"), D("1.75"))}
        for weight in map(D, ["0.001", "0.5", "0.50001", "1", "1.00001", "1.5", "1.50001", "3", "12.25"]):
            for zone, (base, increment) in rates.items():
                for express in (False, True):
                    with self.subTest(weight=weight, zone=zone, express=express):
                        bands = (weight * 2).to_integral_value(rounding=ROUND_CEILING)
                        raw = base + max(D(0), bands - 2) * increment
                        expected = (raw * (D("1.35") if express else D(1)) * D("1.075")).quantize(
                            D("0.01"), rounding=ROUND_HALF_UP)
                        amount = policy.calculate(weight, zone, express)
                        self.assertEqual(amount, expected)
                        self.assertEqual(amount.as_tuple().exponent, -2)
                        self.assertEqual(quote(weight, zone, express)["amount"], expected)
                        line = make_line("batch", weight, zone, 7, express)
                        self.assertEqual(line["unit_amount"], expected)
                        self.assertEqual(line["total"], expected * 7)

    def test_validation_and_order(self):
        for weight in [0, 1.2, "1", None, True, D(0), D("-1"), D("NaN"), D("sNaN"), D("Infinity"), D("-Infinity")]:
            for consumer in (policy.calculate, quote):
                with self.subTest(weight=weight, consumer=consumer):
                    with self.assertRaises(ValueError) as caught:
                        consumer(weight, "invalid", express="invalid")
                    self.assertEqual(str(caught.exception), "weight must be a positive finite Decimal")
        for zone in ("", "LOCAL", "other", None, [], 12):
            with self.assertRaises(ValueError) as caught:
                policy.calculate(D(1), zone, express=1)
            self.assertEqual(str(caught.exception), "unknown zone")
        for express in (0, 1, None, "yes", D(1)):
            with self.assertRaises(ValueError) as caught:
                policy.calculate(D(1), "local", express)
            self.assertEqual(str(caught.exception), "express must be a bool")
        for quantity in (0, -1, True, 1.0, D(1), None):
            with self.assertRaises(ValueError) as caught:
                make_line("ref", None, "invalid", quantity, express="invalid")
            self.assertEqual(str(caught.exception), "quantity must be a positive integer")

    def test_replacement_after_import_affects_every_call_and_arguments(self):
        weight, reference = D("2.25"), object()
        values = [D("0.001"), D("-2.3456"), D("9.9999"), D("0")]
        with patch.object(policy, "calculate", side_effect=values) as replacement:
            self.assertEqual(quote(weight, "remote", True),
                             {"service": "express", "amount": values[0], "currency": "USD"})
            line = make_line(reference, weight, "remote", 3, True)
            self.assertIs(line["reference"], reference)
            self.assertEqual(line["unit_amount"], values[1])
            self.assertEqual(line["total"], D("-7.0368"))
            self.assertEqual(quote(weight, "remote", True)["amount"], values[2])
            self.assertEqual(make_line(reference, weight, "remote", 2, True)["total"], D(0))
            self.assertEqual(replacement.call_count, 4)
            for call in replacement.call_args_list:
                bound = inspect.signature(self.original_policy).bind(*call.args, **call.kwargs)
                self.assertEqual(bound.arguments, {"weight_kg": weight, "zone": "remote", "express": True})
        # Replacement after a prior replacement must not leave a stale alias.
        with patch.object(policy, "calculate", return_value=D("22.222")) as replacement:
            self.assertEqual(quote(D(1), "local")["amount"], D("22.222"))
            self.assertEqual(make_line("x", D(1), "local")["total"], D("22.222"))
            self.assertEqual(replacement.call_count, 2)

    def test_shared_errors_propagate_without_wrapper_or_early_shipment_validation(self):
        boom = RuntimeError("policy temporarily unavailable")
        with patch.object(policy, "calculate", side_effect=boom) as replacement:
            for invoke in (lambda: quote(None, "not-a-zone"),
                           lambda: make_line("r", None, "not-a-zone", 1)):
                with self.assertRaises(RuntimeError) as caught:
                    invoke()
                self.assertIs(caught.exception, boom)
            self.assertEqual(replacement.call_count, 2)
            with self.assertRaisesRegex(ValueError, "^quantity must be a positive integer$"):
                make_line("r", None, "bad", 0)
            self.assertEqual(replacement.call_count, 2)

    def test_obsolete_private_calculators_removed(self):
        # Removal of these helpers is an explicit structural task requirement.
        self.assertFalse(hasattr(quotes, "_charge"))
        self.assertFalse(hasattr(billing, "_charge"))

    original_policy = staticmethod(policy.calculate)


if __name__ == "__main__":
    unittest.main()
