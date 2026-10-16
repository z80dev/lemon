"""Dashboard state gathered through existing store and supervisor read paths."""

from __future__ import annotations

import time
from pathlib import Path
from typing import Any

import project as projects
import supervisor
from store import ATTEMPT_LIVE, STATUSES, TERMINAL, Ledger

EVENT_LIMIT = 60
FINISHED_SHOWN = 10
LOG_LINES = 120
CI_LOG_LINES = 40
TAIL_BYTES = 64 * 1024
INTEGRATING = ("verifying", "awaiting_merge", "landed_pending_confirmation", "blocked")


def tail_text(path: Path, lines: int) -> str | None:
    """Last `lines` lines of an untrusted file, with control characters replaced; None if unreadable."""
    try:
        with open(path, "rb") as handle:
            handle.seek(0, 2)
            size = handle.tell()
            handle.seek(max(0, size - TAIL_BYTES))
            raw = handle.read()
    except OSError:
        return None
    text = raw.decode("utf-8", errors="replace")
    clean = "".join(ch if ch in "\n\t" or ch.isprintable() else "\ufffd" for ch in text)
    return "\n".join(clean.splitlines()[-lines:])


def ci_log_tail(project: projects.Project, task_id: str) -> dict[str, str] | None:
    """Newest CI failure log the integrator stored for this task (`artifacts/ci/<task>-run-<id>.log`)."""
    logs = sorted((project.state_dir / "artifacts" / "ci").glob(f"{task_id}-run-*.log"),
                  key=lambda p: p.stat().st_mtime)
    if not logs:
        return None
    text = tail_text(logs[-1], CI_LOG_LINES)
    return None if text is None else {"name": logs[-1].name, "tail": text}


def _task(task: dict[str, Any]) -> dict[str, Any]:
    return {k: task[k] for k in ("id", "revision", "status", "priority", "title", "dependencies", "updated_at")}


def collect(project: projects.Project, ledger: Ledger) -> dict[str, Any]:
    tasks = ledger.list_tasks()
    by_id = {t["id"]: t for t in tasks}
    by_status: dict[str, list[dict[str, Any]]] = {s: [] for s in STATUSES}
    for task in tasks:
        by_status[task["status"]].append(_task(task))
    for status in TERMINAL:
        by_status[status] = sorted(by_status[status], key=lambda t: -t["updated_at"])[:FINISHED_SHOWN]
    attempts = [
        {**{k: a[k] for k in ("id", "task_id", "stage", "status", "epoch", "worker_ref", "branch", "head_sha",
                              "created_at", "updated_at")},
         "task_title": by_id[a["task_id"]]["title"] if a["task_id"] in by_id else None}
        for a in ledger.list_attempts(ATTEMPT_LIVE)
    ]
    integrations = []
    for task in tasks:
        if task["status"] not in INTEGRATING:
            continue
        integration = ledger.get_integration(task["id"])
        if integration is None:
            continue
        integrations.append({"task": _task(task), "integration": integration,
                             "ci_log": ci_log_tail(project, task["id"])})
    last = ledger.last_event_seq()
    events = ledger.events_after(max(0, last - EVENT_LIMIT), EVENT_LIMIT)
    return {
        "project": project.id,
        "repository": project.repository,
        "generated_at": time.time(),
        "runtime": supervisor.health(project, ledger),
        "counts": {s: sum(1 for t in tasks if t["status"] == s) for s in STATUSES},
        "tasks": by_status,
        "attempts": attempts,
        "integrations": integrations,
        "events": list(reversed(events)),
        "last_event": last,
        "supervisor_log": tail_text(project.logs_dir / "supervisor.log", LOG_LINES),
    }
