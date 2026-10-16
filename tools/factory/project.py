"""Project identity and host-local paths.

The portable identity lives in `.factory/project.json` in the repository; the
machine paths live in the host registry (`projects.json`). Every worktree,
subdirectory, and registered clone resolves to one project ID through Git's
common directory, never through the current working directory or a display name.
"""

from __future__ import annotations

import fcntl
import json
import os
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from store import FactoryError, Invalid, Ledger

PROJECT_ID = re.compile(r"^[a-z][a-z0-9-]{1,40}$")


class NotRegistered(FactoryError):
    code = "not_registered"
    exit_code = 6


def config_home() -> Path:
    return Path(os.environ.get("FACTORY_CONFIG_HOME") or Path.home() / ".config" / "software-factory")


def state_home() -> Path:
    return Path(os.environ.get("FACTORY_STATE_HOME") or Path.home() / ".local" / "state" / "software-factory")


def data_home() -> Path:
    return Path(os.environ.get("FACTORY_DATA_HOME") or Path.home() / ".local" / "share" / "software-factory")


def _git(cwd: Path, *args: str) -> str:
    result = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, timeout=30)
    if result.returncode != 0:
        raise NotRegistered(f"{cwd} is not inside a git checkout")
    return result.stdout.strip()


def canonical_root(cwd: Path) -> Path:
    """The main checkout that owns cwd's git common dir (worktrees map to their main checkout)."""
    common = Path(_git(cwd, "rev-parse", "--path-format=absolute", "--git-common-dir")).resolve()
    if common.name != ".git":
        raise NotRegistered(f"unsupported repository layout at {common}")
    return common.parent


def normalize_remote(url: str) -> str:
    """git@github.com:o/r.git, https://github.com/o/r → github.com/o/r"""
    url = url.strip().removesuffix(".git")
    match = re.match(r"^(?:[\w.-]+@)?([\w.-]+):(?!//)(.+)$", url)
    if match:
        return f"{match.group(1)}/{match.group(2)}".lower()
    match = re.match(r"^\w+://(?:[^@/]+@)?([^/]+)/(.+)$", url)
    if match:
        return f"{match.group(1)}/{match.group(2)}".lower()
    return url.lower()


@dataclass(frozen=True)
class Project:
    id: str
    repository: str
    checkouts: tuple[str, ...]
    base_ref: str
    state_dir: Path

    @property
    def db_path(self) -> Path:
        return self.state_dir / "factory.db"

    @property
    def lock_path(self) -> Path:
        return self.state_dir / "runtime.lock"

    @property
    def runtime_json(self) -> Path:
        return self.state_dir / "runtime.json"

    @property
    def policy_path(self) -> Path:
        return self.state_dir / "policy.json"

    @property
    def checkout_dir(self) -> Path:
        return self.state_dir / "checkout"

    @property
    def sessions_dir(self) -> Path:
        return self.state_dir / "sessions"

    @property
    def logs_dir(self) -> Path:
        return self.state_dir / "logs"

    @property
    def primary_checkout(self) -> Path:
        return Path(self.checkouts[0])

    def ledger(self) -> Ledger:
        return Ledger(self.db_path, self.id)


def _registry_path() -> Path:
    return config_home() / "projects.json"


def load_registry() -> dict[str, Any]:
    path = _registry_path()
    if not path.exists():
        return {"version": 1, "projects": {}}
    return json.loads(path.read_text())


def _to_project(project_id: str, entry: dict[str, Any]) -> Project:
    state_dir = Path(entry.get("state_dir") or state_home() / project_id)
    return Project(project_id, entry["repository"], tuple(entry["checkouts"]), entry.get("base_ref", "origin/main"),
                   state_dir)


def register(cwd: Path) -> Project:
    """Register the checkout containing cwd under the ID in its .factory/project.json."""
    root = canonical_root(cwd)
    toplevel = Path(_git(cwd, "rev-parse", "--show-toplevel"))
    manifest_path = toplevel / ".factory" / "project.json"
    if not manifest_path.exists():
        raise NotRegistered(f"{manifest_path} not found; this repository has no factory identity")
    manifest = json.loads(manifest_path.read_text())
    project_id = manifest["id"]
    if not PROJECT_ID.match(project_id):
        raise Invalid(f"invalid project id {project_id!r}")
    remote = normalize_remote(_git(root, "remote", "get-url", manifest.get("remote", "origin")))
    if remote != manifest["repository"]:
        raise NotRegistered(
            f"checkout remote {remote} does not match project repository {manifest['repository']}", remote=remote
        )
    config_home().mkdir(parents=True, exist_ok=True, mode=0o700)
    with open(config_home() / "projects.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        registry = load_registry()
        entry = registry["projects"].setdefault(
            project_id, {"repository": manifest["repository"], "checkouts": [], "base_ref": manifest.get("base_ref", "origin/main")}
        )
        if entry["repository"] != manifest["repository"]:
            raise NotRegistered(f"project {project_id} is registered for {entry['repository']}")
        if str(root) not in entry["checkouts"]:
            entry["checkouts"].append(str(root))
        tmp = _registry_path().with_suffix(".tmp")
        tmp.write_text(json.dumps(registry, indent=2) + "\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, _registry_path())
    project = _to_project(project_id, entry)
    project.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    return project


def resolve(cwd: Path | None = None, project_id: str | None = None) -> Project:
    """Explicit --project wins; otherwise the cwd's canonical checkout must be registered."""
    registry = load_registry()["projects"]
    if project_id is not None:
        if project_id not in registry:
            raise NotRegistered(f"project {project_id!r} is not registered on this host")
        return _to_project(project_id, registry[project_id])
    root = str(canonical_root(cwd or Path.cwd()))
    for pid, entry in registry.items():
        if root in entry["checkouts"]:
            return _to_project(pid, entry)
    raise NotRegistered(f"{root} is not a registered factory checkout (run `factory register` there)", checkout=root)
