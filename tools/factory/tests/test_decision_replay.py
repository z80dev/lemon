"""Offline decision replay: deterministic MOCK records only, no network, no credentials."""

from __future__ import annotations

import ast
import contextlib
import io
import json
import socket
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from decision import replay

TIERS = {"simple": "mock/model-a", "complex": "mock/model-b"}


def rec(task_id, status="available", choice="simple", uncertainty=0.1, actual="mock/model-a", **extra):
    row = {
        "task_id": task_id,
        "recommendation": {"status": status, "choice": choice, "uncertainty": uncertainty},
        "actual_model": actual,
    }
    row.update(extra)
    return row


class EvaluateTests(unittest.TestCase):
    def test_agreement_counts_by_complexity_status_outcome(self):
        records = [
            rec("MOCK-1", outcome={"review": "approved", "repair_count": 0}),
            rec("MOCK-2", choice="complex", actual="mock/model-a", outcome={"review": "rejected", "repair_count": 2}),
            rec("MOCK-3", choice="complex", actual="mock/model-b", outcome={"review": "approved", "repair_count": 0}),
            rec("MOCK-4", status="unavailable", choice=None, uncertainty=None, actual="mock/model-a"),
            rec("MOCK-5", actual=None),
            rec("MOCK-6", choice="standard"),
        ]
        out = replay.evaluate(records, TIERS)
        self.assertEqual(out["records"], 6)
        self.assertEqual(out["comparable"], 3)
        self.assertEqual(out["agreement"], {"agree": 2, "disagree": 1})
        self.assertEqual(
            out["excluded"],
            {"no_recommendation": 1, "not_routable": 0, "unmapped_choice": 1, "actual_unknown": 1},
        )
        self.assertEqual(out["by_status"], {"available": 5, "unavailable": 1})
        self.assertEqual(out["by_complexity"]["complex"], {"records": 2, "comparable": 2, "agree": 1, "disagree": 1})
        self.assertEqual(out["by_complexity"]["none"]["comparable"], 0)
        self.assertEqual(out["by_outcome"]["review"]["approved"]["agree"], 2)
        self.assertEqual(out["by_outcome"]["review"]["rejected"]["disagree"], 1)
        self.assertEqual(out["by_outcome"]["review"]["unknown"]["records"], 3)
        self.assertEqual(out["by_outcome"]["repair"]["repaired"]["records"], 1)
        self.assertEqual(out["by_outcome"]["repair"]["not_repaired"]["records"], 2)
        self.assertEqual(out["by_outcome"]["repair"]["unknown"]["records"], 3)

    def test_unknown_actuals_never_count_as_comparable(self):
        out = replay.evaluate([rec("MOCK-1", actual=None), rec("MOCK-2", actual=None)], TIERS)
        self.assertEqual(out["comparable"], 0)
        self.assertEqual(out["excluded"]["actual_unknown"], 2)
        self.assertEqual(out["agreement"], {"agree": 0, "disagree": 0})

    def test_no_tier_models_means_nothing_comparable(self):
        out = replay.evaluate([rec("MOCK-1")])
        self.assertEqual(out["comparable"], 0)
        self.assertEqual(out["excluded"]["unmapped_choice"], 1)

    def test_summary_makes_no_accuracy_claim(self):
        out = replay.evaluate([rec("MOCK-1")], TIERS)
        blob = json.dumps(out).lower()
        for banned in ("accuracy\":", "precision", "recall", "calibrat\":", "correct"):
            self.assertNotIn(banned, blob)
        self.assertIn("not accuracy", out["disclaimer"].lower())
        self.assertNotIn("task_id", blob)
        self.assertNotIn("mock-1", blob)

    def test_empty_input(self):
        out = replay.evaluate([], TIERS)
        self.assertEqual((out["records"], out["comparable"]), (0, 0))

    def test_deterministic(self):
        records = [rec("MOCK-1"), rec("MOCK-2", choice="complex")]
        self.assertEqual(json.dumps(replay.evaluate(records, TIERS)), json.dumps(replay.evaluate(records, TIERS)))

    def test_evaluate_revalidates_raw_records(self):
        with self.assertRaises(replay.ReplayError):
            replay.evaluate([{"task_id": "x", "recommendation": {"status": "bogus"}}], TIERS)

    def test_bad_tier_models(self):
        bad_maps = (
            [],
            {"simple": 3},
            {"bad key": "m"},
            {"medium": "mock/model-a"},
            {"insufficient_information": "mock/model-a"},
            {"simple": "bad model"},
            {f"c{i}": "m" for i in range(65)},
        )
        for bad in bad_maps:
            with self.assertRaises(replay.ReplayError):
                replay.evaluate([], bad)

    def test_insufficient_information_is_not_routable(self):
        record = rec("MOCK-1", choice="insufficient_information")
        self.assertEqual(replay.parse_records(json.dumps([record]))[0]["recommendation"]["choice"], "insufficient_information")
        out = replay.evaluate([record], TIERS)
        self.assertEqual(out["comparable"], 0)
        self.assertEqual(out["excluded"]["not_routable"], 1)
        self.assertEqual(out["by_complexity"]["insufficient_information"]["records"], 1)

    def test_choice_vocabulary_is_fixed(self):
        self.assertEqual(replay.CHOICES, ("simple", "standard", "complex", "insufficient_information"))
        self.assertEqual(replay.ROUTABLE_CHOICES, ("simple", "standard", "complex"))

    def test_evaluate_consumes_at_most_max_records_plus_one(self):
        consumed = []

        def endless():
            i = 0
            while True:
                consumed.append(i)
                yield rec(f"MOCK-{i}")
                i += 1

        with self.assertRaises(replay.ReplayError):
            replay.evaluate(endless(), TIERS)
        self.assertLessEqual(len(consumed), replay.MAX_RECORDS + 1)


class ValidationTests(unittest.TestCase):
    def assertInvalid(self, payload):
        with self.assertRaises(replay.ReplayError) as ctx:
            replay.parse_records(json.dumps(payload))
        return str(ctx.exception)

    def test_malformed_shapes(self):
        self.assertInvalid({"not": "an array"})
        self.assertInvalid(["string"])
        self.assertInvalid([{"task_id": "a"}])
        self.assertInvalid([{"recommendation": {"status": "off"}}])
        self.assertInvalid([rec("a", extra_field=1)])
        self.assertInvalid([{**rec("a"), "recommendation": "oops"}])
        self.assertInvalid([{**rec("a"), "recommendation": {"status": "off", "x": 1}}])
        self.assertInvalid([rec("a", outcome="done")])
        self.assertInvalid([rec("a", outcome={"review": "ok", "extra": 1})])

    def test_bad_field_values(self):
        self.assertInvalid([rec("")])
        self.assertInvalid([rec("has space")])
        self.assertInvalid([rec("a", status="maybe")])
        self.assertInvalid([rec("a", status="available", choice=None)])
        self.assertInvalid([rec("a", choice="bad choice")])
        for unknown in ("medium", "high", "low", "Simple", "simple ", ["simple"], {"simple": 1}, 3):
            self.assertInvalid([rec("a", choice=unknown)])
        self.assertInvalid([rec("a", uncertainty=1.5)])
        self.assertInvalid([rec("a", uncertainty=-0.1)])
        self.assertInvalid([rec("a", uncertainty=True)])
        self.assertInvalid([rec("a", uncertainty="0.1")])
        self.assertInvalid([rec("a", actual="bad model\n")])
        self.assertInvalid([rec("a", actual=5)])
        self.assertInvalid([rec("a", outcome={"review": "Has Caps"})])
        self.assertInvalid([rec("a", outcome={"repair_count": -1})])
        self.assertInvalid([rec("a", outcome={"repair_count": True})])
        self.assertInvalid([rec("a", outcome={"repair_count": 1.5})])
        self.assertInvalid([rec("a", label="x" * 1000)])

    def test_duplicate_task_ids(self):
        self.assertInvalid([rec("a"), rec("a")])

    def test_invalid_json_and_nonfinite(self):
        for text in ("{", "", "[NaN]", '[{"task_id": "a", "recommendation": {"status": "off", "uncertainty": NaN}}]'):
            with self.assertRaises(replay.ReplayError):
                replay.parse_records(text)
        with self.assertRaises(replay.ReplayError):
            replay.parse_records(b"\xff\xfe")

    def test_row_bound(self):
        ok = [rec(f"MOCK-{i}") for i in range(replay.MAX_RECORDS)]
        self.assertEqual(len(replay.parse_records(json.dumps(ok))), replay.MAX_RECORDS)
        self.assertInvalid(ok + [rec("MOCK-extra")])

    def test_byte_bound(self):
        with self.assertRaises(replay.ReplayError):
            replay.parse_records(b" " * (replay.MAX_INPUT_BYTES + 1))

    def test_errors_do_not_echo_input_values(self):
        secret = "sk-SECRET-VALUE-123"
        message = self.assertInvalid([rec("a", choice=secret)])
        self.assertNotIn(secret, message)
        message = self.assertInvalid([rec(secret, status="nope")])
        self.assertNotIn(secret, message)

    def test_output_records_are_whitelisted(self):
        out = replay.parse_records(json.dumps([rec("a", label="MOCK free text", outcome={"review": "ok"})]))
        self.assertEqual(
            out,
            [
                {
                    "task_id": "a",
                    "recommendation": {"status": "available", "choice": "simple", "uncertainty": 0.1},
                    "actual_model": "mock/model-a",
                    "outcome": {"review": "ok", "repair_count": None},
                }
            ],
        )

    def test_load_records_file_errors(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(replay.ReplayError):
                replay.load_records(Path(tmp) / "missing.json")
            big = Path(tmp) / "big.json"
            big.write_bytes(b" " * (replay.MAX_INPUT_BYTES + 1))
            with self.assertRaises(replay.ReplayError):
                replay.load_records(big)


class BundledExamplesTests(unittest.TestCase):
    def test_examples_valid_labelled_mock_with_unknown_actuals(self):
        raw = json.loads(replay.EXAMPLES_PATH.read_text())
        self.assertGreaterEqual(len(raw), 2)
        for row in raw:
            self.assertTrue(row["task_id"].startswith("MOCK-"), row["task_id"])
            self.assertIn("MOCK", row["label"])
            self.assertIsNone(row["actual_model"])
        records = replay.load_examples()
        self.assertEqual(len(records), len(raw))
        out = replay.evaluate(records, TIERS)
        self.assertEqual(out["comparable"], 0)


class CliTests(unittest.TestCase):
    def run_cli(self, argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = replay.main(argv)
        return code, out.getvalue(), err.getvalue()

    def test_defaults_to_bundled_examples(self):
        code, out, err = self.run_cli([])
        self.assertEqual(code, 0, err)
        summary = json.loads(out)
        self.assertIn("MOCK", summary["source"])
        self.assertEqual(summary["records"], len(replay.load_examples()))
        self.assertEqual(summary["comparable"], 0)

    def test_input_file_and_tier_models(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "in.json"
            path.write_text(json.dumps([rec("MOCK-1"), rec("MOCK-2", choice="complex")]))
            code, out, err = self.run_cli(
                ["--input", str(path), "--tier-model", "simple=mock/model-a", "--tier-model", "complex=mock/model-b"]
            )
        self.assertEqual(code, 0, err)
        summary = json.loads(out)
        self.assertEqual(summary["agreement"], {"agree": 1, "disagree": 1})
        self.assertEqual(summary["source"], "file")

    def test_invalid_input_exit_code(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "in.json"
            path.write_text("{")
            code, out, err = self.run_cli(["--input", str(path)])
        self.assertEqual(code, 2)
        self.assertEqual(out, "")
        self.assertTrue(err.startswith("replay:"))
        self.assertEqual(self.run_cli(["--tier-model", "nonsense"])[0], 2)

    def test_no_request_option(self):
        parser_help = io.StringIO()
        with contextlib.redirect_stdout(parser_help), self.assertRaises(SystemExit):
            replay.main(["--help"])
        text = parser_help.getvalue().lower()
        for word in ("request", "network", "endpoint", "api-key", "credential"):
            self.assertNotIn(f"--{word}", text)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            replay.main(["--request"])


class IsolationTests(unittest.TestCase):
    def test_source_imports_no_adapter_network_or_credentials(self):
        tree = ast.parse(Path(replay.__file__).read_text())
        imported = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                imported.update(a.name.split(".")[0] for a in node.names)
            elif isinstance(node, ast.ImportFrom):
                imported.add((node.module or "").split(".")[0])
                if node.level:
                    imported.add("<relative>")
        banned = {
            "socket", "ssl", "http", "urllib", "requests", "httpx", "asyncio",
            "subprocess", "os", "keyring", "adapter", "transport", "credentials", "store", "<relative>",
        }
        self.assertFalse(imported & banned, imported & banned)

    def test_full_run_opens_no_sockets(self):
        def boom(*args, **kwargs):
            raise AssertionError("network touched")

        with mock.patch.object(socket, "socket", boom), mock.patch.object(socket, "create_connection", boom):
            out = replay.evaluate(replay.load_examples(), TIERS)
        self.assertEqual(out["records"], len(replay.load_examples()))


if __name__ == "__main__":
    unittest.main()
