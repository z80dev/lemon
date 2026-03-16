"""Task #7 — codex-3: Launcher path doubling smoke test.

Run lemon-cli --help from the repo root and expect:
  - exit code 0
  - usage text in stdout
"""
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]  # .../lemon
LAUNCHER = REPO_ROOT / "clients" / "lemon-cli" / "bin" / "lemon-cli"


def test_launcher_help_exits_zero():
    """bin/lemon-cli --help must exit 0 and print usage text."""
    result = subprocess.run(
        [str(LAUNCHER), "--help"],
        capture_output=True,
        text=True,
        cwd=str(REPO_ROOT),
    )
    assert result.returncode == 0, (
        f"Expected exit 0, got {result.returncode}\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    )
    combined = result.stdout + result.stderr
    assert "usage" in combined.lower() or "lemon" in combined.lower(), (
        f"Expected usage text, got:\n{combined}"
    )
