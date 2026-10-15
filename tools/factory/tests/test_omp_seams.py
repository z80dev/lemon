"""P00: prove the OMP seams the factory relies on, against the installed binary.

Runs a real `omp --mode rpc` with a deterministic scripted model (no network,
no paid calls). A failure here means the installed OMP changed behavior the
factory depends on; `factory compat` refuses to stamp that version.
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import time
import unittest
from pathlib import Path

from .omp_fixture import FixtureEnv, git, omp_available, pids_matching, raw_state, script, wait_for, wait_settled

STRICT_SCHEMA = {
    "type": "object",
    "properties": {"result": {"type": "string"}},
    "required": ["result"],
    "additionalProperties": False,
}


def spawn_step(name: str, child_steps: list[dict], *, isolated: bool = True) -> dict:
    return {
        "tool": "task",
        "args": {
            "context": "factory seam fixture",
            "tasks": [
                {
                    "name": name,
                    "task": "Fixture assignment " + script(*child_steps),
                    "isolated": isolated,
                    "schemaMode": "strict",
                    "outputSchema": STRICT_SCHEMA,
                }
            ],
        },
    }


def async_results(client) -> list[dict]:
    return [m for m in client.get_messages() if m.get("customType") == "async-result"]


@unittest.skipUnless(omp_available(), "installed omp and its omp_rpc client are required")
class OmpSeamTest(unittest.TestCase):
    def setUp(self) -> None:
        self.fx = FixtureEnv()
        self.client = self.fx.client()

    def tearDown(self) -> None:
        self.client.stop()
        self.fx.cleanup()

    def test_ready_handshake_negotiates_protocol_v2(self) -> None:
        self.assertEqual(self.client._protocol_version, 2)
        state = raw_state(self.client)
        self.assertEqual(state["model"]["id"], "fixture-main")
        self.assertTrue(state["isSettled"])
        self.assertTrue(state["sessionFile"].startswith(str(self.fx.sessions)))

    def test_prompt_is_acknowledged_on_admission_not_completion(self) -> None:
        started = time.monotonic()
        self.client.prompt(script({"text": "slow", "delay_ms": 2500}))
        admitted_after = time.monotonic() - started
        self.assertLess(admitted_after, 1.5)
        self.assertFalse(raw_state(self.client)["isSettled"])
        wait_settled(self.client)
        self.assertEqual(self.client.get_last_assistant_text(), "slow")

    def test_follow_up_while_busy_is_queued_and_delivered_once(self) -> None:
        self.client.prompt(script({"text": "busy", "delay_ms": 2000}))
        self.client.follow_up("factory-wake-1")
        queued = raw_state(self.client)["queuedMessages"]["followUp"]
        self.assertEqual(queued, ["factory-wake-1"])
        wait_settled(self.client)
        seen = [r for r in self.fx.requests() if "factory-wake-1" in r["lastText"]]
        self.assertEqual(len(seen), 1)
        self.assertEqual(self.client.get_last_assistant_text(), "ack: factory-wake-1")

    def test_async_isolated_worker_retains_branch_without_applying(self) -> None:
        child = [
            {"tool": "write", "args": {"path": "worker-output.txt", "content": "from worker\n"}},
            {"tool": "yield", "args": {"data": {"result": "ok"}}},
        ]
        self.client.prompt(script(spawn_step("SeamWorker", child), {"text": "spawned"}))
        wait_settled(self.client)
        requests = self.fx.requests()
        # The parent's task call returned before the worker finished: a background job.
        spawn_result = next(r for r in requests if r["lastRole"] == "toolResult" and r["model"] == "fixture-main")
        self.assertIn("Spawned agent `SeamWorker`", spawn_result["lastText"])
        # task.agentModelOverrides from the profile survived the factory overlay.
        self.assertEqual({r["model"] for r in requests if "worker" in r["lastText"] or r["step"].get("tool") == "yield"}, {"fixture-worker"})
        delivered = async_results(self.client)[-1]["content"]
        self.assertIn("Structured output: schema valid", delivered)
        self.assertIn("captured on branch `omp/task/SeamWorker` (apply=false). Not merged.", delivered)
        # Coordinator checkout untouched; change retained on the branch.
        self.assertEqual(git(self.fx.repo, "status", "--porcelain"), "")
        self.assertFalse((self.fx.repo / "worker-output.txt").exists())
        changed = git(self.fx.repo, "diff", "--name-only", "main", "omp/task/SeamWorker").split()
        self.assertEqual(changed, ["worker-output.txt"])

    def test_strict_schema_violation_fails_the_worker(self) -> None:
        child = [{"tool": "yield", "args": {"data": {"other": 1}}}] * 6
        self.client.prompt(script(spawn_step("BadSchema", child), {"text": "spawned"}))
        wait_settled(self.client)
        delivered = async_results(self.client)[-1]["content"]
        self.assertIn('status="failed (exit 1)"', delivered)
        self.assertIn("schema_violation", delivered)

    def test_strict_schema_coerces_scalars_so_handoffs_need_independent_validation(self) -> None:
        child = [{"tool": "yield", "args": {"data": {"result": 5}}}]
        self.client.prompt(script(spawn_step("Coerced", child), {"text": "spawned"}))
        wait_settled(self.client)
        delivered = async_results(self.client)[-1]["content"]
        self.assertIn('"result": "5"', delivered)
        self.assertIn("schema valid", delivered)

    def test_isolated_worker_inherits_dirty_parent_state(self) -> None:
        # Why the coordinator checkout must be clean before dispatch.
        (self.fx.repo / "tracked.txt").write_text("DIRTY-EDIT\n")
        (self.fx.repo / "untracked.txt").write_text("untracked\n")
        child = [
            {"tool": "bash", "args": {"command": "cat tracked.txt; ls"}},
            {"tool": "yield", "args": {"data": {"result": "seen"}}},
        ]
        self.client.prompt(script(spawn_step("DirtyProbe", child), {"text": "spawned"}))
        wait_settled(self.client)
        bash_result = next(r for r in self.fx.requests() if r["model"] == "fixture-worker" and r["lastRole"] == "toolResult")
        self.assertIn("DIRTY-EDIT", bash_result["lastText"])
        self.assertIn("untracked.txt", bash_result["lastText"])

    def test_abort_terminates_tool_process_tree(self) -> None:
        marker = "sleep 4242.1"
        command = f"bash -c '{marker} & sleep 4242.2; wait'"
        self.client.prompt(script({"tool": "bash", "args": {"command": command, "timeout": 600}}, {"text": "done"}))
        wait_for(lambda: len(pids_matching("sleep 4242")) >= 2)
        self.client.abort()
        wait_for(lambda: not pids_matching("sleep 4242"), timeout=10)
        wait_settled(self.client)

    def test_stdin_close_disposes_session_and_tool_tree(self) -> None:
        command = "bash -c 'sleep 4243.1 & sleep 4243.2; wait'"
        self.client.prompt(script({"tool": "bash", "args": {"command": command, "timeout": 600}}, {"text": "done"}))
        wait_for(lambda: len(pids_matching("sleep 4243")) >= 2)
        process = self.client._process
        process.stdin.close()
        self.assertEqual(process.wait(timeout=20), 0)
        wait_for(lambda: not pids_matching("sleep 4243"), timeout=10)

    def test_sigkill_of_omp_group_orphans_tool_processes(self) -> None:
        # Tool shells run in their own process group, so an ungraceful kill of
        # OMP's group leaves them running: the supervisor must reap descendants.
        command = "bash -c 'sleep 4244.1 & sleep 4244.2; wait'"
        self.client.prompt(script({"tool": "bash", "args": {"command": command, "timeout": 600}}, {"text": "done"}))
        tool_pids = wait_for(lambda: pids_matching("sleep 4244") if len(pids_matching("sleep 4244")) >= 2 else None)
        omp_group = self.client._pgid
        try:
            self.assertNotIn(omp_group, {os.getpgid(int(pid)) for pid in tool_pids})
            os.killpg(omp_group, signal.SIGKILL)
            self.client._process.wait(timeout=10)
            time.sleep(0.5)
            self.assertTrue(pids_matching("sleep 4244"))
        finally:
            subprocess.run(["pkill", "-f", "sleep 4244"], check=False)

    def test_artifacts_branch_and_session_survive_restart(self) -> None:
        child = [
            {"tool": "write", "args": {"path": "kept.txt", "content": "kept\n"}},
            {"tool": "yield", "args": {"data": {"result": "ok"}}},
        ]
        self.client.prompt(script(spawn_step("Retained", child), {"text": "spawned"}))
        wait_settled(self.client)
        before = raw_state(self.client)
        self.client.stop()
        artifacts = Path(before["sessionFile"].removesuffix(".jsonl"))
        self.assertTrue((artifacts / "Retained.md").exists())
        self.assertTrue((artifacts / "Retained.jsonl").exists())
        self.assertIn("kept.txt", git(self.fx.repo, "show", "--name-only", "--format=", "omp/task/Retained"))
        # `--continue` with the same session dir resumes the coordinator's session.
        self.client = self.fx.client(["--continue"])
        after = raw_state(self.client)
        self.assertEqual(after["sessionId"], before["sessionId"])
        self.assertIn("Retained", json.dumps(self.client.get_messages()))


if __name__ == "__main__":
    unittest.main()
