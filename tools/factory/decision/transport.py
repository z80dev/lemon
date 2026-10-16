"""Secret-free bridge to the read-only OMP/Bun credential transport."""
from __future__ import annotations

import json
import math
import os
from pathlib import Path
import shutil
import subprocess

from omp_adapter import _source_root, omp_executable

_LIMIT = 65536
_ERRORS = frozenset({"protocol_unavailable", "catalog_unavailable", "credential_unavailable", "timeout", "invalid_request", "invalid_response", "protocol_invalid", "http_error", "transport_unavailable"})


class OmpTransport:
    """Resolve credentials only inside Bun; never return subprocess diagnostics."""

    def __call__(self, payload: dict, timeout_s: float) -> dict:
        def unavailable(error: str) -> dict:
            return {"status": None, "body": {}, "error_class": error}

        if not isinstance(timeout_s, (int, float)) or not math.isfinite(timeout_s) or timeout_s <= 0:
            return unavailable("timeout")
        try:
            bun = shutil.which("bun")
            root = _source_root(os.path.realpath(omp_executable()))
            if not bun or root is None:
                return unavailable("transport_unavailable")
            encoded = json.dumps({"payload": payload, "timeout_ms": timeout_s * 1000}, allow_nan=False).encode()
            if len(encoded) > _LIMIT:
                return unavailable("protocol_unavailable")
            # No inherited provider credentials, proxy settings, preload hooks or shell config.
            child_env = {"HOME": str(Path.home()), "PATH": os.defpath}
            result = subprocess.run(
                [bun, "run", str(Path(__file__).with_name("omp_transport.ts")), str(root)],
                input=encoded, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                timeout=timeout_s, env=child_env, check=False,
            )
            if result.returncode != 0 or len(result.stdout) > _LIMIT:
                return unavailable("transport_unavailable")
            receipt = json.loads(result.stdout)
            if not isinstance(receipt, dict):
                return unavailable("protocol_invalid")
            status = receipt.get("status")
            if status is not None and (type(status) is not int or not 100 <= status <= 599):
                return unavailable("protocol_invalid")
            error = receipt.get("error_class")
            if error is not None:
                return {"status": status, "body": {}, "error_class": error if error in _ERRORS else "transport_unavailable"}
            body = receipt.get("body")
            if not isinstance(body, dict):
                return unavailable("protocol_invalid")
            return {"status": status, "body": body, "error_class": None}
        except subprocess.TimeoutExpired:
            return unavailable("timeout")
        except Exception:
            return unavailable("transport_unavailable")
