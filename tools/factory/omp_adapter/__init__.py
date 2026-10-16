"""Locate the installed OMP binary and the official Python RPC client beside it.

The factory never scrapes transcripts or touches OMP's databases. It talks to
OMP only through the documented JSONL RPC protocol via `omp_rpc` from the OMP
source tree the `omp` launcher lives in. That binary can be updated in place
independently of the tree, so the compatibility stamp binds the binary digest
and the client revision together (see `compat.py`).
"""

from __future__ import annotations

import hashlib
import importlib
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from types import ModuleType

FIXTURE_PROVIDER = Path(__file__).with_name("fixture_provider.ts")


class OmpUnavailable(RuntimeError):
    """A precise prerequisite failure; never degrade silently."""


@dataclass(frozen=True)
class OmpIdentity:
    """What a compatibility stamp binds to: the exact binary and RPC client used."""

    executable: str
    realpath: str
    version: str
    binary_sha256: str
    rpc_client_path: str | None
    rpc_client_commit: str | None
    rpc_client_dirty: bool | None

    def as_dict(self) -> dict[str, str | bool | None]:
        return dict(self.__dict__)


def _run(args: list[str], cwd: str | None = None) -> str:
    return subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True, timeout=30).stdout.strip()


def omp_executable() -> str:
    exe = os.environ.get("FACTORY_OMP_BIN") or shutil.which("omp")
    if not exe:
        raise OmpUnavailable("omp executable not found on PATH (set FACTORY_OMP_BIN)")
    return exe


def _source_root(realpath: str) -> Path | None:
    for parent in Path(realpath).parents:
        if (parent / "python" / "omp-rpc" / "src" / "omp_rpc").is_dir():
            return parent
    return None


def _rpc_client_dir() -> Path:
    override = os.environ.get("FACTORY_OMP_RPC_PATH")
    if override:
        return Path(override)
    root = _source_root(os.path.realpath(omp_executable()))
    if root is None:
        raise OmpUnavailable("cannot locate the omp_rpc client matching the installed omp; set FACTORY_OMP_RPC_PATH")
    return root / "python" / "omp-rpc" / "src"


def _sha256(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def identify() -> OmpIdentity:
    exe = omp_executable()
    real = os.path.realpath(exe)
    version = _run([exe, "--version"]).split()[-1].removeprefix("omp/")
    client = _rpc_client_dir()
    commit: str | None = None
    dirty: bool | None = None
    try:
        commit = _run(["git", "log", "-1", "--format=%H", "--", "."], cwd=str(client)) or None
        dirty = bool(_run(["git", "status", "--porcelain", "--", "."], cwd=str(client)))
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass
    return OmpIdentity(exe, real, version, _sha256(real), str(client), commit, dirty)


def load_rpc_module() -> ModuleType:
    """Import `omp_rpc` from FACTORY_OMP_RPC_PATH or the binary's own source tree."""
    path = _rpc_client_dir()
    if str(path) not in sys.path:
        sys.path.insert(0, str(path))
    return importlib.import_module("omp_rpc")
