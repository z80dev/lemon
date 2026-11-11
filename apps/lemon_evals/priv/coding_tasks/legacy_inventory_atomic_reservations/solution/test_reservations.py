import contextlib
import io
import json
import sqlite3
import tempfile
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from stockroom.cli import main
from stockroom.domain import Stock
from stockroom.repository import Repository
from stockroom.service import Service


class ReservationTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.path = Path(directory.name) / "stock.db"
        self.repository = Repository(self.path)
        self.addCleanup(self.repository.close)
        self.service = Service(self.repository)
        self.service.add_stock("A", 10)
        self.service.add_stock("B", 4)

    def state(self):
        return (
            list(self.repository.connection.execute(
                "SELECT sku, quantity, reserved FROM stocks ORDER BY sku"
            )),
            list(self.repository.connection.execute(
                "SELECT order_id, items FROM reservation_orders ORDER BY order_id"
            )),
        )

    def test_stock_available_and_missing(self):
        self.assertEqual(Stock("A", 10).available, 10)
        self.assertEqual(Stock("A", 10, 3).available, 7)
        with self.assertRaises(KeyError):
            self.repository.stock("missing")

    def test_normalization_aggregation_and_durable_replay(self):
        expected = {"order_id": "one", "items": [
            {"sku": "A", "quantity": 5}, {"sku": "B", "quantity": 2}
        ]}
        result = self.service.reserve(" one ", [
            {"sku": "B", "quantity": 2},
            {"sku": " A ", "quantity": 2},
            {"sku": "A", "quantity": 3},
        ])
        self.assertEqual(result, expected)
        result["items"][0]["quantity"] = 999
        self.assertEqual(self.repository.stock("A"), Stock("A", 10, 5))
        second = Repository(self.path)
        self.addCleanup(second.close)
        other = Service(second)
        self.assertEqual(second.stock("A").available, 5)
        other.reserve("two", [{"sku": "A", "quantity": 5}])
        self.assertEqual(self.repository.stock("A").available, 0)
        self.assertEqual(self.service.reserve("one", list(reversed(expected["items"]))), expected)
        before = self.state()
        with self.assertRaises(ValueError):
            other.reserve("one", [{"sku": "A", "quantity": 4}])
        self.assertEqual(self.state(), before)
        self.service.add_stock(" A ", 2)
        self.assertEqual(second.stock("A"), Stock("A", 12, 10))
        self.repository.close()
        second.close()
        reopened = Repository(self.path)
        self.addCleanup(reopened.close)
        self.assertEqual(Service(reopened).reserve(" one ", expected["items"]), expected)
        self.assertEqual(reopened.stock("A"), Stock("A", 12, 10))

    def test_failures_rollback_every_line_and_do_not_claim_id(self):
        cases = [
            (ValueError, [{"sku": "A", "quantity": 1}, {"sku": "B", "quantity": 5}]),
            (KeyError, [{"sku": "A", "quantity": 1}, {"sku": "Z", "quantity": 1}]),
            (ValueError, [{"sku": "A", "quantity": 6}, {"sku": " A ", "quantity": 5}]),
        ]
        before = self.state()
        for index, (kind, lines) in enumerate(cases):
            with self.subTest(lines=lines):
                with self.assertRaises(kind):
                    self.service.reserve(str(index), lines)
                self.assertEqual(self.state(), before)
        for index in range(len(cases)):
            self.service.reserve(str(index), [{"sku": "B", "quantity": 1}])
        self.assertEqual(self.repository.stock("B").reserved, 3)

    def test_database_failure_rolls_back_stock_and_order(self):
        self.repository.connection.execute(
            "CREATE TRIGGER fail_order BEFORE INSERT ON reservation_orders "
            "BEGIN SELECT RAISE(ABORT, 'order write failed'); END"
        )
        before = self.state()
        with self.assertRaises(sqlite3.IntegrityError):
            self.service.reserve("retry", [{"sku": "A", "quantity": 2}])
        self.assertEqual(self.state(), before)
        self.repository.connection.execute("DROP TRIGGER fail_order")
        self.service.reserve("retry", [{"sku": "A", "quantity": 2}])
        self.assertEqual(self.repository.stock("A").reserved, 2)

    def test_invalid_inputs_are_value_errors_without_writes(self):
        valid = [{"sku": "A", "quantity": 1}]
        cases = [(value, valid) for value in [None, 0, True, "", " \t "]]
        cases += [("invalid", lines) for lines in [
            None, {}, (), [], "A:1", [None], [[]], [{}],
            [{"sku": "A"}], [{"quantity": 1}],
        ]]
        cases += [("invalid", [{"sku": value, "quantity": 1}])
                  for value in [None, 3, True, "", " \t "]]
        cases += [("invalid", [{"sku": "A", "quantity": value}])
                  for value in [None, True, False, 0, -1, 1.5, "2"]]
        cases.append(("invalid", [valid[0], {"sku": "B", "quantity": False}]))
        before = self.state()
        for order_id, lines in cases:
            with self.subTest(order_id=order_id, lines=lines):
                with self.assertRaises(ValueError):
                    self.service.reserve(order_id, lines)
                self.assertEqual(self.state(), before)

    def test_upgrades_legacy_database_without_losing_stock(self):
        path = self.path.with_name("legacy.db")
        with contextlib.closing(sqlite3.connect(path)) as connection:
            with connection:
                connection.execute("CREATE TABLE stocks(sku TEXT PRIMARY KEY, quantity INTEGER NOT NULL)")
                connection.executemany("INSERT INTO stocks VALUES (?, ?)", [("B", 4), ("A", 10)])
        legacy = Repository(path)
        self.addCleanup(legacy.close)
        self.assertEqual(legacy.all(), [Stock("A", 10), Stock("B", 4)])
        expected = Service(legacy).reserve("legacy", [{"sku": "A", "quantity": 10}])
        legacy.close()
        reopened = Repository(path)
        self.addCleanup(reopened.close)
        self.assertEqual(reopened.stock("A"), Stock("A", 10, 10))
        self.assertEqual(Service(reopened).reserve("legacy", expected["items"]), expected)

    def competing_reservations(self, order_ids):
        barrier = threading.Barrier(2)

        def reserve(order_id):
            repository = Repository(self.path)
            try:
                barrier.wait(timeout=10)
                try:
                    return Service(repository).reserve(order_id, [{"sku": "A", "quantity": 7}])
                except ValueError:
                    return None
            finally:
                repository.close()

        with ThreadPoolExecutor(max_workers=2) as executor:
            futures = [executor.submit(reserve, order_id) for order_id in order_ids]
            return [future.result(timeout=15) for future in futures]

    def test_concurrent_orders_cannot_oversubscribe(self):
        results = self.competing_reservations(["first", "second"])
        self.assertEqual(sum(result is not None for result in results), 1)
        self.assertEqual(self.repository.stock("A"), Stock("A", 10, 7))
        self.assertEqual(len(self.state()[1]), 1)

    def test_concurrent_replay_only_reserves_once(self):
        results = self.competing_reservations(["same", "same"])
        self.assertEqual(results[0], results[1])
        self.assertIsNotNone(results[0])
        self.assertEqual(self.repository.stock("A").reserved, 7)
        self.assertEqual(len(self.state()[1]), 1)

    def cli(self, *args):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = main(["--db", str(self.path), *args])
        return status, stdout.getvalue(), stderr.getvalue()

    def test_cli_reserve_and_legacy_outputs(self):
        expected = {"order_id": "cli", "items": [{"sku": "B", "quantity": 2}]}
        for _ in range(2):
            status, stdout, stderr = self.cli("reserve", "cli", " B :1", "B:1")
            self.assertEqual(status, 0)
            self.assertEqual(json.loads(stdout), expected)
            self.assertEqual(stderr, "")
        status, stdout, stderr = self.cli("list")
        self.assertEqual((status, stderr), (0, ""))
        self.assertEqual(json.loads(stdout), [{"sku": "A", "quantity": 10}, {"sku": "B", "quantity": 4}])
        status, stdout, stderr = self.cli("add", "C", "3")
        self.assertEqual((status, stderr), (0, ""))
        self.assertEqual(json.loads(stdout), {"sku": "C", "quantity": 3})

    def test_cli_errors_have_no_stdout_or_traceback(self):
        before = self.state()
        for order_id, line in [("bad", "A:no"), ("bad", "A"), ("bad", "A:0"),
                               ("bad", "A:-1"), ("bad", ":1"), (" ", "A:1"),
                               ("bad", "missing:1"), ("bad", "A:11")]:
            with self.subTest(order_id=order_id, line=line):
                status, stdout, stderr = self.cli("reserve", order_id, line)
                self.assertEqual(status, 2)
                self.assertEqual(stdout, "")
                self.assertEqual(len(stderr.strip().splitlines()), 1)
                self.assertNotIn("Traceback", stderr)
                self.assertEqual(self.state(), before)
