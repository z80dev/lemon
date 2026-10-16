"""OMP compatibility gate.

`factory compat` runs the P00 seam suite against the installed OMP and, only if
every seam passes, stamps that exact binary digest and RPC client revision.
The supervisor refuses to start a coordinator for any other OMP build, so an
OMP update fails closed before autonomous dispatch instead of silently degrading.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import unittest
from pathlib import Path
from typing import Any

import omp_adapter
import project as projects
from store import FactoryError

FACTORY_DIR = Path(__file__).resolve().parent


class Incompatible(FactoryError):
    code = "incompatible_omp"
    exit_code = 6


def stamp_path() -> Path:
    return projects.state_home() / "omp-compat.json"


def check_stamp(identity: omp_adapter.OmpIdentity) -> dict[str, Any]:
    path = stamp_path()
    if not path.exists():
        raise Incompatible("OMP has not passed the factory seam suite on this host; run `factory compat`")
    stamp = json.loads(path.read_text())
    tested = stamp["identity"]
    for field in ("version", "binary_sha256", "rpc_client_commit", "rpc_client_dirty"):
        if tested.get(field) != getattr(identity, field):
            raise Incompatible(
                f"installed OMP differs from the tested build ({field}: {tested.get(field)} -> "
                f"{getattr(identity, field)}); run `factory compat`",
                tested=tested, installed=identity.as_dict(),
            )
    return stamp


def write_stamp(identity: omp_adapter.OmpIdentity, results: dict[str, Any]) -> dict[str, Any]:
    stamp = {"identity": identity.as_dict(), "tested_at": time.time(), "results": results}
    path = stamp_path()
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.write_text(json.dumps(stamp, indent=2) + "\n")
    return stamp


def strip_thinking(model: str) -> str:
    return model.split(":", 1)[0]


def profile_default_model(env: dict[str, str] | None = None) -> str | None:
    """The user's configured default role, read through OMP itself (no YAML parsing here)."""
    result = subprocess.run(
        [omp_adapter.omp_executable(), "config", "get", "modelRoles", "--json"],
        capture_output=True, text=True, timeout=60, env={**os.environ, **(env or {})},
    )
    if result.returncode != 0:
        return None
    roles = json.loads(result.stdout).get("value") or {}
    default = roles.get("default")
    return strip_thinking(default) if default else None


def profile_check() -> dict[str, Any]:
    """Real profile, no prompt and no tokens: the factory overlay keeps the user's routing."""
    rpc = omp_adapter.load_rpc_module()
    expected = profile_default_model()
    overrides = subprocess.run(
        [omp_adapter.omp_executable(), "config", "get", "task.agentModelOverrides", "--json"],
        capture_output=True, text=True, timeout=60,
    )
    client = rpc.RpcClient(
        extra_args=["--no-ui", "--no-session", "--config", str(FACTORY_DIR / "omp-overlay.yml")],
        cwd=FACTORY_DIR, startup_timeout=90,
    )
    client.start()
    try:
        state = client.request_raw("get_state")
        # Raw response: the typed client rejects catalog entries without maxTokens.
        models = client.request_raw("get_available_models").get("models", [])
        available = {f"{m['provider']}/{m['id']}" for m in models}
    finally:
        client.stop()
    resolved = f"{state['model']['provider']}/{state['model']['id']}"
    if expected and resolved != expected:
        raise Incompatible(f"with the factory overlay OMP resolves {resolved}, but the profile default is {expected}")
    return {
        "default_role": expected,
        "resolved_model": resolved,
        "default_available": resolved in available,
        "agent_model_overrides": json.loads(overrides.stdout).get("value") if overrides.returncode == 0 else None,
    }


def run(skip_profile: bool = False) -> dict[str, Any]:
    identity = omp_adapter.identify()
    sys.path.insert(0, str(FACTORY_DIR))
    suite = unittest.defaultTestLoader.loadTestsFromName("tests.test_omp_seams")
    outcome = unittest.TextTestRunner(stream=sys.stderr, verbosity=2).run(suite)
    results: dict[str, Any] = {
        "suite": "tests.test_omp_seams",
        "ran": outcome.testsRun,
        "failures": [str(t) for t, _ in outcome.failures + outcome.errors],
        "skipped": [str(t) for t, _ in outcome.skipped],
    }
    if outcome.failures or outcome.errors or outcome.skipped or outcome.testsRun == 0:
        raise Incompatible("OMP seam suite did not pass; not stamping this build", results=results)
    if not skip_profile:
        results["profile"] = profile_check()
    stamp = write_stamp(identity, results)
    return {"ok": True, "stamp": stamp, "path": str(stamp_path())}
