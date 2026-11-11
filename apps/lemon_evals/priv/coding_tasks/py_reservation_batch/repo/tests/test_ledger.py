import unittest
from stockroom import InventoryError, Ledger, Operation, Stock, VersionConflict


class LedgerTests(unittest.TestCase):
    def test_batch_commits_one_version(self):
        ledger = Ledger({"tea": 8, "cup": 3})
        version = ledger.apply_batch([Operation("reserve", "tea", 3), Operation("reserve", "cup", 2),
                                      Operation("release", "tea", 1)], expected_version=0)
        self.assertEqual(version, 1)
        self.assertEqual(ledger.snapshot(), {"tea": Stock(6, 2), "cup": Stock(1, 2)})

    def test_later_failure_rolls_back(self):
        ledger = Ledger({"tea": 4})
        with self.assertRaisesRegex(InventoryError, "insufficient reserved stock: tea"):
            ledger.apply_batch([Operation("reserve", "tea", 2), Operation("release", "tea", 3)])
        self.assertEqual(ledger.snapshot(), {"tea": Stock(4, 0)})
        self.assertEqual(ledger.version, 0)

    def test_single_operations_and_conflict(self):
        ledger = Ledger({"tea": 4})
        self.assertEqual(ledger.reserve("tea", 2, expected_version=0), 1)
        with self.assertRaises(VersionConflict) as error:
            ledger.release("tea", 1, expected_version=0)
        self.assertEqual((error.exception.expected, error.exception.actual), (0, 1))
        self.assertEqual(ledger.release("tea", 2, expected_version=1), 2)
        self.assertEqual(ledger.apply_batch([], expected_version=2), 2)

    def test_snapshot_and_initial_mapping_are_detached(self):
        source = {"tea": 2}
        ledger = Ledger(source)
        source["tea"] = 50
        snapshot = ledger.snapshot()
        snapshot.clear()
        self.assertEqual(ledger.snapshot(), {"tea": Stock(2)})


if __name__ == "__main__":
    unittest.main()
