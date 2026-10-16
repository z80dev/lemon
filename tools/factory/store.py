"""Authoritative factory ledger: one SQLite database per project on one host.

Every mutation runs in a short `BEGIN IMMEDIATE` transaction that also appends
its event, so readers can always rediscover state from the ledger itself.
Never hold a transaction open across Git, GitHub, tests, or model requests.
"""

from __future__ import annotations

import hashlib
import json
import sqlite3
import time
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
BUSY_TIMEOUT_MS = 5000

PRIORITIES = ("urgent", "high", "normal", "low")
STATUSES = (
    "inbox",
    "queued",
    "active",
    "ready",
    "verifying",
    "awaiting_merge",
    "landed_pending_confirmation",
    "done",
    "blocked",
    "needs_input",
    "cancelled",
)
TERMINAL = {"done", "cancelled"}
TRANSITIONS: dict[str, set[str]] = {
    "inbox": {"queued", "blocked", "needs_input", "cancelled"},
    "queued": {"inbox", "active", "blocked", "needs_input", "cancelled"},
    "active": {"queued", "ready", "blocked", "needs_input", "cancelled"},
    "ready": {"active", "verifying", "blocked", "cancelled"},
    "verifying": {"active", "awaiting_merge", "blocked", "cancelled"},
    "awaiting_merge": {"active", "landed_pending_confirmation", "blocked", "cancelled"},
    "landed_pending_confirmation": {"active", "done", "blocked"},
    "blocked": {"inbox", "queued", "active", "needs_input", "cancelled"},
    "needs_input": {"inbox", "queued", "cancelled"},
    "done": set(),
    "cancelled": set(),
}
EDITABLE = ("title", "goal", "acceptance", "non_goals", "risk", "priority", "dependencies", "write_set", "notes")
LIST_FIELDS = ("acceptance", "non_goals", "dependencies", "write_set")
MODES = ("running", "paused", "draining", "stopped")
ATTEMPT_LIVE = ("reserved", "launched", "running")
ATTEMPT_FINAL = ("succeeded", "failed", "cancelled", "launch_unknown", "orphaned", "superseded")

_SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS tasks (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL,
  seq INTEGER NOT NULL,
  revision INTEGER NOT NULL,
  status TEXT NOT NULL,
  priority TEXT NOT NULL,
  title TEXT NOT NULL,
  raw_request TEXT NOT NULL,
  goal TEXT,
  acceptance TEXT NOT NULL DEFAULT '[]',
  non_goals TEXT NOT NULL DEFAULT '[]',
  risk TEXT,
  dependencies TEXT NOT NULL DEFAULT '[]',
  write_set TEXT NOT NULL DEFAULT '[]',
  notes TEXT,
  source TEXT NOT NULL,
  parent_id TEXT REFERENCES tasks(id),
  disposition TEXT,
  active_attempt TEXT,
  created_at REAL NOT NULL,
  updated_at REAL NOT NULL,
  UNIQUE (project_id, seq)
);
CREATE TABLE IF NOT EXISTS attempts (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL,
  task_id TEXT NOT NULL REFERENCES tasks(id),
  task_revision INTEGER NOT NULL,
  stage TEXT NOT NULL,
  epoch INTEGER NOT NULL,
  status TEXT NOT NULL,
  worker_ref TEXT,
  base_sha TEXT,
  head_sha TEXT,
  branch TEXT,
  outcome TEXT,
  created_at REAL NOT NULL,
  updated_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS events (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id TEXT NOT NULL,
  type TEXT NOT NULL,
  task_id TEXT,
  payload TEXT NOT NULL,
  actor TEXT NOT NULL,
  request_key TEXT,
  created_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS requests (
  project_id TEXT NOT NULL,
  key TEXT NOT NULL,
  op TEXT NOT NULL,
  digest TEXT NOT NULL,
  result TEXT NOT NULL,
  created_at REAL NOT NULL,
  PRIMARY KEY (project_id, key)
);
CREATE TABLE IF NOT EXISTS runtime (
  project_id TEXT PRIMARY KEY,
  desired_mode TEXT NOT NULL DEFAULT 'stopped',
  mode TEXT NOT NULL DEFAULT 'stopped',
  epoch INTEGER NOT NULL DEFAULT 0,
  supervisor_pid INTEGER,
  coordinator_pid INTEGER,
  session_id TEXT,
  session_file TEXT,
  model TEXT,
  heartbeat_at REAL,
  event_cursor INTEGER NOT NULL DEFAULT 0,
  detail TEXT NOT NULL DEFAULT '{}',
  updated_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS tasks_status ON tasks(project_id, status);
CREATE INDEX IF NOT EXISTS attempts_task ON attempts(task_id);
CREATE INDEX IF NOT EXISTS events_project ON events(project_id, seq);
"""


class FactoryError(Exception):
    code = "error"
    exit_code = 1

    def __init__(self, message: str, **details: Any) -> None:
        super().__init__(message)
        self.details = details

    def as_dict(self) -> dict[str, Any]:
        return {"ok": False, "error": self.code, "message": str(self), **self.details}


class NotFound(FactoryError):
    code = "not_found"
    exit_code = 4


class Invalid(FactoryError):
    code = "invalid"
    exit_code = 2


class RevisionConflict(FactoryError):
    code = "revision_conflict"
    exit_code = 3


class IdempotencyConflict(FactoryError):
    code = "idempotency_conflict"
    exit_code = 3


class AdmissionRefused(FactoryError):
    code = "admission_refused"
    exit_code = 5


def digest(op: str, payload: Any) -> str:
    canonical = json.dumps({"op": op, "payload": payload}, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode()).hexdigest()


def _task_row(row: sqlite3.Row) -> dict[str, Any]:
    task = dict(row)
    for field in (*LIST_FIELDS, "source"):
        task[field] = json.loads(task[field])
    return task


def _attempt_row(row: sqlite3.Row) -> dict[str, Any]:
    attempt = dict(row)
    attempt["outcome"] = json.loads(attempt["outcome"]) if attempt["outcome"] else None
    return attempt


class Ledger:
    def __init__(self, path: Path, project_id: str) -> None:
        self.path = Path(path)
        self.project_id = project_id
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        conn = self._connect()
        try:
            self._migrate(conn)
        finally:
            conn.close()

    # -- connection and transactions -------------------------------------------------

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.path, timeout=BUSY_TIMEOUT_MS / 1000, isolation_level=None)
        conn.row_factory = sqlite3.Row
        conn.execute(f"PRAGMA busy_timeout = {BUSY_TIMEOUT_MS}")
        conn.execute("PRAGMA journal_mode = WAL")
        # FULL: a returned task ID survives power loss, not just a process crash.
        conn.execute("PRAGMA synchronous = FULL")
        conn.execute("PRAGMA foreign_keys = ON")
        return conn

    @contextmanager
    def read(self) -> Iterator[sqlite3.Connection]:
        conn = self._connect()
        try:
            yield conn
        finally:
            conn.close()

    @contextmanager
    def write(self) -> Iterator[sqlite3.Connection]:
        conn = self._connect()
        try:
            conn.execute("BEGIN IMMEDIATE")
            try:
                yield conn
            except BaseException:
                conn.execute("ROLLBACK")
                raise
            conn.execute("COMMIT")
        finally:
            conn.close()

    def _migrate(self, conn: sqlite3.Connection) -> None:
        conn.execute("BEGIN IMMEDIATE")
        try:
            for statement in filter(str.strip, _SCHEMA.split(";")):
                conn.execute(statement)
            row = conn.execute("SELECT value FROM meta WHERE key = 'schema_version'").fetchone()
            if row is None:
                conn.execute("INSERT INTO meta VALUES ('schema_version', ?)", (str(SCHEMA_VERSION),))
            elif int(row["value"]) > SCHEMA_VERSION:
                raise FactoryError(f"ledger schema {row['value']} is newer than this factory ({SCHEMA_VERSION})")
            conn.execute(
                "INSERT OR IGNORE INTO runtime (project_id, updated_at) VALUES (?, ?)",
                (self.project_id, time.time()),
            )
            conn.execute("COMMIT")
        except BaseException:
            conn.execute("ROLLBACK")
            raise

    def backup(self, destination: Path) -> None:
        """Consistent online copy (WAL-safe), unlike copying the file."""
        with self.read() as source:
            target = sqlite3.connect(destination)
            try:
                source.backup(target)
            finally:
                target.close()

    # -- events and idempotency ------------------------------------------------------

    def _event(
        self,
        conn: sqlite3.Connection,
        type_: str,
        actor: str,
        payload: dict[str, Any],
        task_id: str | None = None,
        request_key: str | None = None,
    ) -> int:
        cursor = conn.execute(
            "INSERT INTO events (project_id, type, task_id, payload, actor, request_key, created_at)"
            " VALUES (?, ?, ?, ?, ?, ?, ?)",
            (self.project_id, type_, task_id, json.dumps(payload), actor, request_key, time.time()),
        )
        return int(cursor.lastrowid)

    def _replay(self, conn: sqlite3.Connection, key: str | None, op: str, request_digest: str) -> Any:
        if key is None:
            return None
        row = conn.execute(
            "SELECT op, digest, result FROM requests WHERE project_id = ? AND key = ?", (self.project_id, key)
        ).fetchone()
        if row is None:
            return None
        if row["op"] != op or row["digest"] != request_digest:
            raise IdempotencyConflict(f"request key {key!r} was already used with different contents", key=key)
        return json.loads(row["result"])

    def _remember(self, conn: sqlite3.Connection, key: str | None, op: str, request_digest: str, result: Any) -> None:
        if key is not None:
            conn.execute(
                "INSERT INTO requests (project_id, key, op, digest, result, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                (self.project_id, key, op, request_digest, json.dumps(result), time.time()),
            )

    def events_after(self, seq: int, limit: int = 100) -> list[dict[str, Any]]:
        with self.read() as conn:
            rows = conn.execute(
                "SELECT * FROM events WHERE project_id = ? AND seq > ? ORDER BY seq LIMIT ?",
                (self.project_id, seq, limit),
            ).fetchall()
        return [{**dict(r), "payload": json.loads(r["payload"])} for r in rows]

    def last_event_seq(self) -> int:
        with self.read() as conn:
            row = conn.execute("SELECT MAX(seq) AS seq FROM events WHERE project_id = ?", (self.project_id,)).fetchone()
        return int(row["seq"] or 0)

    # -- tasks -------------------------------------------------------------------------

    def _get(self, conn: sqlite3.Connection, task_id: str) -> dict[str, Any]:
        row = conn.execute("SELECT * FROM tasks WHERE project_id = ? AND id = ?", (self.project_id, task_id)).fetchone()
        if row is None:
            raise NotFound(f"no task {task_id}", task_id=task_id)
        return _task_row(row)

    def get_task(self, task_id: str) -> dict[str, Any]:
        with self.read() as conn:
            return self._get(conn, task_id)

    def list_tasks(self, statuses: tuple[str, ...] | None = None) -> list[dict[str, Any]]:
        query = "SELECT * FROM tasks WHERE project_id = ?"
        params: list[Any] = [self.project_id]
        if statuses:
            query += f" AND status IN ({','.join('?' * len(statuses))})"
            params.extend(statuses)
        order = " ORDER BY CASE priority " + " ".join(f"WHEN '{p}' THEN {i}" for i, p in enumerate(PRIORITIES))
        with self.read() as conn:
            rows = conn.execute(query + order + " END, seq", params).fetchall()
        return [_task_row(r) for r in rows]

    def add_task(self, request: dict[str, Any], *, actor: str, request_key: str | None) -> tuple[dict[str, Any], bool]:
        """Create a task; returns (task, replayed). Replays never create a second task."""
        raw = (request.get("request") or "").strip()
        if not raw:
            raise Invalid("request text is required")
        priority = request.get("priority") or "normal"
        if priority not in PRIORITIES:
            raise Invalid(f"priority must be one of {PRIORITIES}")
        source = request.get("source") or {"kind": "user_request"}
        title = (request.get("title") or raw.splitlines()[0])[:120]
        request_digest = digest("add", {"request": raw, "priority": priority, "title": title, "source": source,
                                        "acceptance": request.get("acceptance") or [], "parent_id": request.get("parent_id")})
        with self.write() as conn:
            replay = self._replay(conn, request_key, "add", request_digest)
            if replay is not None:
                return self._get(conn, replay["task_id"]), True
            if source.get("kind") == "github_issue":
                dup = conn.execute(
                    "SELECT id FROM tasks WHERE project_id = ? AND json_extract(source, '$.kind') = 'github_issue'"
                    " AND json_extract(source, '$.repository') = ? AND json_extract(source, '$.number') = ?",
                    (self.project_id, source.get("repository"), source.get("number")),
                ).fetchone()
                if dup is not None:
                    raise IdempotencyConflict(f"issue already imported as {dup['id']}", task_id=dup["id"])
            parent_id = request.get("parent_id")
            if parent_id is not None:
                self._get(conn, parent_id)
            row = conn.execute("SELECT COALESCE(MAX(seq), 0) + 1 AS next FROM tasks WHERE project_id = ?",
                               (self.project_id,)).fetchone()
            seq = int(row["next"])
            task_id = f"F-{seq:04d}"
            now = time.time()
            conn.execute(
                "INSERT INTO tasks (id, project_id, seq, revision, status, priority, title, raw_request, acceptance,"
                " source, parent_id, created_at, updated_at) VALUES (?, ?, ?, 1, 'inbox', ?, ?, ?, ?, ?, ?, ?, ?)",
                (task_id, self.project_id, seq, priority, title, raw, json.dumps(request.get("acceptance") or []),
                 json.dumps(source), parent_id, now, now),
            )
            self._event(conn, "task.created", actor, {"priority": priority, "title": title}, task_id, request_key)
            self._remember(conn, request_key, "add", request_digest, {"task_id": task_id})
            return self._get(conn, task_id), False

    def edit_task(
        self, task_id: str, expected_revision: int | None, changes: dict[str, Any], *, actor: str,
        request_key: str | None,
    ) -> dict[str, Any]:
        """Revision-checked edit. `expected_revision=None` applies to the current revision atomically
        (only for operator commands like prioritize that are not read-modify-write)."""
        unknown = set(changes) - set(EDITABLE)
        if unknown:
            raise Invalid(f"fields not editable: {sorted(unknown)}")
        if not changes:
            raise Invalid("no changes given")
        if "priority" in changes and changes["priority"] not in PRIORITIES:
            raise Invalid(f"priority must be one of {PRIORITIES}")
        for field in LIST_FIELDS:
            if field in changes and not isinstance(changes[field], list):
                raise Invalid(f"{field} must be a list")
        request_digest = digest("edit", {"task_id": task_id, "rev": expected_revision, "changes": changes})
        with self.write() as conn:
            replay = self._replay(conn, request_key, "edit", request_digest)
            if replay is not None:
                return self._get(conn, task_id)
            task = self._get(conn, task_id)
            if expected_revision is not None and task["revision"] != expected_revision:
                raise RevisionConflict(
                    f"{task_id} is at revision {task['revision']}, not {expected_revision}", current=task
                )
            if task["status"] in TERMINAL:
                raise Invalid(f"{task_id} is {task['status']}")
            if "dependencies" in changes:
                for dep in changes["dependencies"]:
                    if dep == task_id:
                        raise Invalid("a task cannot depend on itself")
                    self._get(conn, dep)
            assignments = ", ".join(f"{field} = ?" for field in changes)
            values = [json.dumps(v) if field in LIST_FIELDS else v for field, v in changes.items()]
            conn.execute(
                f"UPDATE tasks SET {assignments}, revision = revision + 1, updated_at = ? WHERE id = ?",
                (*values, time.time(), task_id),
            )
            self._event(conn, "task.updated", actor, {"fields": sorted(changes), "revision": task["revision"] + 1,
                                                      "changes": changes}, task_id, request_key)
            self._remember(conn, request_key, "edit", request_digest, {"task_id": task_id})
            return self._get(conn, task_id)

    def transition(
        self,
        task_id: str,
        expected_revision: int,
        to_status: str,
        *,
        actor: str,
        reason: str,
        request_key: str | None,
        disposition: str | None = None,
    ) -> dict[str, Any]:
        if to_status not in STATUSES:
            raise Invalid(f"unknown status {to_status}")
        if to_status == "cancelled" and not disposition:
            raise Invalid("cancelling requires an explicit disposition")
        request_digest = digest("transition", {"task_id": task_id, "rev": expected_revision, "to": to_status,
                                               "reason": reason, "disposition": disposition})
        with self.write() as conn:
            replay = self._replay(conn, request_key, "transition", request_digest)
            if replay is not None:
                return self._get(conn, task_id)
            task = self._get(conn, task_id)
            if task["revision"] != expected_revision:
                raise RevisionConflict(
                    f"{task_id} is at revision {task['revision']}, not {expected_revision}", current=task
                )
            if to_status not in TRANSITIONS[task["status"]]:
                raise Invalid(f"{task_id}: {task['status']} -> {to_status} is not allowed")
            conn.execute(
                "UPDATE tasks SET status = ?, disposition = COALESCE(?, disposition), revision = revision + 1,"
                " updated_at = ? WHERE id = ?",
                (to_status, disposition, time.time(), task_id),
            )
            self._event(conn, "task.transitioned", actor, {"from": task["status"], "to": to_status, "reason": reason,
                                                           "revision": expected_revision + 1}, task_id, request_key)
            self._remember(conn, request_key, "transition", request_digest, {"task_id": task_id})
            return self._get(conn, task_id)

    # -- runtime -----------------------------------------------------------------------

    def runtime(self) -> dict[str, Any]:
        with self.read() as conn:
            row = conn.execute("SELECT * FROM runtime WHERE project_id = ?", (self.project_id,)).fetchone()
        result = dict(row)
        result["detail"] = json.loads(result["detail"])
        return result

    def request_mode(self, mode: str, *, actor: str) -> dict[str, Any]:
        """Record the operator's desired mode. Admission checks read it immediately."""
        if mode not in MODES:
            raise Invalid(f"mode must be one of {MODES}")
        with self.write() as conn:
            row = conn.execute("SELECT desired_mode FROM runtime WHERE project_id = ?", (self.project_id,)).fetchone()
            if row["desired_mode"] != mode:
                conn.execute("UPDATE runtime SET desired_mode = ?, updated_at = ? WHERE project_id = ?",
                             (mode, time.time(), self.project_id))
                self._event(conn, "runtime.mode_requested", actor, {"from": row["desired_mode"], "to": mode})
        return self.runtime()

    def update_runtime(self, *, event: str | None = None, actor: str = "supervisor", **fields: Any) -> None:
        allowed = {"mode", "epoch", "supervisor_pid", "coordinator_pid", "session_id", "session_file", "model",
                   "heartbeat_at", "detail", "desired_mode"}
        if set(fields) - allowed:
            raise Invalid(f"unknown runtime fields {sorted(set(fields) - allowed)}")
        if "detail" in fields:
            fields["detail"] = json.dumps(fields["detail"])
        with self.write() as conn:
            if fields:
                assignments = ", ".join(f"{k} = ?" for k in fields)
                conn.execute(f"UPDATE runtime SET {assignments}, updated_at = ? WHERE project_id = ?",
                             (*fields.values(), time.time(), self.project_id))
            if event:
                payload = {k: v for k, v in fields.items() if k in ("mode", "epoch", "coordinator_pid", "session_id")}
                self._event(conn, event, actor, payload)

    def begin_epoch(self, supervisor_pid: int) -> int:
        with self.write() as conn:
            conn.execute(
                "UPDATE runtime SET epoch = epoch + 1, mode = 'starting', supervisor_pid = ?, coordinator_pid = NULL,"
                " heartbeat_at = ?, updated_at = ? WHERE project_id = ?",
                (supervisor_pid, time.time(), time.time(), self.project_id),
            )
            epoch = int(conn.execute("SELECT epoch FROM runtime WHERE project_id = ?", (self.project_id,)).fetchone()[0])
            self._event(conn, "runtime.epoch_started", "supervisor", {"epoch": epoch, "supervisor_pid": supervisor_pid})
            return epoch

    def checkpoint(self, seq: int, *, epoch: int) -> int:
        """Advance the processed-event cursor; never backwards, never past the log, never from a stale epoch.

        Deliberately not an event: a checkpoint must not wake the coordinator about itself.
        """
        with self.write() as conn:
            row = conn.execute("SELECT epoch, event_cursor FROM runtime WHERE project_id = ?",
                               (self.project_id,)).fetchone()
            if row["epoch"] != epoch:
                raise AdmissionRefused(f"stale coordinator epoch {epoch}; current is {row['epoch']}")
            last = conn.execute("SELECT COALESCE(MAX(seq), 0) FROM events WHERE project_id = ?",
                                (self.project_id,)).fetchone()[0]
            target = min(max(seq, row["event_cursor"]), last)
            conn.execute("UPDATE runtime SET event_cursor = ?, updated_at = ? WHERE project_id = ?",
                         (target, time.time(), self.project_id))
            return int(target)

    # -- attempts ------------------------------------------------------------------------

    def reserve_attempt(
        self, task_id: str, expected_revision: int, stage: str, *, epoch: int, actor: str, request_key: str | None,
        base_sha: str | None = None, max_live: int | None = None,
    ) -> dict[str, Any]:
        """Deterministic admission: runtime mode, epoch fencing, capacity, task state and dependencies."""
        request_digest = digest("reserve", {"task_id": task_id, "rev": expected_revision, "stage": stage,
                                            "epoch": epoch})
        with self.write() as conn:
            replay = self._replay(conn, request_key, "reserve", request_digest)
            if replay is not None:
                return self.get_attempt_in(conn, replay["attempt_id"])
            runtime = conn.execute("SELECT * FROM runtime WHERE project_id = ?", (self.project_id,)).fetchone()
            if runtime["desired_mode"] != "running" or runtime["mode"] != "running":
                raise AdmissionRefused(f"factory is {runtime['desired_mode']}/{runtime['mode']}; no new admissions")
            if runtime["epoch"] != epoch:
                raise AdmissionRefused(f"stale coordinator epoch {epoch}; current is {runtime['epoch']}")
            task = self._get(conn, task_id)
            if task["revision"] != expected_revision:
                raise RevisionConflict(f"{task_id} is at revision {task['revision']}", current=task)
            if task["status"] != "queued":
                raise AdmissionRefused(f"{task_id} is {task['status']}, not queued")
            for dep in task["dependencies"]:
                if self._get(conn, dep)["status"] != "done":
                    raise AdmissionRefused(f"{task_id} depends on {dep}, which is not done")
            live = conn.execute(
                f"SELECT id FROM attempts WHERE task_id = ? AND status IN ({','.join('?' * len(ATTEMPT_LIVE))})",
                (task_id, *ATTEMPT_LIVE),
            ).fetchone()
            if live is not None:
                raise AdmissionRefused(f"{task_id} already has live attempt {live['id']}")
            if max_live is not None:
                running = conn.execute(
                    f"SELECT COUNT(*) FROM attempts WHERE project_id = ? AND stage = ? AND status IN"
                    f" ({','.join('?' * len(ATTEMPT_LIVE))})",
                    (self.project_id, stage, *ATTEMPT_LIVE),
                ).fetchone()[0]
                if running >= max_live:
                    raise AdmissionRefused(f"{running} {stage} attempts live; policy allows {max_live}")
            count = conn.execute("SELECT COUNT(*) FROM attempts WHERE task_id = ? AND stage = ?",
                                 (task_id, stage)).fetchone()[0]
            attempt_id = f"{task_id}-{stage}-{count + 1}"
            now = time.time()
            conn.execute(
                "INSERT INTO attempts (id, project_id, task_id, task_revision, stage, epoch, status, base_sha,"
                " created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, 'reserved', ?, ?, ?)",
                (attempt_id, self.project_id, task_id, expected_revision, stage, epoch, base_sha, now, now),
            )
            conn.execute(
                "UPDATE tasks SET status = 'active', active_attempt = ?, revision = revision + 1, updated_at = ?"
                " WHERE id = ?",
                (attempt_id, now, task_id),
            )
            self._event(conn, "attempt.reserved", actor, {"attempt_id": attempt_id, "stage": stage, "epoch": epoch},
                        task_id, request_key)
            self._remember(conn, request_key, "reserve", request_digest, {"attempt_id": attempt_id})
            return self.get_attempt_in(conn, attempt_id)

    def get_attempt_in(self, conn: sqlite3.Connection, attempt_id: str) -> dict[str, Any]:
        row = conn.execute("SELECT * FROM attempts WHERE id = ? AND project_id = ?",
                           (attempt_id, self.project_id)).fetchone()
        if row is None:
            raise NotFound(f"no attempt {attempt_id}")
        return _attempt_row(row)

    def get_attempt(self, attempt_id: str) -> dict[str, Any]:
        with self.read() as conn:
            return self.get_attempt_in(conn, attempt_id)

    def list_attempts(self, statuses: tuple[str, ...] | None = None, task_id: str | None = None) -> list[dict[str, Any]]:
        query = "SELECT * FROM attempts WHERE project_id = ?"
        params: list[Any] = [self.project_id]
        if statuses:
            query += f" AND status IN ({','.join('?' * len(statuses))})"
            params.extend(statuses)
        if task_id:
            query += " AND task_id = ?"
            params.append(task_id)
        with self.read() as conn:
            return [_attempt_row(r) for r in conn.execute(query + " ORDER BY created_at", params).fetchall()]

    def update_attempt(
        self, attempt_id: str, *, status: str, actor: str, epoch: int | None, request_key: str | None = None,
        worker_ref: str | None = None, head_sha: str | None = None, branch: str | None = None,
        outcome: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        if status not in ATTEMPT_LIVE + ATTEMPT_FINAL:
            raise Invalid(f"unknown attempt status {status}")
        request_digest = digest("attempt", {"id": attempt_id, "status": status, "worker_ref": worker_ref,
                                            "head_sha": head_sha, "branch": branch, "outcome": outcome})
        with self.write() as conn:
            if self._replay(conn, request_key, "attempt", request_digest) is not None:
                return self.get_attempt_in(conn, attempt_id)
            attempt = self.get_attempt_in(conn, attempt_id)
            if epoch is not None and attempt["epoch"] != epoch:
                raise AdmissionRefused(f"attempt {attempt_id} belongs to epoch {attempt['epoch']}, not {epoch}")
            if attempt["status"] in ATTEMPT_FINAL:
                raise Invalid(f"attempt {attempt_id} is already {attempt['status']}")
            conn.execute(
                "UPDATE attempts SET status = ?, worker_ref = COALESCE(?, worker_ref), head_sha = COALESCE(?, head_sha),"
                " branch = COALESCE(?, branch), outcome = COALESCE(?, outcome), updated_at = ? WHERE id = ?",
                (status, worker_ref, head_sha, branch, json.dumps(outcome) if outcome is not None else None,
                 time.time(), attempt_id),
            )
            self._event(conn, f"attempt.{status}", actor, {"attempt_id": attempt_id, "worker_ref": worker_ref,
                                                           "branch": branch, "head_sha": head_sha},
                        attempt["task_id"], request_key)
            self._remember(conn, request_key, "attempt", request_digest, {"attempt_id": attempt_id})
            return self.get_attempt_in(conn, attempt_id)
