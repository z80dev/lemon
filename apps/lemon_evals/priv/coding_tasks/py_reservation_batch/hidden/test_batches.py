import dataclasses
import unittest
from stockroom import InventoryError, Ledger, Operation, Stock, VersionConflict


class AtomicBatchTests(unittest.TestCase):
    def assert_unchanged(self, ledger, before, version):
        self.assertEqual(ledger.snapshot(), before)
        self.assertEqual(ledger.version, version)

    def test_all_failure_kinds_after_valid_prefix(self):
        cases = [(object(), TypeError, "expected Operation"),
                 (Operation("adjust", "a", 1), ValueError, "unknown action"),
                 (Operation("reserve", "a", True), ValueError, "quantity must be a positive integer"),
                 (Operation("release", "a", 0), ValueError, "quantity must be a positive integer"),
                 (Operation("reserve", "a", -1), ValueError, "quantity must be a positive integer"),
                 (Operation("reserve", "a", 1.5), ValueError, "quantity must be a positive integer"),
                 (Operation("reserve", "missing", 1), KeyError, None),
                 (Operation("reserve", "a", 20), InventoryError, "insufficient available stock: a"),
                 (Operation("release", "a", 20), InventoryError, "insufficient reserved stock: a")]
        for bad, error_type, message in cases:
            with self.subTest(bad=bad):
                ledger = Ledger({"a": 5, "b": 7})
                ledger.reserve("b", 2)
                before, version = ledger.snapshot(), ledger.version
                with self.assertRaises(error_type) as caught:
                    ledger.apply_batch([Operation("reserve", "a", 1), bad])
                if message is not None:
                    self.assertEqual(str(caught.exception), message)
                else:
                    self.assertEqual(caught.exception.args, ("missing",))
                self.assert_unchanged(ledger, before, version)

    def test_iterator_failure_is_not_a_commit(self):
        ledger = Ledger({"a": 8})
        boom = RuntimeError("source disconnected")
        def stream():
            yield Operation("reserve", "a", 3)
            raise boom
        with self.assertRaises(RuntimeError) as caught:
            ledger.apply_batch(stream())
        self.assertIs(caught.exception, boom)
        self.assert_unchanged(ledger, {"a": Stock(8)}, 0)
        self.assertEqual(ledger.reserve("a", 8), 1)

    def test_preconditions_before_consumption_and_validation_order(self):
        ledger = Ledger({"a": 3})
        def forbidden():
            raise AssertionError("iterator consumed")
            yield
        for expected in (True, -1, 0.0, "0"):
            with self.assertRaisesRegex(ValueError, "^invalid expected version$"):
                ledger.apply_batch(forbidden(), expected_version=expected)
        with self.assertRaises(VersionConflict) as caught:
            ledger.apply_batch(forbidden(), expected_version=2)
        self.assertEqual(str(caught.exception), "expected version 2, found 0")
        for op, message in [(Operation("bad", "missing", 0), "unknown action"),
                            (Operation("reserve", "missing", 0), "quantity must be a positive integer")]:
            with self.assertRaises(ValueError) as error:
                ledger.apply_batch([op])
            self.assertEqual(str(error.exception), message)

    def test_staged_order_empty_and_net_zero(self):
        ledger = Ledger({"a": 4, "b": 2})
        ops = [Operation("reserve", "a", 4), Operation("release", "a", 4),
               Operation("reserve", "a", 4), Operation("reserve", "b", 2)]
        self.assertEqual(ledger.apply_batch(iter(ops)), 1)
        self.assertEqual(ledger.snapshot(), {"a": Stock(0, 4), "b": Stock(0, 2)})
        self.assertEqual(ledger.apply_batch([]), 1)
        self.assertEqual(ledger.apply_batch([Operation("release", "a", 2), Operation("reserve", "a", 2)]), 2)
        self.assertEqual(ledger.release("a", 4, expected_version=2), 3)
        self.assertEqual(ledger.reserve("a", 4, expected_version=3), 4)
        self.assertEqual(ops[0], Operation("reserve", "a", 4))

    def test_constructor_and_immutable_values(self):
        for bad in ({"": 1}, {1: 2}, {"a": -1}, {"a": True}, {"a": 1.0}):
            with self.assertRaisesRegex(ValueError, "^invalid initial stock$"):
                Ledger(bad)
        self.assertEqual(Ledger({}).apply_batch([]), 0)
        stock = Ledger({"a": 1}).snapshot()["a"]
        with self.assertRaises(dataclasses.FrozenInstanceError):
            stock.available = 7
        with self.assertRaises(dataclasses.FrozenInstanceError):
            Operation("reserve", "a", 1).quantity = 2


if __name__ == "__main__":
    unittest.main()
