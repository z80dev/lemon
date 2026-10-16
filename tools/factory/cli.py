#!/usr/bin/env python3
"""`factory` command line: the single implementation behind OMP tools and shell use.

Every command prints one JSON object on stdout. Exit codes: 0 ok, 2 invalid,
3 conflict, 4 not found, 5 admission refused, 6 not registered/prerequisite.
"""

from __future__ import annotations

import argparse
import getpass
import json
import os
import socket
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

import project as projects
from store import ATTEMPT_LIVE, PRIORITIES, STATUSES, AdmissionRefused, FactoryError, Invalid, Ledger

SNAPSHOT_LIMIT = 12
RELEASE_ROOT = Path(__file__).resolve().parents[2]
SLOT_POLICY = {"implement": "implementation_slots", "review": "review_slots", "repair": "reserved_repair_slots"}


def _actor(args: argparse.Namespace) -> str:
    return args.actor or os.environ.get("FACTORY_ACTOR") or f"cli:{getpass.getuser()}@{socket.gethostname()}"


def _project(args: argparse.Namespace) -> projects.Project:
    return projects.resolve(Path.cwd(), args.project or os.environ.get("FACTORY_PROJECT"))


def _counts(tasks: list[dict[str, Any]]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for task in tasks:
        counts[task["status"]] = counts.get(task["status"], 0) + 1
    return counts


def _brief(task: dict[str, Any]) -> dict[str, Any]:
    return {k: task[k] for k in ("id", "revision", "status", "priority", "title", "dependencies")}


def status_payload(project: projects.Project) -> dict[str, Any]:
    import supervisor

    ledger = project.ledger()
    tasks = ledger.list_tasks()
    queued = [t for t in tasks if t["status"] == "queued"]
    return {
        "ok": True,
        "project": project.id,
        "runtime": supervisor.health(project, ledger),
        "work": _counts(tasks),
        "next": [_brief(t) for t in queued[:3]],
        "last_event": ledger.last_event_seq(),
    }


def snapshot_payload(project: projects.Project) -> dict[str, Any]:
    """Bounded coordinator context: never whole transcripts or every task."""
    import supervisor

    ledger = project.ledger()
    runtime = ledger.runtime()
    tasks = ledger.list_tasks()
    by_status = {s: [t for t in tasks if t["status"] == s] for s in STATUSES}
    events = ledger.events_after(runtime["event_cursor"], limit=50)
    return {
        "ok": True,
        "project": project.id,
        "runtime": supervisor.health(project, ledger),
        "policy": supervisor.load_policy(project),
        "work": _counts(tasks),
        "inbox": [{**_brief(t), "raw_request": t["raw_request"][:600]} for t in by_status["inbox"][:SNAPSHOT_LIMIT]],
        "queued": [_brief(t) for t in by_status["queued"][:SNAPSHOT_LIMIT]],
        "active": [_brief(t) for t in by_status["active"]],
        "ready": [_brief(t) for t in by_status["ready"]],
        "integrating": [
            {**_brief(t), "integration": ledger.get_integration(t["id"])}
            for t in by_status["verifying"] + by_status["awaiting_merge"] + by_status["landed_pending_confirmation"]
        ],
        "blocked": [_brief(t) for t in by_status["blocked"] + by_status["needs_input"]][:SNAPSHOT_LIMIT],
        "live_attempts": ledger.list_attempts(ATTEMPT_LIVE),
        "unprocessed_events": [
            {"seq": e["seq"], "type": e["type"], "task_id": e["task_id"], "actor": e["actor"]} for e in events
        ],
        "event_cursor": runtime["event_cursor"],
    }


def _edit_changes(args: argparse.Namespace) -> dict[str, Any]:
    changes: dict[str, Any] = json.loads(args.set_json) if args.set_json else {}
    for field in ("title", "goal", "priority", "risk", "notes"):
        value = getattr(args, field, None)
        if value is not None:
            changes[field] = value
    if args.acceptance:
        changes["acceptance"] = args.acceptance
    return changes


def seed(ledger: Ledger, path: Path, *, actor: str) -> dict[str, Any]:
    """Import named approved plan sections; deterministic keys make re-imports idempotent.

    A packet may carry `status` (`needs_input` or `blocked`) with `reason`: decisions and
    out-of-reach work are recorded honestly instead of being dispatched.
    """
    data = json.loads(path.read_text())
    document = data["source"]["document"]
    ids: dict[str, str] = {}
    imported = []
    for packet in data["packets"]:
        task, replayed = ledger.add_task(
            {"request": packet["request"], "title": packet["title"], "priority": packet["priority"],
             "acceptance": packet.get("acceptance", []), "source": {**data["source"], "section": packet["key"]}},
            actor=actor, request_key=f"seed:{document}:{packet['key']}",
        )
        if not replayed and packet.get("status") in ("needs_input", "blocked"):
            task = ledger.transition(task["id"], task["revision"], packet["status"], actor=actor,
                                     reason=packet["reason"], request_key=f"seed-status:{document}:{packet['key']}")
        ids[packet["key"]] = task["id"]
        imported.append({"key": packet["key"], "id": task["id"], "status": task["status"], "replayed": replayed})
    for packet in data["packets"]:
        deps = [ids[key] for key in packet.get("depends_on", [])]
        task = ledger.get_task(ids[packet["key"]])
        if deps and task["dependencies"] != deps:
            ledger.edit_task(task["id"], task["revision"], {"dependencies": deps}, actor=actor,
                             request_key=f"seed-deps:{document}:{packet['key']}")
    return {"ok": True, "imported": imported}


def run(args: argparse.Namespace) -> dict[str, Any]:
    cmd = args.command
    if cmd == "register":
        project = projects.register(Path.cwd())
        project.ledger()
        return {"ok": True, "project": project.id, "repository": project.repository, "checkouts": project.checkouts,
                "state_dir": str(project.state_dir), "policy_approved": project.policy_path.exists(),
                "policy_path": str(project.policy_path)}
    if cmd == "compat":
        import compat

        return compat.run(skip_profile=args.skip_profile)
    if cmd == "install":
        import install

        return install.install(Path.cwd(), args.ref)

    project = _project(args)
    ledger: Ledger = project.ledger()
    actor = _actor(args)

    if cmd == "add":
        request = {"request": " ".join(args.request), "priority": args.priority, "title": args.title,
                   "acceptance": args.acceptance or [], "parent_id": args.parent,
                   "source": json.loads(args.source_json) if args.source_json else {"kind": "user_request",
                                                                                     "actor": actor}}
        task, replayed = ledger.add_task(request, actor=actor, request_key=args.request_key)
        import supervisor

        runtime = supervisor.health(project, ledger)
        note = None if runtime["state"] != "stopped" else "Factory is stopped; queued for the next start."
        return {"ok": True, "replayed": replayed, "task": task, "runtime_state": runtime["state"], "note": note}
    if cmd == "show":
        return {"ok": True, "task": ledger.get_task(args.task_id), "attempts": ledger.list_attempts(task_id=args.task_id)}
    if cmd == "list":
        statuses = tuple(args.status.split(",")) if args.status else None
        return {"ok": True, "tasks": [_brief(t) for t in ledger.list_tasks(statuses)]}
    if cmd == "status":
        return status_payload(project)
    if cmd == "snapshot":
        return snapshot_payload(project)
    if cmd == "events":
        return {"ok": True, "events": ledger.events_after(args.after, args.limit)}
    if cmd == "edit":
        task = ledger.edit_task(args.task_id, args.expected_revision, _edit_changes(args), actor=actor,
                                request_key=args.request_key)
        return {"ok": True, "task": task}
    if cmd == "prioritize":
        task = ledger.edit_task(args.task_id, args.expected_revision, {"priority": args.priority}, actor=actor,
                                request_key=args.request_key)
        return {"ok": True, "task": task}
    if cmd == "transition":
        task = ledger.transition(args.task_id, args.expected_revision, args.to, actor=actor, reason=args.reason,
                                 request_key=args.request_key, disposition=args.disposition)
        return {"ok": True, "task": task}
    if cmd == "reserve":
        import supervisor

        policy = supervisor.load_policy(project)
        slots = policy.get(SLOT_POLICY.get(args.stage, ""), 0)
        if args.stage == "implement" and "max_ready_backlog" in policy:
            backlog = ledger.list_tasks(("ready", "verifying", "awaiting_merge"))
            if len(backlog) >= policy["max_ready_backlog"]:
                raise AdmissionRefused(f"{len(backlog)} tasks await review/integration; policy allows "
                                       f"{policy['max_ready_backlog']} before new implementations")
        base_sha = supervisor.verified_base(project, ledger)
        attempt = ledger.reserve_attempt(args.task_id, args.expected_revision, args.stage, epoch=args.epoch,
                                         actor=actor, request_key=args.request_key, base_sha=base_sha,
                                         max_live=int(slots), max_per_day=policy.get("max_attempts_per_day"))
        return {"ok": True, "attempt": attempt}
    if cmd == "attempt":
        attempt = ledger.update_attempt(args.attempt_id, status=args.status, actor=actor, epoch=args.epoch,
                                        request_key=args.request_key, worker_ref=args.worker_ref,
                                        head_sha=args.head_sha, branch=args.branch,
                                        outcome=json.loads(args.outcome_json) if args.outcome_json else None)
        return {"ok": True, "attempt": attempt}
    if cmd == "checkpoint":
        return {"ok": True, "event_cursor": ledger.checkpoint(args.seq, epoch=args.epoch)}
    if cmd == "seed":
        return seed(ledger, Path(args.file), actor=actor)
    if cmd == "backup":
        ledger.backup(Path(args.destination))
        return {"ok": True, "backup": args.destination}

    import supervisor

    if cmd == "ensure":
        return supervisor.ensure(project, actor=actor, wait=args.wait)
    if cmd == "autostart":
        import install

        return install.autostart(project, enable=not args.disable, interval_s=args.interval)
    if cmd == "start":
        started = supervisor.start(project, actor=actor, wait=args.wait)
        status = status_payload(project)
        # Report the queue the console must describe, not a remembered one.
        return {**started, "work": status["work"], "next": status["next"]}
    if cmd in ("pause", "resume", "drain"):
        return supervisor.request_mode(project, {"pause": "paused", "resume": "running", "drain": "draining"}[cmd],
                                       actor=actor)
    if cmd == "stop":
        return supervisor.stop(project, actor=actor, abort=args.abort, wait=args.wait)
    raise Invalid(f"unknown command {cmd}")


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="factory", description=__doc__)
    p.add_argument("--project", help="registered project ID (default: resolve from the current checkout)")
    p.add_argument("--actor", help="attribution recorded on events")
    sub = p.add_subparsers(dest="command", required=True)

    sub.add_parser("register", help="register this checkout under its .factory/project.json identity")

    add = sub.add_parser("add", help="durably add a request to the queue")
    add.add_argument("request", nargs="+")
    add.add_argument("--priority", choices=PRIORITIES, default="normal")
    add.add_argument("--title")
    add.add_argument("--acceptance", action="append", help="proposed acceptance criterion (repeatable)")
    add.add_argument("--parent")
    add.add_argument("--source-json")
    add.add_argument("--request-key", help="idempotency key: replays return the same task")

    compat_cmd = sub.add_parser("compat", help="run the OMP seam suite and stamp this OMP build as compatible")
    compat_cmd.add_argument("--skip-profile", action="store_true", help="skip the real-profile routing check")
    inst = sub.add_parser("install", help="install a committed factory version and link the OMP extension")
    inst.add_argument("--ref", default="HEAD")

    show = sub.add_parser("show")
    show.add_argument("task_id")
    lst = sub.add_parser("list")
    lst.add_argument("--status", help="comma-separated statuses")
    sub.add_parser("status")
    sub.add_parser("snapshot", help="bounded coordinator snapshot")
    events = sub.add_parser("events")
    events.add_argument("--after", type=int, default=0)
    events.add_argument("--limit", type=int, default=100)

    edit = sub.add_parser("edit", help="edit a task at an expected revision")
    edit.add_argument("task_id")
    edit.add_argument("--expected-revision", type=int, required=True)
    for field in ("title", "goal", "risk", "notes"):
        edit.add_argument(f"--{field}")
    edit.add_argument("--priority", choices=PRIORITIES)
    edit.add_argument("--acceptance", action="append")
    edit.add_argument("--set-json", help="JSON object of editable fields")
    edit.add_argument("--request-key")

    prio = sub.add_parser("prioritize")
    prio.add_argument("task_id")
    prio.add_argument("priority", choices=PRIORITIES)
    prio.add_argument("--expected-revision", type=int)
    prio.add_argument("--request-key")

    tr = sub.add_parser("transition")
    tr.add_argument("task_id")
    tr.add_argument("to", choices=STATUSES)
    tr.add_argument("--expected-revision", type=int, required=True)
    tr.add_argument("--reason", required=True)
    tr.add_argument("--disposition")
    tr.add_argument("--request-key")

    res = sub.add_parser("reserve", help="coordinator: admission-checked attempt reservation")
    res.add_argument("task_id")
    res.add_argument("--expected-revision", type=int, required=True)
    res.add_argument("--stage", default="implement")
    res.add_argument("--epoch", type=int, required=True)
    res.add_argument("--request-key")

    att = sub.add_parser("attempt", help="coordinator: record an attempt outcome")
    att.add_argument("attempt_id")
    att.add_argument("--status", required=True)
    att.add_argument("--epoch", type=int)
    att.add_argument("--worker-ref")
    att.add_argument("--branch")
    att.add_argument("--head-sha")
    att.add_argument("--outcome-json")
    att.add_argument("--request-key")

    cp = sub.add_parser("checkpoint", help="coordinator: mark events processed through SEQ")
    cp.add_argument("seq", type=int)
    cp.add_argument("--epoch", type=int, required=True)

    sd = sub.add_parser("seed", help="import approved plan packets once (replays are no-ops)")
    sd.add_argument("--file", default=str(RELEASE_ROOT / ".factory" / "seed-work.json"))

    bk = sub.add_parser("backup")
    bk.add_argument("destination")

    start = sub.add_parser("start")
    start.add_argument("--wait", type=float, default=90.0)
    for name in ("pause", "resume", "drain"):
        sub.add_parser(name)
    stop = sub.add_parser("stop")
    stop.add_argument("--abort", action="store_true", help="emergency: kill immediately, record uncertainty")
    stop.add_argument("--wait", type=float, default=90.0)
    ens = sub.add_parser("ensure", help="watchdog: restart the factory if it should be running and is not")
    ens.add_argument("--wait", type=float, default=600.0)
    auto = sub.add_parser("autostart", help="install (or --disable) a launchd watchdog running `ensure`")
    auto.add_argument("--disable", action="store_true")
    auto.add_argument("--interval", type=int, default=300)
    return p


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        result = run(args)
    except FactoryError as exc:
        print(json.dumps(exc.as_dict(), default=str))
        return exc.exit_code
    print(json.dumps(result, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
