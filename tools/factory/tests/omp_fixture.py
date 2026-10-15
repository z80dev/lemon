"""Deterministic OMP harness: a real `omp --mode rpc` process with a scripted model.

The scripted provider (omp_adapter/fixture_provider.ts) makes no network calls.
A private agent directory isolates auth, sessions and settings from the user's
profile while still exercising the installed OMP binary.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any

import omp_adapter

FACTORY_OVERLAY = Path(__file__).resolve().parents[1] / "omp-overlay.yml"

AGENT_CONFIG = """\
modelRoles:
  default: factory-fixture/fixture-main
  task: factory-fixture/fixture-main
task:
  agentModelOverrides:
    task: factory-fixture/fixture-worker
setupVersion: 2
"""


def script(*steps: dict[str, Any]) -> str:
    return "FIXTURE<<" + json.dumps({"steps": list(steps)}) + ">>FIXTURE"


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout


def pids_matching(pattern: str) -> list[str]:
    return subprocess.run(["pgrep", "-f", pattern], capture_output=True, text=True).stdout.split()


class FixtureEnv:
    """Temp agent dir + git repo + request log for one test class."""

    def __init__(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="factory-fx-"))
        self.agent_dir = self.root / "agent"
        self.agent_dir.mkdir()
        (self.agent_dir / "config.yml").write_text(AGENT_CONFIG)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        git(self.repo, "init", "-q", "-b", "main")
        git(self.repo, "config", "user.name", "Factory Fixture")
        git(self.repo, "config", "user.email", "fixture@example.invalid")
        (self.repo / "tracked.txt").write_text("committed\n")
        git(self.repo, "add", "tracked.txt")
        git(self.repo, "commit", "-q", "-m", "init")
        self.sessions = self.root / "sessions"
        self.log = self.root / "requests.jsonl"
        self.log.touch()

    @property
    def env(self) -> dict[str, str]:
        return {
            "PI_CODING_AGENT_DIR": str(self.agent_dir),
            "FACTORY_FIXTURE_LOG": str(self.log),
        }

    @property
    def omp_args(self) -> list[str]:
        return ["--no-ui", "--no-extensions", "--config", str(FACTORY_OVERLAY), "-e", str(omp_adapter.FIXTURE_PROVIDER)]

    def requests(self) -> list[dict[str, Any]]:
        return [json.loads(line) for line in self.log.read_text().splitlines() if line.strip()]

    def client(self, extra: list[str] | None = None) -> Any:
        rpc = omp_adapter.load_rpc_module()
        client = rpc.RpcClient(
            cwd=self.repo,
            env=self.env,
            session_dir=self.sessions,
            extra_args=[*self.omp_args, *(extra or [])],
            startup_timeout=60,
            request_timeout=30,
        )
        return client.start()

    def cleanup(self) -> None:
        shutil.rmtree(self.root, ignore_errors=True)


def raw_state(client: Any) -> dict[str, Any]:
    state = client.request_raw("get_state")
    return {k: v for k, v in state.items() if k not in ("systemPrompt", "dumpTools")}


def wait_settled(client: Any, timeout: float = 60.0) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        state = raw_state(client)
        if state.get("isSettled"):
            return state
        time.sleep(0.2)
    raise AssertionError(f"session did not settle within {timeout}s: {raw_state(client)}")


def wait_for(predicate: Any, timeout: float = 20.0, interval: float = 0.2) -> Any:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(interval)
    raise AssertionError("condition not met before timeout")


def omp_available() -> bool:
    try:
        omp_adapter.omp_executable()
        omp_adapter.load_rpc_module()
        return True
    except (omp_adapter.OmpUnavailable, ImportError):
        return False
