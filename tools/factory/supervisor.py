#!/usr/bin/env python3
"""Local supervisor: owns the single OMP RPC coordinator for one project.

It is deterministic glue, not a planner: a kernel lock for single-instance
ownership, prerequisite checks, a clean dedicated checkout, coordinator launch
over documented RPC, coalesced wake-ups from the ledger, and bounded shutdown.
Model inference happens only when there is an actionable ledger event.
"""

from __future__ import annotations

import argparse
import errno
import fcntl
import hashlib
import json
import os
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

import compat  # noqa: E402
import omp_adapter  # noqa: E402
import project as projects  # noqa: E402
from store import ATTEMPT_LIVE, AdmissionRefused, FactoryError, Invalid, Ledger, RevisionConflict  # noqa: E402

RELEASE_ROOT = Path(__file__).resolve().parents[2]
HEARTBEAT_S = 2.0
STALE_HEARTBEAT_S = 20.0
POLL_S = 0.5
LOCK_RETRY_S = 3.0
GRACEFUL_EXIT_S = 20.0
COORDINATOR_ACTOR = "coordinator"
# Events produced by the coordinator itself or by the supervisor's own bookkeeping
# never wake the coordinator; everything else in the ledger is potentially actionable.
QUIET_EVENT_PREFIXES = ("runtime.", "attempt.reserved")


class Blocked(FactoryError):
    code = "blocked"
    exit_code = 6


# -- release, policy and health ---------------------------------------------------------


def release_version(root: Path = RELEASE_ROOT) -> str:
    marker = root / "VERSION"
    if marker.exists():
        return marker.read_text().strip()
    try:
        sha = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=root, capture_output=True, text=True,
                             check=True).stdout.strip()
        return f"unreleased:{sha}"
    except (subprocess.CalledProcessError, FileNotFoundError):
        return "unreleased:unknown"


def load_policy(project: projects.Project) -> dict[str, Any]:
    if not project.policy_path.exists():
        raise Blocked(
            f"no approved policy at {project.policy_path}; review .factory/policy.example.json and copy it there",
            policy_path=str(project.policy_path),
        )
    return json.loads(project.policy_path.read_text())


def _lock_held(project: projects.Project) -> bool:
    project.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    with open(project.lock_path, "a+") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_SH | fcntl.LOCK_NB)
        except OSError as exc:
            if exc.errno in (errno.EAGAIN, errno.EACCES, errno.EWOULDBLOCK):
                return True
            raise
        fcntl.flock(handle, fcntl.LOCK_UN)
        return False


def health(project: projects.Project, ledger: Ledger) -> dict[str, Any]:
    """Actual state: a live process alone never counts as a healthy coordinator."""
    runtime = ledger.runtime()
    alive = _lock_held(project)
    age = time.time() - runtime["heartbeat_at"] if runtime["heartbeat_at"] else None
    if not alive:
        state = "stopped"
    elif age is None or age > STALE_HEARTBEAT_S:
        state = "unresponsive"
    else:
        state = runtime["mode"]
        if state == "running" and runtime["detail"].get("retrying"):
            state = "rate_limited"
    return {
        "state": state,
        "desired_mode": runtime["desired_mode"],
        "epoch": runtime["epoch"],
        "supervisor_pid": runtime["supervisor_pid"] if alive else None,
        "coordinator_pid": runtime["coordinator_pid"] if alive else None,
        "session_id": runtime["session_id"],
        "model": runtime["model"],
        "heartbeat_age_s": round(age, 1) if age is not None else None,
        "event_cursor": runtime["event_cursor"],
        "unclean_previous_exit": (not alive) and runtime["mode"] not in ("stopped",),
        "detail": runtime["detail"],
    }


# -- process tree helpers ---------------------------------------------------------------


def descendants(root_pid: int) -> list[int]:
    """All live descendants of root_pid (tool shells leave OMP's process group)."""
    out = subprocess.run(["ps", "-A", "-o", "pid=,ppid="], capture_output=True, text=True).stdout
    children: dict[int, list[int]] = {}
    for line in out.splitlines():
        pid, ppid = (int(x) for x in line.split())
        children.setdefault(ppid, []).append(pid)
    found: list[int] = []
    stack = [root_pid]
    while stack:
        for child in children.get(stack.pop(), []):
            found.append(child)
            stack.append(child)
    return found


def kill_tree(root_pid: int) -> list[int]:
    victims = [root_pid, *descendants(root_pid)]
    for pid in victims:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    return victims


# -- CLI-side lifecycle operations ------------------------------------------------------


def start(project: projects.Project, *, actor: str, wait: float) -> dict[str, Any]:
    ledger = project.ledger()
    current = health(project, ledger)
    if current["state"] not in ("stopped",):
        return {"ok": True, "attached": True, "runtime": current}
    load_policy(project)  # fail fast and precisely before spawning anything
    previous_epoch = current["epoch"]
    ledger.request_mode("running", actor=actor)
    project.logs_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    log = open(project.logs_dir / "supervisor.log", "ab")
    proc = subprocess.Popen(
        [sys.executable, str(Path(__file__).resolve()), "--project", project.id],
        stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True, close_fds=True,
    )
    log.close()
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:
        state = health(project, ledger)
        if state["epoch"] > previous_epoch and state["state"] not in ("starting", "recovering", "unresponsive"):
            break
        if proc.poll() is not None and not _lock_held(project):
            state = health(project, ledger)
            if state["epoch"] > previous_epoch:
                break  # started and already failed: report its recorded detail
        time.sleep(0.2)
    else:
        state = health(project, ledger)
    return {"ok": state["state"] in ("running", "paused"), "attached": False, "runtime": state}


def request_mode(project: projects.Project, mode: str, *, actor: str) -> dict[str, Any]:
    ledger = project.ledger()
    if health(project, ledger)["state"] == "stopped":
        return {"ok": False, "error": "not_running", "message": f"factory is stopped; cannot {mode}",
                "runtime": health(project, ledger)}
    ledger.request_mode(mode, actor=actor)
    return {"ok": True, "runtime": health(project, ledger)}


def stop(project: projects.Project, *, actor: str, abort: bool, wait: float) -> dict[str, Any]:
    ledger = project.ledger()
    state = health(project, ledger)
    if state["state"] == "stopped":
        ledger.request_mode("stopped", actor=actor)
        return {"ok": True, "runtime": state}
    ledger.request_mode("stopped", actor=actor)
    if abort:
        killed: list[int] = []
        for pid in (state["supervisor_pid"], state["coordinator_pid"]):
            if pid:
                killed.extend(kill_tree(pid))
        uncertain = _orphan_live_attempts(ledger, reason="emergency abort: worker cleanup not confirmed")
        ledger.update_runtime(mode="stopped", event="runtime.emergency_abort", actor=actor,
                              detail={"killed": killed, "uncertain_attempts": uncertain})
        deadline = time.monotonic() + 10
        while _lock_held(project) and time.monotonic() < deadline:
            time.sleep(0.1)
        return {"ok": True, "aborted": True, "killed": killed, "uncertain_attempts": uncertain,
                "runtime": health(project, ledger)}
    deadline = time.monotonic() + wait
    while _lock_held(project) and time.monotonic() < deadline:
        time.sleep(0.2)
    final = health(project, ledger)
    return {"ok": final["state"] == "stopped", "runtime": final}


def verified_base(project: projects.Project, ledger: Ledger) -> str | None:
    """Dispatch only from the recorded clean coordinator base: isolated workers inherit dirty state."""
    base = ledger.runtime()["detail"].get("base_sha")
    if not base:
        return None  # never started: reserve_attempt's runtime-mode gate refuses
    checkout = project.checkout_dir
    status = subprocess.run(["git", "status", "--porcelain", "--untracked-files=all"], cwd=checkout,
                            capture_output=True, text=True, timeout=60)
    head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=checkout, capture_output=True, text=True, timeout=60)
    if status.returncode != 0 or status.stdout.strip():
        raise AdmissionRefused("coordinator checkout has local changes; workers would inherit them",
                               dirty=status.stdout.splitlines()[:20])
    if head.stdout.strip() != base:
        raise AdmissionRefused(f"coordinator checkout moved from recorded base {base[:12]} to {head.stdout.strip()[:12]}")
    return base


def _orphan_live_attempts(ledger: Ledger, *, reason: str) -> list[str]:
    """Unknown worker state stays blocked for reconciliation; never silently re-queued."""
    affected = []
    for attempt in ledger.list_attempts(ATTEMPT_LIVE):
        ledger.update_attempt(attempt["id"], status="orphaned", actor="supervisor", epoch=None,
                              outcome={"reason": reason})
        _block_task(ledger, attempt["task_id"], reason)
        affected.append(attempt["id"])
    return affected


def _block_task(ledger: Ledger, task_id: str, reason: str) -> None:
    for _ in range(3):
        task = ledger.get_task(task_id)
        if task["status"] in ("blocked", "done", "cancelled"):
            return
        try:
            ledger.transition(task_id, task["revision"], "blocked", actor="supervisor", reason=reason,
                              request_key=None)
            return
        except RevisionConflict:
            continue
        except Invalid:
            return


def _requeue_task(ledger: Ledger, task_id: str, reason: str) -> None:
    task = ledger.get_task(task_id)
    if task["status"] == "active":
        ledger.transition(task_id, task["revision"], "queued", actor="supervisor", reason=reason, request_key=None)


# -- the supervisor daemon ----------------------------------------------------------------


class Supervisor:
    def __init__(self, project: projects.Project) -> None:
        self.project = project
        self.ledger = project.ledger()
        self.retrying: str | None = None
        self.lock_handle: Any = None
        self.client: Any = None
        self.epoch = 0
        self.delivered_through = 0
        self.wake_pending = False
        self.busy = threading.Event()
        self.policy: dict[str, Any] = {}

    # lifecycle ---------------------------------------------------------------------

    def acquire_lock(self) -> bool:
        self.project.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        handle = open(self.project.lock_path, "a+")
        deadline = time.monotonic() + LOCK_RETRY_S  # status probes hold a shared lock for microseconds
        while True:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.lock_handle = handle
                return True
            except OSError:
                if time.monotonic() > deadline:
                    handle.close()
                    return False
                time.sleep(0.05)

    def run(self) -> int:
        if not self.acquire_lock():
            print(f"{time.ctime()} another supervisor owns {self.project.id}; exiting", flush=True)
            return 0
        self.project.runtime_json.write_text(json.dumps({"pid": os.getpid(), "started": time.time(),
                                                         "release": str(RELEASE_ROOT)}) + "\n")
        self.epoch = self.ledger.begin_epoch(os.getpid())
        try:
            self._prepare()
            self._launch()
            self._loop()
        except FactoryError as exc:
            self._fail(exc.as_dict())
            return 1
        except Exception as exc:  # recorded, then the lock is released by process exit
            self._fail({"error": "supervisor_crash", "message": repr(exc)})
            raise
        finally:
            if self.client is not None:
                self._shutdown_coordinator()
        return 0

    def _fail(self, detail: dict[str, Any]) -> None:
        print(f"{time.ctime()} failed: {detail}", flush=True)
        self.ledger.update_runtime(mode="failed", event="runtime.failed", coordinator_pid=None, detail=detail)

    def _set(self, mode: str, event: str | None = None, **detail: Any) -> None:
        current = self.ledger.runtime()["detail"]
        self.ledger.update_runtime(mode=mode, event=event, heartbeat_at=time.time(), detail={**current, **detail})

    # startup -----------------------------------------------------------------------

    def _prepare(self) -> None:
        self._set("recovering", "runtime.recovering", phase="validating")
        self.policy = load_policy(self.project)
        version = release_version()
        if version.startswith("unreleased:") and not self.policy.get("allow_unreleased", False):
            raise Blocked(f"supervisor is running from an unreleased tree ({version}); run `factory install`")
        identity = omp_adapter.identify()
        stamp = compat.check_stamp(identity)
        self.policy_digest = hashlib.sha256(json.dumps(self.policy, sort_keys=True).encode()).hexdigest()[:12]
        self._set("recovering", phase="checkout", factory_version=version, omp_version=identity.version,
                  compat_stamp=stamp["tested_at"], policy_digest=self.policy_digest)
        self.base_sha = self._prepare_checkout()
        self._set("recovering", phase="reconcile", base_sha=self.base_sha)
        self.reconciliation = self._reconcile()

    def _git(self, *args: str, cwd: Path | None = None, timeout: float = 60) -> str:
        result = subprocess.run(["git", *args], cwd=cwd or self.project.checkout_dir, capture_output=True, text=True,
                                timeout=timeout)
        if result.returncode != 0:
            raise Blocked(f"git {' '.join(args)} failed: {result.stderr.strip()[:300]}")
        return result.stdout.strip()

    def _prepare_checkout(self) -> str:
        """Dedicated detached worktree; refuses to touch it if dirty (workers inherit dirty state)."""
        checkout = self.project.checkout_dir
        source = self.project.primary_checkout
        base_ref = self.project.base_ref
        remote = base_ref.split("/", 1)[0] if "/" in base_ref else None
        if remote and self.policy.get("fetch_base", True):
            try:
                self._git("fetch", "--quiet", remote, cwd=source, timeout=120)
            except (Blocked, subprocess.TimeoutExpired) as exc:
                print(f"{time.ctime()} fetch failed, using local {base_ref}: {exc}", flush=True)
        if not checkout.exists():
            self._git("worktree", "add", "--detach", str(checkout), base_ref, cwd=source)
        dirty = self._git("status", "--porcelain", "--untracked-files=all")
        if dirty:
            raise Blocked(f"coordinator checkout {checkout} has local changes; refusing to discard them",
                          dirty=dirty.splitlines()[:20])
        if not self._git("config", "user.email"):
            raise Blocked("git user.email is not configured for the coordinator checkout")
        self._git("checkout", "--quiet", "--detach", base_ref)
        return self._git("rev-parse", "HEAD")

    def _reconcile(self) -> dict[str, Any]:
        """Attempts from earlier epochs: import finished work, block unknowns, never relaunch blindly."""
        summary: dict[str, list[str]] = {"completed_unrecorded": [], "blocked_unknown": []}
        for attempt in self.ledger.list_attempts(ATTEMPT_LIVE):
            if attempt["epoch"] >= self.epoch:
                continue
            branch = f"omp/task/{attempt['worker_ref']}" if attempt["worker_ref"] else None
            head = None
            if branch:
                result = subprocess.run(["git", "rev-parse", "--verify", "--quiet", branch], cwd=self.project.checkout_dir,
                                        capture_output=True, text=True)
                head = result.stdout.strip() or None
            if head:
                self.ledger.update_attempt(attempt["id"], status="succeeded", actor="supervisor", epoch=None,
                                           branch=branch, head_sha=head,
                                           outcome={"reconciled": "retained branch found after restart"})
                summary["completed_unrecorded"].append(attempt["id"])
            else:
                self.ledger.update_attempt(attempt["id"], status="launch_unknown", actor="supervisor", epoch=None,
                                           outcome={"reconciled": "no retained output after restart"})
                _block_task(self.ledger, attempt["task_id"], f"attempt {attempt['id']} state unknown after restart")
                summary["blocked_unknown"].append(attempt["id"])
        return summary

    def _omp_env(self) -> dict[str, str]:
        env = {
            "FACTORY_ROLE": "coordinator",
            "FACTORY_PROJECT": self.project.id,
            "FACTORY_EPOCH": str(self.epoch),
            "FACTORY_ACTOR": COORDINATOR_ACTOR,
            "FACTORY_CONFIG_HOME": str(projects.config_home()),
            "FACTORY_STATE_HOME": str(projects.state_home()),
            "FACTORY_PYTHON": sys.executable,
        }
        env.update(self.policy.get("omp", {}).get("env", {}))
        return env

    def _launch(self) -> None:
        rpc = omp_adapter.load_rpc_module()
        self.project.sessions_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        resume = any(self.project.sessions_dir.glob("*.jsonl"))
        command = [
            omp_adapter.omp_executable(), "--mode", "rpc", "--no-ui", "--no-title",
            "--no-extensions", "-e", str(RELEASE_ROOT / "integrations" / "omp-factory" / "extension.ts"),
            "--config", str(RELEASE_ROOT / "tools" / "factory" / "omp-overlay.yml"),
            "--session-dir", str(self.project.sessions_dir),
            "--append-system-prompt", str(RELEASE_ROOT / ".factory" / "charter.md"),
            *(["--continue"] if resume else []),
            *self.policy.get("omp", {}).get("extra_args", []),
        ]
        self._set("starting", "runtime.coordinator_launching", phase="launch", resume=resume)
        self.client = rpc.RpcClient(command=command, cwd=self.project.checkout_dir, env=self._omp_env(),
                                    startup_timeout=90, request_timeout=60)
        self.client.on_event(self._on_event)
        self.client.start()
        state = self.client.request_raw("get_state")
        model = f"{state['model']['provider']}/{state['model']['id']}"
        expected = compat.profile_default_model(self._omp_env())
        if expected and expected != model:
            raise Blocked(f"coordinator resolved {model}, but the profile's default role is {expected}")
        self.ledger.update_runtime(coordinator_pid=self.client._process.pid, session_id=state["sessionId"],
                                   session_file=state.get("sessionFile"), model=model,
                                   event="runtime.coordinator_ready")
        desired = self.ledger.runtime()["desired_mode"]
        self._set("paused" if desired == "paused" else "running", "runtime.started", phase="ready")
        self.delivered_through = self.ledger.runtime()["event_cursor"]
        self._deliver(self._startup_message())

    def _startup_message(self) -> str:
        runtime = self.ledger.runtime()
        return (
            "[factory supervisor: automated startup notice, not a user instruction]\n"
            f"Epoch {self.epoch} started. Factory {runtime['detail'].get('factory_version')}, policy "
            f"{self.policy_digest}, base {self.base_sha[:12]}.\n"
            f"Restart reconciliation: {json.dumps(self.reconciliation)}.\n"
            f"Unprocessed ledger events after cursor {runtime['event_cursor']} through "
            f"{self.ledger.last_event_seq()}.\n"
            "Call factory_snapshot, act per the charter, then factory_checkpoint through the last event you "
            "handled. If nothing is actionable, reply `idle` and stop."
        )

    # event loop --------------------------------------------------------------------

    def _on_event(self, event: Any) -> None:
        kind = getattr(event, "type", None)
        if kind == "agent_start":
            self.busy.set()
        elif kind == "agent_end":
            self.busy.clear()
            self.wake_pending = False
        elif kind == "auto_retry_start":
            self.retrying = getattr(event, "error_message", "retrying")
        elif kind == "auto_retry_end":
            self.retrying = None

    def _deliver(self, message: str) -> None:
        # One call covers idle (starts a turn) and busy (queued follow-up, never a steer).
        self.client.prompt(message, streaming_behavior="followUp")
        self.wake_pending = True

    def _actionable(self, after: int) -> list[dict[str, Any]]:
        return [
            e for e in self.ledger.events_after(after, limit=500)
            if e["actor"] != COORDINATOR_ACTOR and not e["type"].startswith(QUIET_EVENT_PREFIXES)
        ]

    def _wake_message(self, events: list[dict[str, Any]], through: int) -> str:
        kinds: dict[str, int] = {}
        for e in events:
            kinds[e["type"]] = kinds.get(e["type"], 0) + 1
        tasks = sorted({e["task_id"] for e in events if e["task_id"]})[:20]
        summary = ", ".join(f"{n}x {k}" for k, n in sorted(kinds.items()))
        return (
            "[factory supervisor: automated notification, not a user instruction]\n"
            f"New ledger events {events[0]['seq']}..{through}: {summary}. Tasks: {', '.join(tasks) or 'none'}.\n"
            f"Call factory_snapshot, act per the charter, then checkpoint through {through}."
        )

    def _loop(self) -> None:
        last_beat = 0.0
        while True:
            process = self.client._process
            if process is None or process.poll() is not None:
                code = process.returncode if process is not None else None
                self.client = None
                _orphan_live_attempts(self.ledger, reason=f"coordinator exited unexpectedly ({code})")
                raise Blocked(f"coordinator exited unexpectedly with code {code}")
            runtime = self.ledger.runtime()
            desired = runtime["desired_mode"]
            if desired == "stopped":
                self._graceful_stop("stop requested")
                return
            if desired == "draining":
                if runtime["mode"] != "draining":
                    self._set("draining", "runtime.draining")
                if self._quiescent():
                    self._graceful_stop("drained")
                    return
            elif desired == "paused" and runtime["mode"] != "paused":
                self._set("paused", "runtime.paused")
            elif desired == "running" and runtime["mode"] != "running":
                self._set("running", "runtime.resumed")
            if desired == "running":
                self.delivered_through = max(self.delivered_through, runtime["event_cursor"])
                last = self.ledger.last_event_seq()
                if last > self.delivered_through and not self.wake_pending:
                    events = self._actionable(self.delivered_through)
                    if events:
                        self._deliver(self._wake_message(events, last))
                    self.delivered_through = last
            now = time.time()
            if now - last_beat >= HEARTBEAT_S:
                self.ledger.update_runtime(heartbeat_at=now, detail={**runtime["detail"], "retrying": self.retrying,
                                                                     "busy": self.busy.is_set()})
                last_beat = now
            time.sleep(POLL_S)

    def _quiescent(self) -> bool:
        state = self.client.request_raw("get_state")
        return bool(state.get("isSettled")) and not self.ledger.list_attempts(ATTEMPT_LIVE)

    # shutdown ----------------------------------------------------------------------

    def _graceful_stop(self, reason: str) -> None:
        self._set("stopping", "runtime.stopping", reason=reason)
        confirmed = self._shutdown_coordinator()
        live = [a for a in self.ledger.list_attempts(ATTEMPT_LIVE) if a["epoch"] == self.epoch]
        for attempt in live:
            if confirmed:
                self.ledger.update_attempt(attempt["id"], status="cancelled", actor="supervisor", epoch=None,
                                           outcome={"reason": reason, "cleanup": "confirmed"})
                _requeue_task(self.ledger, attempt["task_id"], f"{reason}; attempt {attempt['id']} cancelled")
            else:
                self.ledger.update_attempt(attempt["id"], status="orphaned", actor="supervisor", epoch=None,
                                           outcome={"reason": reason, "cleanup": "forced; not confirmed"})
                _block_task(self.ledger, attempt["task_id"], f"{reason}; worker cleanup not confirmed")
        self.ledger.update_runtime(mode="stopped", coordinator_pid=None, event="runtime.stopped",
                                   detail={**self.ledger.runtime()["detail"], "stop_reason": reason,
                                           "cleanup_confirmed": confirmed})

    def _shutdown_coordinator(self) -> bool:
        """Abort, cancel workers, close stdin and wait; force-kill the whole tree only as a last resort."""
        client, self.client = self.client, None
        if client is None or client._process is None:
            return True
        process = client._process
        try:
            client.abort()
            for agent in client.request_raw("get_subagents").get("subagents", []):
                if agent.get("status") in ("running", "queued"):
                    client.request_raw("cancel_subagent", subagentId=agent["id"])
        except Exception as exc:  # the process may already be gone
            print(f"{time.ctime()} abort during shutdown failed: {exc!r}", flush=True)
        tree = descendants(process.pid)
        try:
            process.stdin.close()
            process.wait(timeout=GRACEFUL_EXIT_S)
            confirmed = not [pid for pid in tree if _alive(pid)]
        except (OSError, subprocess.TimeoutExpired):
            confirmed = False
        if not confirmed:
            kill_tree(process.pid)
            for pid in tree:
                if _alive(pid):
                    os.kill(pid, signal.SIGKILL)
        client.stop()
        return confirmed


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def main() -> int:
    parser = argparse.ArgumentParser(description="factory supervisor daemon (started by `factory start`)")
    parser.add_argument("--project", required=True)
    args = parser.parse_args()
    project = projects.resolve(project_id=args.project)
    return Supervisor(project).run()


if __name__ == "__main__":
    sys.exit(main())
