import json
import random
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from analyze import analyze


def attempt(identifier, job, number, seq, code=None, stage="fetch"):
    event = {"type": "attempt", "id": identifier, "job": job,
             "attempt": number, "seq": seq, "stage": stage,
             "status": "ok" if code is None else "error"}
    if code is not None:
        event["code"] = code
    return event


def complete(identifier, job, number, seq, status):
    return {"type": "complete", "id": identifier, "job": job,
            "attempt": number, "seq": seq, "status": status}


def summary(**changes):
    result = {"completed": 0, "succeeded": 0, "failed": 0, "recovered": 0,
              "pending": 0, "malformed": 0, "error_counts": {}, "failures": []}
    result.update(changes)
    return result


class AnalyzeTests(unittest.TestCase):
    def test_empty(self):
        self.assertEqual(analyze(iter(["\n", "", "  \t"])), summary())
        self.assertEqual(analyze(iter([])), summary())

    def test_noise_and_nonobject_json(self):
        objects = [{}, {"type": "heartbeat", "severity": "error", "code": "NOISE"},
                   {"type": []}, {"type": {"nested": "ignored"}},
                   {"type": "other", "status": "failed", "id": "x", "job": "noise"}]
        lines = [json.dumps(event) for event in objects]
        lines += ["bad json", "null", "[]", '"text"', "42", "false", "bad json"]
        self.assertEqual(analyze(iter(lines)), summary(malformed=7))

    def test_recognized_records_validate_every_required_field(self):
        valid = [attempt("ok", "pending", 1, 0),
                 attempt("error", "pending", 1, 1, "ERR"),
                 complete("done", "finished", 1, 2, "success")]
        invalid = []
        for event in valid:
            fields = ["type", "id", "job", "attempt", "seq", "status"]
            if event["type"] == "attempt":
                fields.append("stage")
                if event["status"] == "error":
                    fields.append("code")
            for field in fields:
                if field == "type":
                    continue  # Missing type is an ignored unknown object, not malformed.
                missing = dict(event)
                del missing[field]
                invalid.append(missing)
            for field in ("id", "job"):
                for value in ("", None, 1, True, [], {}):
                    invalid.append(dict(event, **{field: value}))
            for field in ("seq", "attempt"):
                for value in (True, False, -1, 1.5, "1", None, [], {}):
                    invalid.append(dict(event, **{field: value}))
            if event["type"] == "complete":
                for value in ("ok", "error", "", None, [], {}):
                    invalid.append(dict(event, status=value))
            else:
                for value in ("other", "", None, [], {}):
                    invalid.append(dict(event, stage=value))
                for value in ("success", "failed", "", None, [], {}):
                    invalid.append(dict(event, status=value))
                if event["status"] == "error":
                    for value in ("", None, 1, False, [], {}):
                        invalid.append(dict(event, code=value))
            invalid.append(dict(event, attempt=0))
        lines = [json.dumps(event) for event in invalid + invalid + valid + valid]
        self.assertEqual(analyze(iter(lines)), summary(
            completed=1, succeeded=1, pending=1, malformed=2 * len(invalid),
            error_counts={"ERR": 1},
        ))

    def test_retries_roots_deduplication_and_out_of_order_events(self):
        records = [
            attempt("old-error", "failed", 1, 1, "OLD"),
            complete("old-done", "failed", 1, 2, "success"),
            attempt("root-b", "failed", 2, 5, "DOWNSTREAM", "commit"),
            attempt("root-a", "failed", 2, 5, "ROOT", "parse"),
            attempt("late-error", "failed", 2, 20, "LATE"),
            complete("final", "failed", 2, 10, "failed"),
            attempt("retry-error", "recovered", 1, 3, "TEMP"),
            complete("retry-old", "recovered", 1, 4, "failed"),
            complete("retry-final", "recovered", 2, 8, "success"),
            attempt("clean-late", "clean", 1, 12, "LATE"),
            complete("clean-final", "clean", 1, 9, "success"),
            complete("unknown-final", "unknown", 3, 6, "failed"),
            attempt("wrong-attempt", "unknown", 1, 2, "WRONG"),
            attempt("unknown-late", "unknown", 3, 7, "LATE"),
            attempt("pending-error", "pending-error", 2, 4, "WAIT"),
            attempt("pending-ok", "pending-ok", 1, 0),
            complete("tie-a", "tied", 1, 15, "failed"),
            complete("tie-z", "tied", 1, 15, "success"),
        ]
        expected = summary(
            completed=5, succeeded=3, failed=2, recovered=1, pending=2,
            error_counts={"OLD": 1, "DOWNSTREAM": 1, "ROOT": 1, "LATE": 3,
                          "TEMP": 1, "WRONG": 1, "WAIT": 1},
            failures=[
                {"job": "failed", "attempt": 2, "code": "ROOT", "stage": "parse", "seq": 5},
                {"job": "unknown", "attempt": 3, "code": "unknown", "stage": None, "seq": 6},
            ],
        )
        for seed in range(5):
            lines = [json.dumps(event) for event in records + records]
            random.Random(seed).shuffle(lines)
            with self.subTest(seed=seed):
                self.assertEqual(analyze(line for line in lines), expected)
                self.assertEqual(analyze(reversed(lines)), expected)

    def test_completion_seq_boundaries_and_failure_job_order(self):
        records = [
            complete("done-z", "z", 2, 5, "failed"),
            complete("done-a", "a", 3, 5, "failed"),
            attempt("root-z", "z", 2, 5, "Z", "commit"),
            attempt("root-a", "a", 3, 5, "A", "parse"),
            complete("done-success", "success", 2, 5, "success"),
            attempt("zz-after-id", "success", 1, 5, "TEMP"),
        ]
        self.assertEqual(analyze(map(json.dumps, records)), summary(
            completed=3, succeeded=1, recovered=1, failed=2,
            error_counts={"Z": 1, "A": 1, "TEMP": 1},
            failures=[
                {"job": "a", "attempt": 3, "code": "A", "stage": "parse", "seq": 5},
                {"job": "z", "attempt": 2, "code": "Z", "stage": "commit", "seq": 5},
            ],
        ))

    def test_extra_fields_do_not_invalidate_records(self):
        records = [dict(attempt("ok", "pending", 1, 0), code=[], metadata={"x": 1}),
                   dict(complete("done", "finished", 1, 1, "success"), stage=[], code={})]
        self.assertEqual(analyze(map(json.dumps, records)),
                         summary(completed=1, succeeded=1, pending=1))

    def test_cli_prints_one_json_object_for_supplied_path(self):
        records = [attempt("e", "job", 1, 2, "ROOT", "parse"),
                   complete("c", "job", 1, 3, "failed")]
        expected = summary(completed=1, failed=1, error_counts={"ROOT": 1}, failures=[
            {"job": "job", "attempt": 1, "code": "ROOT", "stage": "parse", "seq": 2},
        ])
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "custom.jsonl"
            path.write_text("\n".join(map(json.dumps, records)) + "\n", encoding="utf-8")
            result = subprocess.run([sys.executable, str(Path(__file__).with_name("analyze.py")),
                                     str(path)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertEqual(len(result.stdout.splitlines()), 1)
        self.assertEqual(json.loads(result.stdout), expected)
