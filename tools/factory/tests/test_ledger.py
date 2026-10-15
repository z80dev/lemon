"""P01: durable intake, identity, idempotency and revision conflicts across OS processes."""

from __future__ import annotations

import contextlib
import sqlite3
import subprocess
import sys
import unittest

from .helpers import FACTORY_DIR, FactoryHome, git


class LedgerCliTest(unittest.TestCase):
    def setUp(self) -> None:
        self.home = FactoryHome()
        self.home.cli("register")

    def tearDown(self) -> None:
        self.home.cleanup()

    def db(self) -> contextlib.closing[sqlite3.Connection]:
        return contextlib.closing(sqlite3.connect(self.home.state_dir / "factory.db"))

    # identity -----------------------------------------------------------------------

    def test_subdirectories_and_worktrees_resolve_to_one_project(self) -> None:
        sub = self.home.repo / "apps" / "deep"
        sub.mkdir(parents=True)
        worktree = self.home.root / "wt"
        git(self.home.repo, "worktree", "add", "-q", "--detach", str(worktree))
        _, a = self.home.cli("add", "from root", "--request-key", "k-root")
        _, b = self.home.cli("add", "from subdir", "--request-key", "k-sub", cwd=sub)
        _, c = self.home.cli("add", "from worktree", "--request-key", "k-wt", cwd=worktree)
        self.assertEqual([a["task"]["id"], b["task"]["id"], c["task"]["id"]], ["F-0001", "F-0002", "F-0003"])
        _, listing = self.home.cli("list", cwd=worktree)
        self.assertEqual(len(listing["tasks"]), 3)

    def test_unregistered_clone_with_same_identity_does_not_attach(self) -> None:
        clone = self.home.root / "clone"
        subprocess.run(["git", "clone", "-q", str(self.home.repo), str(clone)], check=True)
        code, payload = self.home.cli("add", "sneaky", cwd=clone, check=False)
        self.assertEqual(code, 6)
        self.assertEqual(payload["error"], "not_registered")
        # Explicit registration of that clone attaches it to the same queue.
        git(clone, "remote", "set-url", "origin", "https://github.com/example/widget.git")
        self.home.cli("register", cwd=clone)
        _, added = self.home.cli("add", "now registered", cwd=clone)
        self.assertEqual(added["task"]["id"], "F-0001")

    def test_register_rejects_mismatched_remote(self) -> None:
        other = self.home.root / "other"
        subprocess.run(["git", "clone", "-q", str(self.home.repo), str(other)], check=True)
        git(other, "remote", "set-url", "origin", "git@github.com:someone/else.git")
        code, payload = self.home.cli("register", cwd=other, check=False)
        self.assertEqual((code, payload["error"]), (6, "not_registered"))

    # intake -----------------------------------------------------------------------

    def test_add_commits_task_and_event_together_and_reports_stopped_runtime(self) -> None:
        _, result = self.home.cli("add", "cancellation should kill the tree", "--priority", "high",
                                  "--acceptance", "fixture proves cleanup", "--request-key", "r1")
        task = result["task"]
        self.assertEqual((task["id"], task["status"], task["priority"], task["revision"]),
                         ("F-0001", "inbox", "high", 1))
        self.assertEqual(task["raw_request"], "cancellation should kill the tree")
        self.assertEqual(result["runtime_state"], "stopped")
        self.assertIn("queued for the next start", result["note"])
        with self.db() as conn:
            events = conn.execute("SELECT type, task_id FROM events").fetchall()
        self.assertEqual(events, [("task.created", "F-0001")])

    def test_simultaneous_duplicate_requests_create_one_task(self) -> None:
        argv = ["add", "same request", "--request-key", "dup-key"]
        results = self.home.cli_parallel([argv] * 16)
        self.assertEqual({code for code, _ in results}, {0})
        self.assertEqual({payload["task"]["id"] for _, payload in results}, {"F-0001"})
        self.assertEqual(sum(1 for _, payload in results if not payload["replayed"]), 1)
        with self.db() as conn:
            self.assertEqual(conn.execute("SELECT COUNT(*) FROM tasks").fetchone()[0], 1)
            self.assertEqual(conn.execute("SELECT COUNT(*) FROM events").fetchone()[0], 1)

    def test_reused_key_with_different_payload_conflicts(self) -> None:
        self.home.cli("add", "original", "--request-key", "k")
        code, payload = self.home.cli("add", "different", "--request-key", "k", check=False)
        self.assertEqual((code, payload["error"]), (3, "idempotency_conflict"))

    def test_simultaneous_distinct_requests_get_unique_sequential_ids(self) -> None:
        results = self.home.cli_parallel([["add", f"request {i}", "--request-key", f"k{i}"] for i in range(12)])
        ids = sorted(payload["task"]["id"] for _, payload in results)
        self.assertEqual(ids, [f"F-{i:04d}" for i in range(1, 13)])

    # edits ------------------------------------------------------------------------

    def test_competing_edits_of_same_revision_one_wins_other_conflicts(self) -> None:
        self.home.cli("add", "edit me")
        results = self.home.cli_parallel([
            ["edit", "F-0001", "--expected-revision", "1", "--title", "console A"],
            ["edit", "F-0001", "--expected-revision", "1", "--title", "console B"],
        ])
        codes = sorted(code for code, _ in results)
        self.assertEqual(codes, [0, 3])
        loser = next(payload for code, payload in results if code == 3)
        winner = next(payload for code, payload in results if code == 0)
        self.assertEqual(loser["error"], "revision_conflict")
        self.assertEqual(loser["current"]["revision"], 2)
        self.assertEqual(loser["current"]["title"], winner["task"]["title"])
        _, shown = self.home.cli("show", "F-0001")
        self.assertEqual(shown["task"]["raw_request"], "edit me")

    def test_prioritize_without_revision_uses_current_and_replays_idempotently(self) -> None:
        self.home.cli("add", "ui polish")
        _, first = self.home.cli("prioritize", "F-0001", "urgent", "--request-key", "p1")
        _, again = self.home.cli("prioritize", "F-0001", "urgent", "--request-key", "p1")
        self.assertEqual(first["task"]["revision"], 2)
        self.assertEqual(again["task"]["revision"], 2)

    def test_transitions_follow_lifecycle_and_cancel_needs_disposition(self) -> None:
        self.home.cli("add", "t")
        code, payload = self.home.cli("transition", "F-0001", "done", "--expected-revision", "1", "--reason", "x",
                                      check=False)
        self.assertEqual((code, payload["error"]), (2, "invalid"))
        code, payload = self.home.cli("transition", "F-0001", "cancelled", "--expected-revision", "1",
                                      "--reason", "dup", check=False)
        self.assertEqual(code, 2)
        _, ok = self.home.cli("transition", "F-0001", "cancelled", "--expected-revision", "1", "--reason", "dup",
                              "--disposition", "duplicate of F-0002")
        self.assertEqual((ok["task"]["status"], ok["task"]["disposition"]), ("cancelled", "duplicate of F-0002"))

    def test_ordering_is_priority_then_age(self) -> None:
        for text, prio in (("a", "low"), ("b", "normal"), ("c", "urgent"), ("d", "normal")):
            self.home.cli("add", text, "--priority", prio)
        _, listing = self.home.cli("list")
        self.assertEqual([t["title"] for t in listing["tasks"]], ["c", "b", "d", "a"])

    def test_seed_imports_packets_once_with_dependencies(self) -> None:
        _, first = self.home.cli("seed")
        _, again = self.home.cli("seed")
        self.assertEqual([p["id"] for p in first["imported"]], [p["id"] for p in again["imported"]])
        self.assertTrue(all(p["replayed"] for p in again["imported"]))
        ids = {p["key"]: p["id"] for p in first["imported"]}
        _, p07 = self.home.cli("show", ids["P07"])
        self.assertEqual(p07["task"]["dependencies"], [ids["P05"], ids["P06"]])
        self.assertEqual(p07["task"]["source"]["section"], "P07")
        _, listing = self.home.cli("list")
        self.assertEqual(len(listing["tasks"]), 5)


class AdmissionTest(unittest.TestCase):
    """Deterministic admission gates read the ledger, not the model."""

    def setUp(self) -> None:
        self.home = FactoryHome()
        self.home.cli("register")
        sys.path.insert(0, str(FACTORY_DIR))
        from store import Ledger

        self.ledger = Ledger(self.home.state_dir / "factory.db", "widget")
        self.epoch = self.ledger.begin_epoch(1)
        self.ledger.request_mode("running", actor="test")
        self.ledger.update_runtime(mode="running")
        (self.home.state_dir / "policy.json").write_text('{"implementation_slots": 1}')
        self.home.cli("add", "dep")
        self.home.cli("add", "work")
        for tid in ("F-0001", "F-0002"):
            self.home.cli("transition", tid, "queued", "--expected-revision", "1", "--reason", "triaged")

    def tearDown(self) -> None:
        self.home.cleanup()

    def reserve(self, tid: str, *, epoch: int | None = None, key: str | None = None) -> tuple[int, dict]:
        rev = self.ledger.get_task(tid)["revision"]
        args = ["reserve", tid, "--expected-revision", str(rev), "--epoch",
                str(self.epoch if epoch is None else epoch)]
        if key:
            args += ["--request-key", key]
        return self.home.cli(*args, check=False)

    def test_pause_refuses_admission_immediately(self) -> None:
        self.ledger.request_mode("paused", actor="console")
        code, payload = self.reserve("F-0001")
        self.assertEqual((code, payload["error"]), (5, "admission_refused"))
        self.ledger.request_mode("running", actor="console")
        code, payload = self.reserve("F-0001")
        self.assertEqual(code, 0)
        self.assertEqual(payload["attempt"]["id"], "F-0001-implement-1")
        self.assertEqual(self.ledger.get_task("F-0001")["status"], "active")

    def test_policy_capacity_limits_live_attempts(self) -> None:
        self.assertEqual(self.reserve("F-0001")[0], 0)
        code, payload = self.reserve("F-0002")
        self.assertEqual(code, 5)
        self.assertIn("policy allows 1", payload["message"])

    def test_stale_epoch_is_fenced(self) -> None:
        code, payload = self.reserve("F-0001", epoch=self.epoch - 1)
        self.assertEqual((code, payload["error"]), (5, "admission_refused"))
        code, payload = self.home.cli("checkpoint", "1", "--epoch", str(self.epoch - 1), check=False)
        self.assertEqual(code, 5)

    def test_dependencies_must_be_done_and_duplicate_reservations_replay(self) -> None:
        edit_rev = self.ledger.get_task("F-0002")["revision"]
        self.home.cli("edit", "F-0002", "--expected-revision", str(edit_rev), "--set-json",
                      '{"dependencies": ["F-0001"]}')
        code, payload = self.reserve("F-0002")
        self.assertEqual(code, 5)
        self.assertIn("depends on F-0001", payload["message"])
        _, first = self.reserve("F-0001", key="dispatch-1")
        replay = self.home.cli("reserve", "F-0001", "--expected-revision", str(first["attempt"]["task_revision"]),
                               "--epoch", str(self.epoch), "--request-key", "dispatch-1")[1]
        self.assertEqual(replay["attempt"]["id"], first["attempt"]["id"])

    def test_checkpoint_is_monotonic_and_bounded_by_the_log(self) -> None:
        last = self.ledger.last_event_seq()
        _, a = self.home.cli("checkpoint", str(last + 50), "--epoch", str(self.epoch))
        self.assertEqual(a["event_cursor"], last)
        _, b = self.home.cli("checkpoint", "1", "--epoch", str(self.epoch))
        self.assertEqual(b["event_cursor"], last)


if __name__ == "__main__":
    unittest.main()
