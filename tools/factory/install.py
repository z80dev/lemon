"""Install a reviewed, committed factory version and expose it to OMP consoles.

A release is `git archive` of one commit (never a dirty tree), unpacked under
`<data>/releases/<sha>` with `current` pointing at it. Consoles load the
extension through `omp plugin link`, which changes OMP's plugin registry only:
no settings, model roles, or aliases are touched. A running supervisor keeps
the release it started from until an explicit restart.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path
from typing import Any

import omp_adapter
import project as projects
from store import FactoryError

PAYLOAD = (".factory", "tools/factory", "integrations/omp-factory")


class InstallError(FactoryError):
    code = "install_failed"
    exit_code = 6


def _git(cwd: Path, *args: str) -> str:
    result = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, timeout=120)
    if result.returncode != 0:
        raise InstallError(f"git {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout.strip()


def install(cwd: Path, ref: str) -> dict[str, Any]:
    root = Path(_git(cwd, "rev-parse", "--show-toplevel"))
    sha = _git(root, "rev-parse", "--verify", f"{ref}^{{commit}}")
    releases = projects.data_home() / "releases"
    release = releases / sha
    if not release.exists():
        releases.mkdir(parents=True, exist_ok=True, mode=0o700)
        staging = Path(tempfile.mkdtemp(prefix=f".{sha[:12]}-", dir=releases))
        archive = subprocess.run(["git", "archive", "--format=tar", sha, *PAYLOAD], cwd=root, capture_output=True,
                                 timeout=120)
        if archive.returncode != 0:
            shutil.rmtree(staging)
            raise InstallError(f"git archive failed: {archive.stderr.decode().strip()}")
        archive_path = staging / "payload.tar"
        archive_path.write_bytes(archive.stdout)
        with tarfile.open(archive_path) as tar:
            tar.extractall(staging, filter="data")
        archive_path.unlink()
        (staging / "VERSION").write_text(sha + "\n")
        os.replace(staging, release)
    current = projects.data_home() / "current"
    link = current.with_name(".current.tmp")
    link.unlink(missing_ok=True)
    link.symlink_to(release)
    os.replace(link, current)
    plugin = current / "integrations" / "omp-factory"
    linked = subprocess.run([omp_adapter.omp_executable(), "plugin", "link", str(plugin)], capture_output=True,
                            text=True, timeout=120)
    if linked.returncode != 0:
        raise InstallError(f"omp plugin link failed: {linked.stderr.strip() or linked.stdout.strip()}")
    return {
        "ok": True,
        "release": str(release),
        "version": sha,
        "current": str(current),
        "plugin": str(plugin),
        "plugin_link": linked.stdout.strip()[-500:],
        "note": "Running supervisors keep their release until `factory stop` + `factory start`.",
    }
