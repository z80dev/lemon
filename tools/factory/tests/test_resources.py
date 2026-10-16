"""Deterministic heavy-check contention/crash tests; never start a real BEAM."""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from .helpers import FACTORY_DIR, FactoryHome
from .omp_fixture import FixtureEnv, omp_available, script, wait_settled

sys.path.insert(0, str(FACTORY_DIR))

import project as projects
import resources
import supervisor
from store import Invalid

RUNNER = FACTORY_DIR / "resources.py"
SCRIPT = FACTORY_DIR.parents[1] / "scripts" / "test"


def eventually(predicate, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.01)
    raise AssertionError("timed out waiting for fixture barrier")


class HeavyChecksTest(unittest.TestCase):
    def setUp(self):
        self.home = FactoryHome()
        self.home.cli("register")
        self.home.env.update(FACTORY_PROJECT="widget", FACTORY_HEAVY_RUNNER=str(RUNNER), FACTORY_PYTHON=sys.executable)
        (self.home.state_dir / "policy.json").write_text(json.dumps({"heavy_beam_slots": 1}))
        self.pool = resources.HeavyChecks(self.home.state_dir, 1)
        self.processes = []
        self.groups = set()
        self.addCleanup(self.home.cleanup)
        self.addCleanup(self.stop_processes)

    def stop_processes(self):
        for pgid in self.groups:
            try:
                os.killpg(pgid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        for process in self.processes:
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=10)

    def launch(self, command, timeout="0.2", env=None):
        process = subprocess.Popen([sys.executable, str(RUNNER), "run", "--timeout", timeout, "--", *command],
                                   cwd=self.home.repo, env=env or self.home.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.processes.append(process)
        return process

    def blocked_command(self, name, close_fd=False):
        ready, go = self.home.root / f"{name}.ready", self.home.root / f"{name}.go"
        code = (
            "import os, pathlib, time; "
            + ('os.close(int(os.environ["FACTORY_HEAVY_LEASE_FD"])); ' if close_fd else "")
            + f"pathlib.Path({str(ready)!r}).write_text(str(os.getpid())); "
            + f"go=pathlib.Path({str(go)!r}); "
            + "\nwhile not go.exists(): time.sleep(0.01)\n"
        )
        return [sys.executable, "-c", code], ready, go

    def wait_ready(self, ready):
        pid = eventually(lambda: ready.read_text() if ready.exists() else None)
        self.groups.add(int(pid))
        return int(pid)

    def test_checkout_setup_timeout_reaps_term_ignoring_group_before_return(self):
        ready = self.home.root / "setup.ready"
        code = (
            "import os, pathlib, signal, time; "
            "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
            "child=os.fork(); "
            f"pathlib.Path({str(ready)!r} + str(child == 0)).write_text(str(os.getpid())); "
            "\nwhile True: time.sleep(0.01)\n"
        )
        instance = supervisor.Supervisor.__new__(supervisor.Supervisor)
        instance.project = type("Project", (), {"logs_dir": self.home.state_dir / "logs"})()
        instance.project.logs_dir.mkdir(exist_ok=True)
        instance.policy = {"checkout_setup": [[sys.executable, "-c", code]], "checkout_setup_timeout_s": 1}
        instance._set = lambda *args, **kwargs: None
        instance._omp_env = lambda: self.home.env
        with self.assertRaises(supervisor.Blocked):
            instance._setup_checkout(self.home.repo, self.home.repo)
        pids = [int(Path(str(ready) + suffix).read_text()) for suffix in ("True", "False")]
        self.groups.add(pids[1])
        for pid in pids:
            self.assertIsNone(resources._identity(pid), f"setup process {pid} survived timeout")
        self.assertFalse(resources._group_live(pids[1]))
        lease = self.pool.acquire(0)
        lease.close()
        log = (instance.project.logs_dir / "checkout-setup.log").read_text()
        self.assertIn("execution timeout", log)

    def metadata(self):
        return list(self.pool.directory.glob("slot-*.json"))[0]

    def test_two_concurrent_workers_have_exactly_one_holder(self):
        command_a, ready_a, go_a = self.blocked_command("a")
        command_b, ready_b, go_b = self.blocked_command("b")
        a, b = self.launch(command_a), self.launch(command_b)
        eventually(lambda: ready_a.exists() or ready_b.exists())
        winner, loser, ready, go = (a, b, ready_a, go_a) if ready_a.exists() else (b, a, ready_b, go_b)
        self.wait_ready(ready)
        _, error = loser.communicate(timeout=10)
        self.assertEqual(loser.returncode, 75, error)
        self.assertEqual(json.loads(error)["error"], "heavy_check_timeout")
        self.assertIsNone(winner.poll())
        self.assertNotEqual(ready_a.exists(), ready_b.exists())
        go.touch()
        self.assertEqual(winner.communicate(timeout=10), ("", ""))
        self.assertEqual(winner.returncode, 0)

    def test_normal_completion_and_failure_release_immediately(self):
        for code in (0, 7):
            result = self.launch([sys.executable, "-c", f"raise SystemExit({code})"])
            self.assertEqual(result.communicate(timeout=10), ("", ""))
            self.assertEqual(result.returncode, code)
            lease = self.pool.acquire(0)
            lease.close()
        self.assertEqual(json.loads(self.metadata().read_text())["state"], "released")

    def test_timeout_reports_owner_group_capacity_and_age_without_eviction(self):
        command, ready, go = self.blocked_command("timeout")
        holder = self.launch(command)
        child = self.wait_ready(ready)
        result = self.launch([sys.executable, "-c", "raise SystemExit(99)"], timeout="0")
        _, error = result.communicate(timeout=10)
        self.assertEqual(result.returncode, 75)
        diagnostic = json.loads(error)
        self.assertEqual(diagnostic["capacity"], 1)
        self.assertEqual(diagnostic["timeout_s"], 0)
        self.assertEqual(diagnostic["holders"][0]["owner"]["pid"], holder.pid)
        self.assertEqual(diagnostic["holders"][0]["pgid"], child)
        self.assertIn("age_s", diagnostic["holders"][0])
        self.assertIsNone(holder.poll())
        go.touch()
        holder.communicate(timeout=10)

    def test_crashed_runner_never_frees_slot_while_fd_closing_build_lives(self):
        command, ready, _ = self.blocked_command("crash", close_fd=True)
        holder = self.launch(command)
        child = self.wait_ready(ready)
        holder.kill()
        holder.wait(timeout=10)
        # Child closed its inherited fd; kernel flock is now free, but pgid fences reuse.
        self.assertEqual(self.pool.cleanup(), [])
        self.assertEqual(json.loads(self.metadata().read_text())["state"], "active")
        with self.assertRaises(resources.LeaseTimeout) as raised:
            self.pool.acquire(0)
        self.assertIn("live_or_unknown_command_group", raised.exception.details["holders"][0]["blocked_by"])
        os.killpg(child, signal.SIGKILL)
        eventually(lambda: not resources._group_live(child))
        self.assertEqual(self.pool.cleanup(), ["slot-0000"])
        lease = self.pool.acquire(0)
        lease.close()

    def test_dead_holder_is_reclaimed_on_next_admission(self):
        command, ready, _ = self.blocked_command("dead")
        holder = self.launch(command)
        child = self.wait_ready(ready)
        holder.kill()
        holder.wait(timeout=10)
        os.killpg(child, signal.SIGKILL)
        eventually(lambda: not resources._group_live(child))
        lease = self.pool.acquire(0)
        self.assertEqual(lease.data["reclaimed_previous_owner"]["pid"], holder.pid)
        lease.close()

    def test_stale_age_and_epoch_do_not_evict_live_owner_with_free_kernel_lock(self):
        lease = self.pool.acquire(0)
        data = {**lease.data, "acquired_at": 1, "epoch": "ancient"}
        resources._save(lease.path.with_suffix(".json"), data)
        lease.handle.close()  # Simulate an accidental fd close while owner is still alive.
        with self.assertRaises(resources.LeaseTimeout) as raised:
            self.pool.acquire(0)
        self.assertTrue(raised.exception.details["holders"][0]["stale"])
        self.assertEqual(self.pool.cleanup(), [])
        resources._save(lease.path.with_suffix(".json"), {**data, "state": "released"})

    def test_unknown_liveness_is_not_proof_of_death(self):
        lease = self.pool.acquire(0)
        lease.handle.close()
        with patch.object(resources, "_identity", return_value={"pid": os.getpid(), "unknown": True}):
            with self.assertRaises(resources.LeaseTimeout):
                self.pool.acquire(0)
            self.assertEqual(self.pool.cleanup(), [])
        resources._save(lease.path.with_suffix(".json"), {**lease.data, "state": "released"})

    def test_pid_reuse_is_proven_by_start_identity(self):
        lease = self.pool.acquire(0)
        lease.handle.close()
        with patch.object(resources, "_identity", return_value={"pid": os.getpid(), "started": "different start"}):
            self.assertEqual(self.pool.cleanup(), ["slot-0000"])

    def test_capacity_and_reduction_count_existing_live_slots(self):
        bigger = resources.HeavyChecks(self.home.state_dir, 2)
        first, second = bigger.acquire(0), bigger.acquire(0)
        with self.assertRaises(resources.LeaseTimeout):
            self.pool.acquire(0)
        first.close()
        # Slot 1 still holds the reduced capacity; free slot 0 must not be reused.
        with self.assertRaises(resources.LeaseTimeout):
            self.pool.acquire(0)
        second.close()
        lease = self.pool.acquire(0)
        lease.close()

    def test_corrupt_metadata_fails_closed(self):
        path = self.pool.directory / "slot-0000.json"
        path.write_text("not json")
        with self.assertRaises(resources.LeaseTimeout) as raised:
            self.pool.acquire(0)
        self.assertEqual(raised.exception.details["holders"][0]["blocked_by"], ["unknown_metadata"])
        self.assertEqual(self.pool.cleanup(), [])

    def test_admission_mutex_has_explicit_timeout(self):
        import fcntl
        with open(self.pool.directory / "admission.lock", "a+") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            with self.assertRaises(resources.LeaseTimeout) as raised:
                self.pool.acquire(0)
            self.assertIn("admission mutex", str(raised.exception))

    def test_invalid_policy_and_timeouts(self):
        for slots in (0, -1, True, "1", None):
            with self.subTest(slots=slots), self.assertRaises(Invalid):
                resources.capacity({"heavy_beam_slots": slots})
        for timeout in (-1, "bad", "nan", "inf"):
            with self.subTest(timeout=timeout), self.assertRaises(Invalid):
                self.pool.acquire(timeout)

    def test_runner_outside_factory_is_transparent(self):
        env = {key: value for key, value in self.home.env.items() if not key.startswith("FACTORY_")}
        process = self.launch([sys.executable, "-c", "print('outside'); raise SystemExit(9)"], env=env)
        self.assertEqual(process.communicate(timeout=10), ("outside\n", ""))
        self.assertEqual(process.returncode, 9)
        self.assertEqual(list(self.pool.directory.glob("slot-*")), [])

    def test_real_script_route_validates_inherited_lease_and_preserves_exit(self):
        stub = self.home.root / "bin"
        stub.mkdir()
        mix = stub / "mix"
        mix.write_text('#!/bin/sh\nprintf "mix:%s:%s\\n" "$1" "$2"\nexit 7\n')
        mix.chmod(0o755)
        env = {**self.home.env, "PATH": f"{stub}:{self.home.env['PATH']}"}
        process = subprocess.run([str(SCRIPT), "path", "x"], env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual((process.returncode, process.stdout, process.stderr), (7, "mix:test:x\n", ""))
        self.assertEqual(json.loads(self.metadata().read_text())["state"], "released")

    def test_command_completion_does_not_release_surviving_background_build(self):
        child, ready, go = self.blocked_command("background")
        code = (
            "import pathlib, subprocess, time; "
            f"subprocess.Popen({child!r}, close_fds=True); "
            f"ready=pathlib.Path({str(ready)!r}); "
            "\nwhile not ready.exists(): time.sleep(0.01)\n"
        )
        process = self.launch([sys.executable, "-c", code])
        process.wait(timeout=10)
        self.assertEqual(process.returncode, 0)
        data = json.loads(self.metadata().read_text())
        self.groups.add(data["pgid"])
        self.assertEqual(data["state"], "active")
        with self.assertRaises(resources.LeaseTimeout):
            self.pool.acquire(0)
        self.assertEqual(self.pool.cleanup(), [])
        go.touch()
        eventually(lambda: not resources._group_live(data["pgid"]))
        self.assertEqual(self.pool.cleanup(), ["slot-0000"])

    def test_nested_runner_validates_instead_of_deadlocking(self):
        inner = [sys.executable, str(RUNNER), "run", "--timeout", "0", "--", sys.executable, "-c", "print('nested')"]
        process = self.launch(inner)
        self.assertEqual(process.communicate(timeout=10), ("nested\n", ""))
        self.assertEqual(process.returncode, 0)
        self.assertEqual(len(list(self.pool.directory.glob("slot-*.lock"))), 1)

    def test_forged_lease_markers_fail_closed(self):
        env = {**self.home.env, "FACTORY_HEAVY_LEASE_FD": "9999", "FACTORY_HEAVY_LEASE_TOKEN": "fake"}
        process = self.launch([sys.executable, "-c", "print('must not run')"], env=env)
        out, error = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 2)
        self.assertEqual(out, "")
        self.assertIn("invalid inherited", json.loads(error)["message"])

    def test_supervisor_sets_installed_runner_and_protected_context(self):
        with patch.dict(os.environ, self.home.env, clear=True):
            project = projects.resolve(project_id="widget")
            instance = supervisor.Supervisor(project)
            instance.policy = {"omp": {"env": {"FACTORY_PROJECT": "wrong", "FACTORY_HEAVY_RUNNER": "wrong"}}}
            context = instance._omp_env()
        self.assertEqual(context["FACTORY_PROJECT"], "widget")
        self.assertEqual(Path(context["FACTORY_HEAVY_RUNNER"]), RUNNER)
        self.assertEqual(context["FACTORY_STATE_HOME"], self.home.env["FACTORY_STATE_HOME"])
        self.assertEqual(context["FACTORY_PYTHON"], sys.executable)

    @unittest.skipUnless(omp_available(), "installed omp and its omp_rpc client are required")
    def test_native_isolated_worker_inherits_factory_gate(self):
        import shlex
        import omp_adapter

        fixture = FixtureEnv()
        self.addCleanup(fixture.cleanup)
        stub = self.home.root / "worker-bin"
        stub.mkdir()
        mix = stub / "mix"
        mix.write_text("#!/bin/sh\nprintf 'native-heavy-gate\\n'\n")
        mix.chmod(0o755)
        env = {**self.home.env, **fixture.env, "PATH": f"{stub}:{self.home.env['PATH']}"}
        rpc = omp_adapter.load_rpc_module()
        client = rpc.RpcClient(cwd=fixture.repo, env=env, session_dir=fixture.sessions,
                               extra_args=fixture.omp_args, startup_timeout=60, request_timeout=30)
        client.start()
        owner = client._process.pid
        try:
            child = [
                {"tool": "bash", "args": {"command": f"{shlex.quote(str(SCRIPT))} path x"}},
                {"tool": "yield", "args": {"data": {"result": "checked"}}},
            ]
            spawn = {"tool": "task", "args": {"context": "factory heavy gate fixture", "tasks": [{
                "name": "HeavyGate", "task": script(*child), "isolated": True, "schemaMode": "strict",
                "outputSchema": {"type": "object", "properties": {"result": {"type": "string"}},
                                 "required": ["result"], "additionalProperties": False},
            }]}}
            client.prompt(script(spawn, {"text": "spawned"}))
            wait_settled(client)
            results = [r["lastText"] for r in fixture.requests()
                       if r["model"] == "fixture-worker" and r["lastRole"] == "toolResult"]
            self.assertTrue(any("native-heavy-gate" in result for result in results), results)
            self.assertEqual(json.loads(self.metadata().read_text())["state"], "released")
        finally:
            client.stop()
            supervisor.reap_isolation_workspaces(owner)


if __name__ == "__main__":
    unittest.main()
