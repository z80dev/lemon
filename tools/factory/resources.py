#!/usr/bin/env python3
"""Host-local heavy-check semaphore. Kernel locks plus live-owner fencing, never TTL stealing.

Slot files are permanent: unlinking a locked inode would create a second lock.
A command inherits its slot fd, and its process group is durably recorded before
it may execute. Even if the runner dies and a child closes inherited fds, a live
command group fences reuse. Unknown liveness fails closed.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import math
import os
import signal
import subprocess
import sys
import time
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Any

import project as projects
from store import FactoryError, Invalid

DEFAULT_TIMEOUT_S = 1800.0
POLL_S = 0.1


class LeaseTimeout(FactoryError):
    code = "heavy_check_timeout"
    exit_code = 75


def _duration(value: Any) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError):
        raise Invalid("heavy-check timeout must be a finite nonnegative number") from None
    if not math.isfinite(number) or number < 0:
        raise Invalid("heavy-check timeout must be a finite nonnegative number")
    return number


def capacity(policy: dict[str, Any]) -> int:
    slots = policy.get("heavy_beam_slots", 1)
    if isinstance(slots, bool) or not isinstance(slots, int) or slots < 1:
        raise Invalid("policy heavy_beam_slots must be a positive integer")
    return slots


def _identity(pid: int) -> dict[str, Any] | None:
    """None proves death; inaccessible/ambiguous processes are retained as unknown."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return None
    except PermissionError:
        return {"pid": pid, "unknown": True}
    try:
        result = subprocess.run(["ps", "-p", str(pid), "-o", "stat=,lstart="],
                                capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return {"pid": pid, "unknown": True}
    fields = result.stdout.strip().split(None, 1)
    if result.returncode == 0 and len(fields) == 2:
        if fields[0].startswith("Z"):
            return None
        return {"pid": pid, "started": fields[1]}
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return None
    except PermissionError:
        pass
    return {"pid": pid, "unknown": True}


def _owner_live(owner: dict[str, Any] | None) -> bool:
    if not owner:
        return False
    current = _identity(owner["pid"])
    if current is None:
        return False
    # A changed start time proves the recorded owner died (PID reuse).
    return bool(current.get("unknown") or owner.get("unknown") or current == owner)


def _group_live(pgid: int | None) -> bool:
    if pgid is None:
        return False
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    try:
        result = subprocess.run(["ps", "-A", "-o", "pgid=,stat="], capture_output=True, text=True, timeout=5)
        if result.returncode != 0:
            return True
        members = [row.split()[1] for row in result.stdout.splitlines()
                   if len(row.split()) == 2 and row.split()[0] == str(pgid)]
        if members:
            return any(not state.startswith("Z") for state in members)
    except (OSError, subprocess.TimeoutExpired):
        return True
    # Never infer death from a partial/empty ps listing alone.
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass
    return True


def _metadata(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text())
        if not isinstance(data, dict) or data.get("state") not in ("active", "released", "reclaimed"):
            raise ValueError("invalid state")
        acquired = data.get("acquired_at", 0)
        if not isinstance(acquired, (int, float)) or not math.isfinite(acquired):
            raise ValueError("invalid acquisition time")
        if data["state"] == "active":
            owner = data["owner"]
            if not isinstance(owner, dict) or not isinstance(owner.get("pid"), int) or owner["pid"] <= 0:
                raise ValueError("invalid owner")
            if not isinstance(owner.get("started"), str) and owner.get("unknown") is not True:
                raise ValueError("missing owner identity")
            if data.get("pgid") is not None and (not isinstance(data["pgid"], int) or data["pgid"] <= 0):
                raise ValueError("invalid command group")
        return data
    except FileNotFoundError:
        return {}
    except (OSError, ValueError, KeyError, TypeError):
        return {"state": "unknown", "diagnostic": "unreadable lease metadata; refusing unsafe reclamation"}


def _save(path: Path, data: dict[str, Any]) -> None:
    temporary = path.with_suffix(f".tmp-{os.getpid()}")
    try:
        with open(temporary, "w") as handle:
            json.dump(data, handle, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def _blockers(data: dict[str, Any]) -> list[str]:
    if data.get("state") == "unknown":
        return ["unknown_metadata"]
    if data.get("state") != "active":
        return []
    blocked = []
    if _owner_live(data["owner"]):
        blocked.append("live_or_unknown_owner")
    if _group_live(data.get("pgid")):
        blocked.append("live_or_unknown_command_group")
    return blocked


class HeavyChecks:
    def __init__(self, state_dir: Path, slots: int) -> None:
        self.directory = state_dir / "resources" / "heavy-beam"
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.slots = capacity({"heavy_beam_slots": slots})

    @contextmanager
    def _admission(self, deadline: float):
        with open(self.directory / "admission.lock", "a+") as handle:
            while True:
                try:
                    fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise LeaseTimeout("timed out waiting for heavy-check admission mutex",
                                           resource="heavy-beam", capacity=self.slots)
                    time.sleep(min(POLL_S, max(0, deadline - time.monotonic())))
            try:
                yield
            finally:
                fcntl.flock(handle, fcntl.LOCK_UN)

    def _paths(self) -> list[Path]:
        existing = list(self.directory.glob("slot-*.lock"))
        return sorted(set(existing + [self.directory / f"slot-{n:04d}.lock" for n in range(self.slots)]))

    def _scan(self) -> tuple[list[dict[str, Any]], list[tuple[Any, Path, dict[str, Any]]]]:
        busy, free = [], []
        for path in self._paths():
            handle = open(path, "a+")
            meta = _metadata(path.with_suffix(".json"))
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                handle.close()
                reasons = ["kernel_lock_held"]
            else:
                reasons = _blockers(meta)
                if not reasons:
                    free.append((handle, path, meta))
                    continue
                handle.close()
            age = max(0, time.time() - meta.get("acquired_at", time.time()))
            busy.append({"slot": path.stem, "blocked_by": reasons, "owner": meta.get("owner"),
                         "pgid": meta.get("pgid"), "epoch": meta.get("epoch"), "age_s": round(age, 1),
                         "stale": age >= DEFAULT_TIMEOUT_S, "diagnostic": meta.get("diagnostic")})
        return busy, free

    def acquire(self, timeout: float) -> "Lease":
        timeout = _duration(timeout)
        deadline = time.monotonic() + timeout
        while True:
            with self._admission(deadline):
                busy, free = self._scan()
                selected = free.pop(0) if len(busy) < self.slots and free else None
                for handle, _, _ in free:
                    handle.close()
                if selected is not None:
                    handle, path, previous = selected
                    data = {"state": "active", "owner": _identity(os.getpid()), "pgid": None,
                            "token": uuid.uuid4().hex, "acquired_at": time.time(),
                            "epoch": os.environ.get("FACTORY_EPOCH"),
                            "reclaimed_previous_owner": previous.get("owner") if previous.get("state") == "active" else None}
                    try:
                        _save(path.with_suffix(".json"), data)
                    except BaseException:
                        handle.close()
                        raise
                    return Lease(handle, path, data)
            if time.monotonic() >= deadline:
                raise LeaseTimeout(f"timed out after {timeout:g}s waiting for heavy-beam lease; live owners are never evicted",
                                   resource="heavy-beam", capacity=self.slots, timeout_s=timeout, holders=busy)
            time.sleep(min(POLL_S, max(0, deadline - time.monotonic())))

    def cleanup(self, timeout: float = 1.0) -> list[str]:
        """Clear only stale records whose kernel lock is free AND all recorded owners are dead."""
        reclaimed = []
        with self._admission(time.monotonic() + _duration(timeout)):
            _, free = self._scan()
            try:
                for _, path, data in free:
                    if data.get("state") == "active":
                        _save(path.with_suffix(".json"), {**data, "state": "reclaimed", "reclaimed_at": time.time()})
                        reclaimed.append(path.stem)
            finally:
                for handle, _, _ in free:
                    handle.close()
        return reclaimed


class Lease:
    def __init__(self, handle: Any, path: Path, data: dict[str, Any]) -> None:
        self.handle, self.path, self.data = handle, path, data

    def close(self) -> None:
        # Closing a runner never marks a surviving build released.
        try:
            if not _group_live(self.data.get("pgid")):
                _save(self.path.with_suffix(".json"), {**self.data, "state": "released", "released_at": time.time()})
        finally:
            # Do not LOCK_UN: inherited copies must continue holding the same flock.
            self.handle.close()

    def run(self, command: list[str], execution_timeout: float | None = None) -> int:
        if execution_timeout is not None:
            execution_timeout = _duration(execution_timeout)
        ready_r, ready_w = os.pipe()
        go_r, go_w = os.pipe()
        try:
            pid = os.fork()
        except BaseException:
            for fd in (ready_r, ready_w, go_r, go_w):
                os.close(fd)
            raise
        if pid == 0:
            try:
                os.close(ready_r)
                os.close(go_w)
                os.setsid()
                os.set_inheritable(self.handle.fileno(), True)
                os.write(ready_w, b"1")
                os.close(ready_w)
                permitted = os.read(go_r, 1)
                os.close(go_r)
                if permitted != b"1":
                    os._exit(125)
                env = {**os.environ, "FACTORY_HEAVY_LEASE_FD": str(self.handle.fileno()),
                       "FACTORY_HEAVY_LEASE_TOKEN": self.data["token"]}
                os.execvpe(command[0], command, env)
            except BaseException as exc:
                os.write(2, f"factory heavy check: cannot execute command: {exc}\n".encode())
                os._exit(127)
        os.close(ready_w)
        os.close(go_r)
        previous_handlers = {}
        try:
            if os.read(ready_r, 1) != b"1":
                raise Invalid("heavy-check child exited before establishing its process group")
            self.data["pgid"] = pid
            _save(self.path.with_suffix(".json"), self.data)

            def forward(signum, _frame):
                try:
                    os.killpg(pid, signum)
                except ProcessLookupError:
                    pass

            for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
                previous_handlers[signum] = signal.signal(signum, forward)
            os.write(go_w, b"1")
            os.close(go_w)
            go_w = -1
            if execution_timeout is None:
                _, status = os.waitpid(pid, 0)
            else:
                deadline = time.monotonic() + execution_timeout
                reaped = 0
                while True:
                    if not reaped:
                        reaped, status = os.waitpid(pid, os.WNOHANG)
                    if reaped and not _group_live(pid):
                        break
                    if time.monotonic() >= deadline:
                        # Keep both the runner and its lease alive until the entire
                        # command group is dead, not merely the direct child.
                        forward(signal.SIGTERM, None)
                        grace = time.monotonic() + 1.0
                        while _group_live(pid) and time.monotonic() < grace:
                            time.sleep(POLL_S)
                        if _group_live(pid):
                            forward(signal.SIGKILL, None)
                        if not reaped:
                            os.waitpid(pid, 0)
                        while _group_live(pid):
                            time.sleep(POLL_S)
                        raise LeaseTimeout(
                            f"heavy-check command exceeded execution timeout {execution_timeout:g}s; command group terminated",
                            resource="heavy-beam", execution_timeout_s=execution_timeout, pgid=pid)
                    time.sleep(POLL_S)
            code = os.waitstatus_to_exitcode(status)
            return 128 - code if code < 0 else code
        finally:
            os.close(ready_r)
            if go_w != -1:
                os.close(go_w)
            for signum, handler in previous_handlers.items():
                signal.signal(signum, handler)


def validate_inherited(pool: HeavyChecks) -> None:
    """A marker alone cannot skip admission: require the matching inherited locked inode."""
    try:
        fd = int(os.environ["FACTORY_HEAVY_LEASE_FD"])
        stat = os.fstat(fd)
        token = os.environ["FACTORY_HEAVY_LEASE_TOKEN"]
        for path in pool._paths():
            candidate = path.stat()
            if (candidate.st_dev, candidate.st_ino) != (stat.st_dev, stat.st_ino):
                continue
            data = _metadata(path.with_suffix(".json"))
            if data.get("state") != "active" or data.get("token") != token or data.get("pgid") != os.getpgrp():
                break
            # A separate open-file description must be unable to lock the inode.
            with open(path, "a+") as probe:
                try:
                    fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    return
            break
    except (KeyError, OSError, ValueError):
        pass
    raise Invalid("invalid inherited heavy-check lease (closed fd, stale token, or different process group)")


def _pool() -> HeavyChecks:
    if not os.environ.get("FACTORY_PROJECT") or not os.environ.get("FACTORY_STATE_HOME"):
        raise Invalid("factory heavy checks require FACTORY_PROJECT and explicit FACTORY_STATE_HOME")
    project = projects.resolve(project_id=os.environ["FACTORY_PROJECT"])
    try:
        policy = json.loads(project.policy_path.read_text())
    except (OSError, ValueError) as exc:
        raise Invalid(f"cannot read approved heavy-check policy: {exc}") from None
    return HeavyChecks(project.state_dir, capacity(policy))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="operation", required=True)
    run = sub.add_parser("run", help="acquire the heavy lease and run a command; no-op outside the factory")
    run.add_argument("--timeout", default=os.environ.get("FACTORY_HEAVY_TIMEOUT_S", DEFAULT_TIMEOUT_S))
    run.add_argument("--execution-timeout", type=_duration,
                     help="terminate and reap the command group after this many seconds")
    run.add_argument("command", nargs=argparse.REMAINDER)
    sub.add_parser("validate", help="validate an inherited lease without acquiring another slot")
    args = parser.parse_args()
    try:
        if args.operation == "validate":
            validate_inherited(_pool())
            return 0
        command = args.command[1:] if args.command[:1] == ["--"] else args.command
        if not command:
            raise Invalid("heavy-check run requires a command after --")
        if not os.environ.get("FACTORY_PROJECT"):
            os.execvp(command[0], command)
        pool = _pool()
        if os.environ.get("FACTORY_HEAVY_LEASE_FD") or os.environ.get("FACTORY_HEAVY_LEASE_TOKEN"):
            validate_inherited(pool)
            if args.execution_timeout is not None:
                raise Invalid("execution timeout requires ownership of the heavy-check runner")
            os.execvp(command[0], command)
        lease = pool.acquire(_duration(args.timeout))
        try:
            return lease.run(command, execution_timeout=args.execution_timeout)
        finally:
            lease.close()
    except FactoryError as exc:
        print(json.dumps(exc.as_dict(), sort_keys=True), file=sys.stderr)
        return exc.exit_code
    except OSError as exc:
        print(json.dumps({"ok": False, "error": "heavy_check_io", "message": str(exc)}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
