"""Isolated factory homes and independent CLI processes for lifecycle tests."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

FACTORY_DIR = Path(__file__).resolve().parents[1]
CLI = FACTORY_DIR / "cli.py"
REPOSITORY = "github.com/example/widget"


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


class FactoryHome:
    """Temp config/state/data homes plus a registered git checkout with an `origin` remote."""

    def __init__(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="factory-home-"))
        self.env = {
            **{key: value for key, value in os.environ.items() if not key.startswith("FACTORY_")},
            "FACTORY_CONFIG_HOME": str(self.root / "config"),
            "FACTORY_STATE_HOME": str(self.root / "state"),
            "FACTORY_DATA_HOME": str(self.root / "data"),
            "FACTORY_ACTOR": "test",
        }
        self.origin = self.root / "origin.git"
        git(self.root, "init", "-q", "--bare", "-b", "main", str(self.origin))
        self.repo = self.root / "repo"
        self.repo.mkdir()
        git(self.repo, "init", "-q", "-b", "main")
        git(self.repo, "config", "user.name", "Factory Test")
        git(self.repo, "config", "user.email", "factory@example.invalid")
        (self.repo / ".factory").mkdir()
        (self.repo / ".factory" / "project.json").write_text(
            json.dumps({"id": "widget", "repository": REPOSITORY, "remote": "origin", "base_ref": "origin/main"})
        )
        (self.repo / "README.md").write_text("widget\n")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-q", "-m", "init")
        # The remote URL identity must match .factory/project.json; push to a local bare repo via pushurl.
        git(self.repo, "remote", "add", "origin", f"git@github.com:{REPOSITORY.split('/', 1)[1]}.git")
        git(self.repo, "config", "remote.origin.pushurl", str(self.origin))
        git(self.repo, "push", "-q", str(self.origin), "main")
        git(self.repo, "update-ref", "refs/remotes/origin/main", "HEAD")

    @property
    def state_dir(self) -> Path:
        return self.root / "state" / "widget"

    def cli(self, *args: str, cwd: Path | None = None, check: bool = True) -> tuple[int, dict[str, Any]]:
        result = subprocess.run([sys.executable, str(CLI), *args], cwd=cwd or self.repo, env=self.env,
                                capture_output=True, text=True, timeout=180)
        try:
            payload = json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            raise AssertionError(f"non-JSON output ({result.returncode}): {result.stdout}\n{result.stderr}") from exc
        if check and result.returncode != 0:
            raise AssertionError(f"factory {' '.join(args)} failed: {payload}\n{result.stderr}")
        return result.returncode, payload

    def cli_parallel(self, argvs: list[list[str]]) -> list[tuple[int, dict[str, Any]]]:
        """Independent OS processes released together through a filesystem barrier."""
        go = self.root / f"go-{time.monotonic_ns()}"
        launcher = (
            "import os, sys, time\n"
            f"while not os.path.exists({str(go)!r}): time.sleep(0.001)\n"
            f"sys.path.insert(0, {str(FACTORY_DIR)!r})\n"
            "import cli\n"
            "sys.exit(cli.main(sys.argv[1:]))\n"
        )
        procs = [
            subprocess.Popen([sys.executable, "-c", launcher, *argv], cwd=self.repo, env=self.env,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            for argv in argvs
        ]
        time.sleep(0.5)  # let every interpreter reach the barrier
        go.touch()
        results = []
        for proc in procs:
            out, err = proc.communicate(timeout=120)
            try:
                results.append((proc.returncode, json.loads(out)))
            except json.JSONDecodeError as exc:
                raise AssertionError(f"non-JSON output: {out}\n{err}") from exc
        return results

    def cleanup(self) -> None:
        shutil.rmtree(self.root, ignore_errors=True)
