"""Install a reviewed, committed factory version and expose it to OMP consoles.

A release is `git archive` of one commit (never a dirty tree), unpacked under
`<data>/releases/<sha>` with `current` pointing at it. Consoles load the
extension through `omp plugin link`, which changes OMP's plugin registry only:
no settings, model roles, or aliases are touched. A running supervisor keeps
the release it started from until an explicit restart.
"""

from __future__ import annotations

import os
import plistlib
import shutil
import subprocess
import sys
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


def _launch_agent(project: projects.Project) -> tuple[str, Path]:
    label = f"dev.lemon.factory.{project.id}"
    return label, Path.home() / "Library" / "LaunchAgents" / f"{label}.plist"


def autostart(project: projects.Project, *, enable: bool, interval_s: int = 300) -> dict[str, Any]:
    """Opt-in launchd watchdog that runs `factory ensure` at login and every interval.

    `ensure` respects an operator stop, so this keeps the factory running continuously
    without overriding explicit control. Runs the installed `current` release.
    """
    label, plist_path = _launch_agent(project)
    domain = f"gui/{os.getuid()}"
    subprocess.run(["launchctl", "bootout", f"{domain}/{label}"], capture_output=True, timeout=60)
    if not enable:
        plist_path.unlink(missing_ok=True)
        return {"ok": True, "autostart": False, "label": label}
    cli = projects.data_home() / "current" / "tools" / "factory" / "cli.py"
    if not cli.exists():
        raise InstallError("no installed release; run `factory install` first")
    env = {key: os.environ[key] for key in ("PATH", "HOME", "FACTORY_CONFIG_HOME", "FACTORY_STATE_HOME",
                                           "FACTORY_DATA_HOME") if key in os.environ}
    project.logs_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    agent = {
        "Label": label,
        "ProgramArguments": [sys.executable, str(cli), "--project", project.id, "ensure"],
        "StartInterval": interval_s,
        "RunAtLoad": True,
        # The supervisor detaches into its own session; launchd must not reap it with the watchdog.
        "AbandonProcessGroup": True,
        "EnvironmentVariables": env,
        "WorkingDirectory": str(project.primary_checkout),
        "StandardOutPath": str(project.logs_dir / "autostart.log"),
        "StandardErrorPath": str(project.logs_dir / "autostart.log"),
    }
    plist_path.parent.mkdir(parents=True, exist_ok=True)
    with open(plist_path, "wb") as handle:
        plistlib.dump(agent, handle)
    loaded = subprocess.run(["launchctl", "bootstrap", domain, str(plist_path)], capture_output=True, text=True,
                            timeout=60)
    if loaded.returncode != 0:
        raise InstallError(f"launchctl bootstrap failed: {loaded.stderr.strip()}")
    return {"ok": True, "autostart": True, "label": label, "plist": str(plist_path), "interval_s": interval_s}
