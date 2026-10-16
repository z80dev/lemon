"""HTML rendering. Every ledger, CI, event and log string goes through `esc` (untrusted text)."""

from __future__ import annotations

import html
import json
from datetime import datetime, timezone
from typing import Any


def esc(value: Any) -> str:
    return html.escape("" if value is None else str(value), quote=True)


def stamp(epoch: Any) -> str:
    if not isinstance(epoch, (int, float)):
        return ""
    return datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def age(now: float, epoch: Any) -> str:
    if not isinstance(epoch, (int, float)):
        return "-"
    seconds = max(0, int(now - epoch))
    for unit, size in (("d", 86400), ("h", 3600), ("m", 60)):
        if seconds >= size:
            return f"{seconds // size}{unit} ago"
    return f"{seconds}s ago"


def _table(headers: tuple[str, ...], rows: list[list[str]], empty: str) -> str:
    if not rows:
        return f'<p class="muted">{esc(empty)}</p>'
    head = "".join(f"<th>{esc(h)}</th>" for h in headers)
    body = "".join("<tr>" + "".join(f"<td>{cell}</td>" for cell in row) + "</tr>" for row in rows)
    return f"<table><thead><tr>{head}</tr></thead><tbody>{body}</tbody></table>"


def _pill(value: Any) -> str:
    text = esc(value)
    return f'<span class="pill s-{"".join(c if c.isalnum() else "_" for c in str(value))}">{text}</span>'


def _pre(text: str | None, empty: str) -> str:
    return f"<pre>{esc(text)}</pre>" if text else f'<p class="muted">{esc(empty)}</p>'


def runtime_panel(state: dict[str, Any]) -> str:
    rt = state["runtime"]
    heartbeat = "-" if rt["heartbeat_age_s"] is None else f"{rt['heartbeat_age_s']}s"
    items = [
        ("state", _pill(rt["state"])), ("desired", esc(rt["desired_mode"])), ("epoch", esc(rt["epoch"])),
        ("supervisor pid", esc(rt["supervisor_pid"])), ("coordinator pid", esc(rt["coordinator_pid"])),
        ("model", esc(rt["model"])), ("heartbeat age", esc(heartbeat)),
        ("event cursor / last", f"{esc(rt['event_cursor'])} / {esc(state['last_event'])}"),
        ("unclean exit", esc("yes" if rt["unclean_previous_exit"] else "no")),
    ]
    cells = "".join(f"<div><dt>{esc(k)}</dt><dd>{v}</dd></div>" for k, v in items)
    detail = json.dumps(rt["detail"], sort_keys=True, default=str) if rt["detail"] else ""
    return (f"<section><h2>Runtime health</h2><dl class=\"grid\">{cells}</dl>"
            + (f"<pre>{esc(detail)}</pre>" if detail else "") + "</section>")


def tasks_panel(state: dict[str, Any]) -> str:
    now = state["generated_at"]
    columns = []
    for status, tasks in state["tasks"].items():
        count = state["counts"][status]
        items = "".join(
            f"<li>{_pill(t['priority'])} <b>{esc(t['id'])}</b> {esc(t['title'])}"
            f" <span class=\"muted\">{esc(age(now, t['updated_at']))}</span></li>"
            for t in tasks
        )
        shown = f' <span class="muted">(latest {len(tasks)})</span>' if count > len(tasks) else ""
        columns.append(f"<div class=\"col\"><h3>{esc(status)} <span class=\"count\">{count}</span>{shown}</h3>"
                       f"<ul>{items}</ul></div>")
    return f"<section><h2>Tasks by status</h2><div class=\"cols\">{''.join(columns)}</div></section>"


def attempts_panel(state: dict[str, Any]) -> str:
    now = state["generated_at"]
    rows = [[esc(a["id"]), esc(a["task_id"]), esc(a["task_title"]), esc(a["stage"]), _pill(a["status"]),
             esc(a["epoch"]), esc(a["worker_ref"]), esc(a["branch"]), esc(age(now, a["created_at"]))]
            for a in state["attempts"]]
    return "<section><h2>Live attempts</h2>" + _table(
        ("attempt", "task", "title", "stage", "status", "epoch", "worker", "branch", "started"), rows,
        "No live attempts.") + "</section>"


def integrations_panel(state: dict[str, Any]) -> str:
    now = state["generated_at"]
    blocks = []
    for entry in state["integrations"]:
        task, integ = entry["task"], entry["integration"]
        pr = f"#{integ['pr_number']}" if integ["pr_number"] else "-"
        facts = [("task", f"{esc(task['id'])} {esc(task['title'])} {_pill(task['status'])}"),
                 ("integration", _pill(integ["state"])), ("PR", esc(pr)), ("branch", esc(integ["branch"])),
                 ("head", esc((integ["head_sha"] or "")[:12])), ("CI run", esc(integ["ci_run_id"])),
                 ("merge", esc((integ["merge_sha"] or "")[:12])), ("repairs", esc(integ["repairs"])),
                 ("updated", esc(age(now, integ["updated_at"])))]
        cells = "".join(f"<div><dt>{esc(k)}</dt><dd>{v}</dd></div>" for k, v in facts)
        log = entry["ci_log"]
        log_html = (f"<details><summary>CI failure log tail: {esc(log['name'])} (untrusted text)</summary>"
                    f"{_pre(log['tail'], 'Log is empty.')}</details>") if log else ""
        blocks.append(f"<div class=\"card\"><dl class=\"grid\">{cells}</dl>{log_html}</div>")
    body = "".join(blocks) or '<p class="muted">No tasks in integration.</p>'
    return f"<section><h2>Integration PR / CI</h2>{body}</section>"


def events_panel(state: dict[str, Any]) -> str:
    rows = [[esc(e["seq"]), esc(stamp(e["created_at"])), esc(e["type"]), esc(e["task_id"]), esc(e["actor"]),
             f"<code>{esc(json.dumps(e['payload'], sort_keys=True, default=str))}</code>"]
            for e in state["events"]]
    return "<section><h2>Event feed</h2>" + _table(("seq", "time (UTC)", "type", "task", "actor", "payload"), rows,
                                                   "No events yet.") + "</section>"


def log_panel(state: dict[str, Any]) -> str:
    return ("<section><h2>Supervisor log tail</h2>"
            + _pre(state["supervisor_log"], "No supervisor log yet.") + "</section>")


def fragment(state: dict[str, Any]) -> str:
    head = (f"<header><h1>{esc(state['project'])} <span class=\"muted\">{esc(state['repository'])}</span></h1>"
            f"<span class=\"muted\">read-only &middot; updated {esc(stamp(state['generated_at']))} UTC</span></header>")
    return head + "".join(panel(state) for panel in (
        runtime_panel, tasks_panel, attempts_panel, integrations_panel, events_panel, log_panel))


def error_fragment(message: str) -> str:
    return f'<section class="error"><h2>Ledger read failed</h2><pre>{esc(message)}</pre></section>'


STYLE = """
body{font:13px/1.45 ui-monospace,Menlo,monospace;margin:0;padding:16px;background:#14161a;color:#d7dae0}
header{display:flex;justify-content:space-between;align-items:baseline;margin-bottom:8px}
h1{font-size:18px;margin:0}h2{font-size:14px;border-bottom:1px solid #333;padding-bottom:4px;margin:20px 0 8px}
h3{font-size:12px;margin:0 0 4px}.muted{color:#8a8f98}.count{background:#2a2e36;border-radius:8px;padding:0 6px}
table{border-collapse:collapse;width:100%}th,td{text-align:left;padding:3px 8px;border-bottom:1px solid #262a31;vertical-align:top}
pre{background:#0d0e11;padding:8px;overflow:auto;max-height:340px;white-space:pre-wrap;word-break:break-all}
code{word-break:break-all}.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(170px,1fr));gap:6px;margin:0}
.grid div{background:#1c1f25;padding:6px 8px;border-radius:4px}dt{color:#8a8f98;font-size:11px}dd{margin:0;word-break:break-all}
.cols{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:10px}
.col{background:#1c1f25;padding:8px;border-radius:4px}.col ul{list-style:none;margin:0;padding:0}.col li{margin:3px 0}
.card{background:#1c1f25;padding:8px;border-radius:4px;margin-bottom:8px}
.pill{padding:0 6px;border-radius:8px;background:#2a2e36}
.s-running,.s-ci_green,.s-succeeded,.s-merged{background:#1f4d2b}
.s-stopped,.s-blocked,.s-failed,.s-unresponsive,.s-urgent,.s-orphaned{background:#6b2424}
.s-paused,.s-draining,.s-rate_limited,.s-high{background:#6b5a1f}.error{color:#ff8a8a}
"""

# Polls the same read path the first paint used; the server's HTML is already escaped and is swapped in whole.
SCRIPT = """
const root=document.getElementById('root');
async function refresh(){try{const r=await fetch('/fragment',{cache:'no-store'});
if(r.ok){root.innerHTML=await r.text();}}catch(e){}}
setInterval(refresh,2000);
"""


def page(state_fragment: str, nonce: str) -> str:
    return ("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>Factory dashboard</title>"
            f"<style>{STYLE}</style></head><body><div id=\"root\">{state_fragment}</div>"
            f"<script nonce=\"{esc(nonce)}\">{SCRIPT}</script></body></html>")
