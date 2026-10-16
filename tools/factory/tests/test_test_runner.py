"""scripts/test heavy-lane routing through the shared factory heavy runner.

Nothing here runs a real umbrella lane: `mix`, `bun` and `npm` are stubs that
only record their argv, and the heavy runner is a stub that records its argv
(and, for one test, re-executes the script with FACTORY_PROJECT stripped).
"""

from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import unittest
from pathlib import Path

from .helpers import FactoryHome

REPO = Path(__file__).resolve().parents[3]
SCRIPT = REPO / "scripts" / "test"
HEAVY_LANES = ("fast", "coverage", "changed", "premerge", "quality", "eval-fast", "live-eval", "path", "all")
CHEAP_LANES = ("help", "clients", "smoke")
SCRUBBED_PREFIXES = ("FACTORY_",)
SCRUBBED_KEYS = ("MIX_ENV", "LEMON_TEST_TMPDIR", "LEMON_STORE_PATH", "LEMON_TEST_ALLOW_LIVE_CREDENTIALS",
                 "LEMON_TEST_REUSE_NODE_MODULES")

MIX_STUB = """#!/bin/sh
{ printf '%s' "$(basename "$0")"; for a in "$@"; do printf ' [%s]' "$a"; done; printf ' MIX_ENV=%s\\n' "${MIX_ENV-}"; } >> "$STUB_LOG"
exit "${STUB_MIX_EXIT:-0}"
"""

# Records its argv. `validate` exits with STUB_VALIDATE_EXIT (default 0). With
# STUB_RUNNER_EXEC=1 `run` plays the real runner's re-exec (minus the lease) by
# stripping FACTORY_PROJECT and running the wrapped command.
RUNNER_STUB = """import json, os, sys
with open(os.environ["STUB_RUNNER_LOG"], "a") as log:
    log.write(json.dumps(sys.argv) + "\\n")
if sys.argv[1] == "validate":
    sys.exit(int(os.environ.get("STUB_VALIDATE_EXIT", "0")))
if os.environ.get("STUB_RUNNER_EXEC") == "1":
    cmd = sys.argv[sys.argv.index("--") + 1:]
    os.environ.pop("FACTORY_PROJECT")
    os.execv(cmd[0], cmd)
"""

PYTHON3_STUB = """#!/bin/sh
printf 'python3 %s\\n' "$*" >> "$STUB_PYTHON_LOG"
exec "$REAL_PYTHON" "$@"
"""


def _executable(path: Path, text: str) -> Path:
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return path


class TestRunnerRoutingTest(unittest.TestCase):
    def setUp(self) -> None:
        self.home = FactoryHome()
        self.addCleanup(self.home.cleanup)
        root = self.home.root
        self.bin = root / "bin"
        self.bin.mkdir()
        self.tmp = root / "tmp"
        self.tmp.mkdir()
        self.mix_log = root / "mix.log"
        self.runner_log = root / "runner.log"
        for name in ("mix", "bun", "npm"):
            _executable(self.bin / name, MIX_STUB)
        self.runner = _executable(root / "resources.py", RUNNER_STUB)
        # FactoryHome pre-populates FACTORY_* homes; tests opt back in explicitly.
        self.base_env = {
            k: v for k, v in self.home.env.items()
            if not k.startswith(SCRUBBED_PREFIXES) and k not in SCRUBBED_KEYS
        }
        self.base_env.update({
            "PATH": f"{self.bin}{os.pathsep}{self.base_env['PATH']}",
            "TMPDIR": str(self.tmp),
            "STUB_LOG": str(self.mix_log),
            "STUB_RUNNER_LOG": str(self.runner_log),
        })

    def factory_env(self, **extra: str) -> dict[str, str]:
        return {
            **self.base_env,
            "FACTORY_PROJECT": "widget",
            "FACTORY_STATE_HOME": self.home.env["FACTORY_STATE_HOME"],
            "FACTORY_CONFIG_HOME": self.home.env["FACTORY_CONFIG_HOME"],
            "FACTORY_DATA_HOME": self.home.env["FACTORY_DATA_HOME"],
            "FACTORY_PYTHON": sys.executable,
            "FACTORY_HEAVY_RUNNER": str(self.runner),
            **extra,
        }

    def run_script(self, script: Path, env: dict[str, str], *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run([str(script), *args], cwd=REPO, env=env, capture_output=True, text=True, timeout=120)

    def read_log(self, path: Path) -> list[str]:
        return path.read_text().splitlines() if path.exists() else []

    # --- outside the factory -------------------------------------------------

    def baseline_script(self) -> Path:
        shown = subprocess.run(["git", "show", "HEAD:scripts/test"], cwd=REPO, capture_output=True, text=True)
        if shown.returncode != 0:
            self.skipTest(f"no HEAD:scripts/test baseline: {shown.stderr.strip()}")
        root = self.home.root / "baseline"
        (root / "scripts").mkdir(parents=True)
        return _executable(root / "scripts" / "test", shown.stdout)

    def test_outside_factory_matches_head_baseline(self) -> None:
        baseline = self.baseline_script()
        cases = [
            ("help",),
            ("--help",),
            ("path", "apps/foo/test", "--seed", "1"),
            ("path",),  # usage error, exit 64
            ("no-such-lane",),  # unknown lane, exit 64
        ]
        for args in cases:
            for mix_exit in ("0", "3"):
                with self.subTest(args=args, mix_exit=mix_exit):
                    env = {**self.base_env, "STUB_MIX_EXIT": mix_exit}
                    self.mix_log.write_text("")
                    old = self.run_script(baseline, env, *args)
                    old_log = self.read_log(self.mix_log)
                    self.mix_log.write_text("")
                    new = self.run_script(SCRIPT, env, *args)
                    new_log = self.read_log(self.mix_log)
                    self.assertEqual((old.returncode, old.stdout, old.stderr), (new.returncode, new.stdout, new.stderr))
                    self.assertEqual(old_log, new_log)
        # Sanity: the comparison really covered a nonzero mix exit and the usage errors.
        env = {**self.base_env, "STUB_MIX_EXIT": "3"}
        self.assertEqual(self.run_script(SCRIPT, env, "path", "x").returncode, 3)
        self.assertEqual(self.run_script(SCRIPT, env, "path").returncode, 64)

    def test_outside_factory_never_touches_runner(self) -> None:
        env = {**self.base_env, "FACTORY_HEAVY_RUNNER": str(self.runner)}  # runner alone is inert
        result = self.run_script(SCRIPT, env, "path", "apps/foo/test")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read_log(self.runner_log), [])
        self.assertEqual(self.read_log(self.mix_log), ["mix [test] [apps/foo/test] MIX_ENV=test"])

    # --- under the factory ---------------------------------------------------

    def test_heavy_lanes_route_through_runner_with_same_lane_and_args(self) -> None:
        for lane in HEAVY_LANES:
            with self.subTest(lane=lane):
                self.runner_log.write_text("")
                self.mix_log.write_text("")
                result = self.run_script(SCRIPT, self.factory_env(), lane, "--base", "origin/x", "a b")
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = [json.loads(line) for line in self.read_log(self.runner_log)]
                self.assertEqual(calls, [[str(self.runner), "run", "--", str(REPO / "scripts" / "test"),
                                          lane, "--base", "origin/x", "a b"]])
                self.assertEqual(self.read_log(self.mix_log), [], "heavy lane must not run before the runner re-execs")

    def test_routed_lane_without_args(self) -> None:
        result = self.run_script(SCRIPT, self.factory_env(), "fast")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in self.read_log(self.runner_log)]
        self.assertEqual(calls, [[str(self.runner), "run", "--", str(REPO / "scripts" / "test"), "fast"]])

    def test_runner_reexec_runs_the_lane(self) -> None:
        result = self.run_script(SCRIPT, self.factory_env(STUB_RUNNER_EXEC="1"), "path", "apps/foo/test", "--seed", "1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.read_log(self.runner_log)), 1)
        self.assertEqual(self.read_log(self.mix_log), ["mix [test] [apps/foo/test] [--seed] [1] MIX_ENV=test"])

    def test_runner_reexec_propagates_nonzero_exit(self) -> None:
        result = self.run_script(SCRIPT, self.factory_env(STUB_RUNNER_EXEC="1", STUB_MIX_EXIT="3"), "path", "x")
        self.assertEqual(result.returncode, 3)

    def test_validated_inherited_lease_runs_lane_without_rerouting(self) -> None:
        env = self.factory_env(FACTORY_HEAVY_LEASE_FD="9", FACTORY_HEAVY_LEASE_TOKEN="tok")
        result = self.run_script(SCRIPT, env, "path", "apps/foo/test")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read_log(self.runner_log), [json.dumps([str(self.runner), "validate"])])
        self.assertEqual(self.read_log(self.mix_log), ["mix [test] [apps/foo/test] MIX_ENV=test"])

    def test_invalid_inherited_lease_fails_closed(self) -> None:
        env = self.factory_env(FACTORY_HEAVY_LEASE_FD="9", FACTORY_HEAVY_LEASE_TOKEN="tok", STUB_VALIDATE_EXIT="1")
        for lane in HEAVY_LANES:
            with self.subTest(lane=lane):
                self.runner_log.write_text("")
                self.mix_log.write_text("")
                result = self.run_script(SCRIPT, env, lane, "x")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("validation", result.stderr)
                self.assertEqual(self.read_log(self.runner_log), [json.dumps([str(self.runner), "validate"])])
                self.assertEqual(self.read_log(self.mix_log), [])

    def test_partial_lease_env_is_not_a_bypass(self) -> None:
        for partial in ({"FACTORY_HEAVY_LEASE_FD": "9"}, {"FACTORY_HEAVY_LEASE_TOKEN": "tok"}):
            with self.subTest(partial=partial):
                self.runner_log.write_text("")
                self.mix_log.write_text("")
                result = self.run_script(SCRIPT, self.factory_env(**partial), "path", "x")
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = [json.loads(line) for line in self.read_log(self.runner_log)]
                self.assertEqual(calls, [[str(self.runner), "run", "--", str(SCRIPT), "path", "x"]])
                self.assertEqual(self.read_log(self.mix_log), [])

    def test_default_factory_python_is_python3(self) -> None:
        python_log = self.home.root / "python.log"
        _executable(self.bin / "python3", PYTHON3_STUB)
        env = self.factory_env(REAL_PYTHON=sys.executable, STUB_PYTHON_LOG=str(python_log))
        del env["FACTORY_PYTHON"]
        result = self.run_script(SCRIPT, env, "path", "x")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read_log(python_log), [f"python3 {self.runner} run -- {SCRIPT} path x"])

    def test_missing_runner_fails_closed(self) -> None:
        missing = str(self.home.root / "nope" / "resources.py")
        for lane in HEAVY_LANES:
            for label, overrides in (("unset", None), ("empty", ""), ("nonexistent", missing)):
                with self.subTest(lane=lane, runner=label):
                    env = self.factory_env()
                    if overrides is None:
                        del env["FACTORY_HEAVY_RUNNER"]
                    else:
                        env["FACTORY_HEAVY_RUNNER"] = overrides
                    self.mix_log.write_text("")
                    result = self.run_script(SCRIPT, env, lane, "x")
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("FACTORY_HEAVY_RUNNER", result.stderr)
                    self.assertIn(lane, result.stderr)
                    self.assertEqual(self.read_log(self.mix_log), [])
                    self.assertEqual(self.read_log(self.runner_log), [])

    def test_cheap_lanes_do_not_route_or_need_the_runner(self) -> None:
        for lane in CHEAP_LANES:
            for runner in (str(self.runner), str(self.home.root / "nope" / "resources.py")):
                with self.subTest(lane=lane, runner=runner):
                    self.runner_log.write_text("")
                    baseline = self.run_script(SCRIPT, self.base_env, lane)
                    result = self.run_script(SCRIPT, self.factory_env(FACTORY_HEAVY_RUNNER=runner), lane)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual((baseline.stdout, baseline.stderr), (result.stdout, result.stderr))
                    self.assertEqual(self.read_log(self.runner_log), [])

    def test_invalid_lane_unchanged_under_factory(self) -> None:
        baseline = self.run_script(SCRIPT, self.base_env, "bogus")
        for env in (self.factory_env(), self.factory_env(FACTORY_HEAVY_RUNNER="")):
            result = self.run_script(SCRIPT, env, "bogus")
            self.assertEqual(result.returncode, 64)
            self.assertEqual((baseline.returncode, baseline.stdout, baseline.stderr),
                             (result.returncode, result.stdout, result.stderr))
        self.assertEqual(self.read_log(self.runner_log), [])


if __name__ == "__main__":
    unittest.main()
