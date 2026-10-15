"""P03: one managed coordinator, shared by independent consoles, with bounded lifecycle.

Uses the real installed OMP in RPC mode with the deterministic fixture model
(acting as a minimal coordinator: snapshot, checkpoint, idle). No paid calls.
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import time
import unittest
from pathlib import Path

from .helpers import FACTORY_DIR, FactoryHome, git
from .omp_fixture import AGENT_CONFIG, omp_available, wait_for

sys.path.insert(0, str(FACTORY_DIR))

import compat  # noqa: E402
import omp_adapter  # noqa: E402


def omp_processes(session_dir: Path) -> list[str]:
    pattern = f"--session-dir {session_dir}"
    return subprocess.run(["pgrep", "-f", "--", pattern], capture_output=True, text=True).stdout.split()


@unittest.skipUnless(omp_available(), "installed omp and its omp_rpc client are required")
class SupervisorTest(unittest.TestCase):
    def setUp(self) -> None:
        self.home = FactoryHome()
        self.home.cli("register")
        agent = self.home.root / "agent"
        agent.mkdir()
        (agent / "config.yml").write_text(AGENT_CONFIG)
        self.fixture_log = self.home.root / "fixture.jsonl"
        self.fixture_log.touch()
        policy = {
            "allow_unreleased": True,
            "fetch_base": False,
            "implementation_slots": 1,
            "max_ready_backlog": 3,
            "max_repair_attempts": 2,
            "omp": {
                "extra_args": ["-e", str(omp_adapter.FIXTURE_PROVIDER)],
                "env": {
                    "PI_CODING_AGENT_DIR": str(agent),
                    "FACTORY_FIXTURE_LOG": str(self.fixture_log),
                    "FACTORY_FIXTURE_COORDINATOR": "1",
                },
            },
        }
        (self.home.state_dir / "policy.json").write_text(json.dumps(policy))
        previous = os.environ.get("FACTORY_STATE_HOME")
        os.environ["FACTORY_STATE_HOME"] = self.home.env["FACTORY_STATE_HOME"]
        try:
            compat.write_stamp(omp_adapter.identify(), {"suite": "fixture-test"})
        finally:
            if previous is None:
                os.environ.pop("FACTORY_STATE_HOME")
            else:
                os.environ["FACTORY_STATE_HOME"] = previous
        self.sessions = self.home.state_dir / "sessions"

    def tearDown(self) -> None:
        self.home.cli("stop", "--wait", "30", check=False)
        for pid in omp_processes(self.sessions):
            os.kill(int(pid), signal.SIGKILL)
        self.home.cleanup()

    def requests(self) -> list[dict]:
        return [json.loads(line) for line in self.fixture_log.read_text().splitlines() if line.strip()]

    def status(self) -> dict:
        return self.home.cli("status")[1]

    def start(self) -> dict:
        code, payload = self.home.cli("start", check=False)
        self.assertEqual(code, 0, payload)
        self.assertTrue(payload["ok"], payload)
        return payload

    def wait_cursor(self, seq: int) -> None:
        wait_for(lambda: self.status()["runtime"]["event_cursor"] >= seq, timeout=60)

    # -- acceptance scenarios -----------------------------------------------------------

    def test_two_simultaneous_starts_yield_one_coordinator(self) -> None:
        results = self.home.cli_parallel([["start"], ["start"], ["start"]])
        runtimes = [payload["runtime"] for _, payload in results]
        self.assertEqual({r["state"] for r in runtimes}, {"running"}, runtimes)
        self.assertEqual(len({(r["epoch"], r["supervisor_pid"], r["coordinator_pid"]) for r in runtimes}), 1)
        # Every racer may spawn a supervisor; the kernel lock admits one and the rest exit.
        log = self.home.state_dir / "logs" / "supervisor.log"
        wait_for(lambda: log.read_text().count("another supervisor owns widget; exiting") == 2, timeout=15)
        self.assertEqual(len(omp_processes(self.sessions)), 1)
        # The CLI processes that started it have all exited; another process still sees it live.
        status = self.status()["runtime"]
        self.assertEqual(status["state"], "running")
        self.assertEqual(status["coordinator_pid"], runtimes[0]["coordinator_pid"])
        self.assertLess(status["heartbeat_age_s"], 10)

    def test_add_while_running_wakes_once_then_stays_idle(self) -> None:
        self.start()
        self.wait_cursor(self.home.cli("events")[1]["events"][-1]["seq"])
        _, added = self.home.cli("add", "terminate the whole tool process tree", "--request-key", "console-b-1")
        seq = self.home.cli("events")[1]["events"][-1]["seq"]
        self.wait_cursor(seq)
        wakes = [r for r in self.requests() if "automated notification" in r["lastText"]]
        self.assertEqual(len(wakes), 1)
        self.assertIn(added["task"]["id"], wakes[0]["lastText"])
        quiet_from = len(self.requests())
        time.sleep(6)  # sustained idle: the supervisor must not prompt the model
        self.assertEqual(len(self.requests()), quiet_from)
        # Replaying the same console request does not create work or a wake.
        _, replay = self.home.cli("add", "terminate the whole tool process tree", "--request-key", "console-b-1")
        self.assertTrue(replay["replayed"])
        time.sleep(2)
        self.assertEqual(len(self.requests()), quiet_from)

    def test_add_while_stopped_is_discovered_at_start(self) -> None:
        _, added = self.home.cli("add", "queued while stopped")
        self.assertEqual(added["runtime_state"], "stopped")
        self.assertIn("next start", added["note"])
        self.start()
        created = next(e["seq"] for e in self.home.cli("events")[1]["events"] if e["type"] == "task.created")
        self.wait_cursor(created)
        startup = [r for r in self.requests() if "automated startup notice" in r["lastText"]]
        self.assertEqual(len(startup), 1)
        _, snap = self.home.cli("snapshot")
        self.assertEqual([t["id"] for t in snap["inbox"]], [added["task"]["id"]])

    def test_pause_refuses_admission_before_the_model_sees_it(self) -> None:
        self.start()
        self.home.cli("add", "work")
        self.home.cli("transition", "F-0001", "queued", "--expected-revision", "1", "--reason", "triaged")
        epoch = str(self.status()["runtime"]["epoch"])
        self.home.cli("pause")
        code, refused = self.home.cli("reserve", "F-0001", "--expected-revision", "2", "--epoch", epoch, check=False)
        self.assertEqual((code, refused["error"]), (5, "admission_refused"))
        wait_for(lambda: self.status()["runtime"]["state"] == "paused")
        before = len(self.requests())
        self.home.cli("add", "added while paused")
        time.sleep(3)
        self.assertEqual(len(self.requests()), before)  # paused: no wake
        self.home.cli("resume")
        wait_for(lambda: self.status()["runtime"]["state"] == "running")
        code, attempt = self.home.cli("reserve", "F-0001", "--expected-revision", "2", "--epoch", epoch, check=False)
        self.assertEqual(code, 0, attempt)
        wait_for(lambda: len(self.requests()) > before, timeout=30)  # resume delivers the pending events

    def test_stop_is_bounded_and_restart_resumes_session_with_new_epoch(self) -> None:
        first = self.start()["runtime"]
        coordinator = first["coordinator_pid"]
        _, stopped = self.home.cli("stop")
        self.assertEqual(stopped["runtime"]["state"], "stopped")
        self.assertFalse(stopped["runtime"]["unclean_previous_exit"])
        self.assertEqual(omp_processes(self.sessions), [])
        with self.assertRaises(ProcessLookupError):
            os.kill(coordinator, 0)
        second = self.start()["runtime"]
        self.assertEqual(second["epoch"], first["epoch"] + 1)
        self.assertEqual(second["session_id"], first["session_id"])

    def test_restart_reconciles_in_flight_attempts_without_relaunching(self) -> None:
        self.start()
        self.home.cli("add", "finished before crash")
        self.home.cli("add", "lost in crash")
        epoch = str(self.status()["runtime"]["epoch"])
        for tid in ("F-0001", "F-0002"):
            self.home.cli("transition", tid, "queued", "--expected-revision", "1", "--reason", "triaged")
        policy_path = self.home.state_dir / "policy.json"
        policy = json.loads(policy_path.read_text())
        policy["implementation_slots"] = 2
        policy_path.write_text(json.dumps(policy))
        a = self.home.cli("reserve", "F-0001", "--expected-revision", "2", "--epoch", epoch)[1]["attempt"]["id"]
        b = self.home.cli("reserve", "F-0002", "--expected-revision", "2", "--epoch", epoch)[1]["attempt"]["id"]
        for attempt in (a, b):
            self.home.cli("attempt", attempt, "--status", "launched", "--worker-ref", attempt, "--epoch", epoch)
        # Worker a retained its branch; worker b left nothing.
        checkout = self.home.state_dir / "checkout"
        git(checkout, "branch", f"omp/task/{a}", "HEAD")
        supervisor_pid = self.status()["runtime"]["supervisor_pid"]
        os.kill(supervisor_pid, signal.SIGKILL)  # crash: coordinator sees stdin EOF and exits
        wait_for(lambda: self.status()["runtime"]["state"] == "stopped", timeout=30)
        self.assertTrue(self.status()["runtime"]["unclean_previous_exit"])
        wait_for(lambda: not omp_processes(self.sessions), timeout=30)
        self.start()
        _, shown_a = self.home.cli("show", "F-0001")
        _, shown_b = self.home.cli("show", "F-0002")
        self.assertEqual(shown_a["attempts"][0]["status"], "succeeded")
        self.assertEqual(shown_a["attempts"][0]["head_sha"], git(checkout, "rev-parse", f"omp/task/{a}"))
        self.assertEqual(shown_b["attempts"][0]["status"], "launch_unknown")
        self.assertEqual(shown_b["task"]["status"], "blocked")
        self.assertEqual(len(shown_b["attempts"]), 1)  # no blind duplicate

    def test_dirty_coordinator_checkout_blocks_start_and_is_preserved(self) -> None:
        self.start()
        self.home.cli("stop")
        stray = self.home.state_dir / "checkout" / "user-edit.txt"
        stray.write_text("do not lose me\n")
        code, payload = self.home.cli("start", check=False)
        self.assertFalse(payload["ok"])
        self.assertEqual(payload["runtime"]["state"], "stopped")
        self.assertEqual(payload["runtime"]["detail"]["error"], "blocked")
        self.assertIn("local changes", payload["runtime"]["detail"]["message"])
        self.assertEqual(stray.read_text(), "do not lose me\n")
        del code

    def test_user_checkout_edits_are_never_touched(self) -> None:
        edit = self.home.repo / "README.md"
        edit.write_text("user's uncommitted edit\n")
        self.start()
        self.home.cli("stop")
        self.assertEqual(edit.read_text(), "user's uncommitted edit\n")
        self.assertEqual(git(self.home.repo, "status", "--porcelain"), "M README.md")

    def test_emergency_abort_kills_everything_and_records_uncertainty(self) -> None:
        runtime = self.start()["runtime"]
        _, aborted = self.home.cli("stop", "--abort")
        self.assertTrue(aborted["aborted"])
        self.assertIn(runtime["coordinator_pid"], aborted["killed"])
        self.assertEqual(aborted["runtime"]["state"], "stopped")
        self.assertEqual(omp_processes(self.sessions), [])
        types = [e["type"] for e in self.home.cli("events")[1]["events"]]
        self.assertIn("runtime.emergency_abort", types)


if __name__ == "__main__":
    unittest.main()
