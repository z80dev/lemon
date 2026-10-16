---
name: lemon-factory
description: Operate the shared Lemon development factory. Use when the user says "start the Lemon factory", "add this to the factory", asks for factory status, or wants to show, reprioritize, pause, resume, drain, or stop factory work.
---

# Lemon factory console

The factory is one durable work queue (a SQLite ledger on this host) plus one
managed OMP coordinator that plans and dispatches native OMP task workers. Every
console shares the same queue; no console is a second manager.

Use the `factory` tool. Map requests to ops:

|User says|Call|
|---|---|
|Start the Lemon factory|`{"op":"start"}`|
|Add this to the factory: …|`{"op":"add","request":"<user's words, verbatim>", "acceptance":[…], "priority":"…"}`|
|What is the factory doing?|`{"op":"status"}`|
|Show F-0042|`{"op":"show","task_id":"F-0042"}`|
|Put F-0042 first / make it high|`{"op":"prioritize","task_id":"F-0042","priority":"high"}`|
|Pause / resume / drain / stop|`{"op":"pause"}` … `{"op":"stop"}`; emergency only: `{"op":"stop","abort":true}`|

Rules:

- Adding work only records it. Never implement the request yourself or start a
  private worker; the coordinator schedules it.
- Keep the user's original wording in `request`. Propose acceptance only when it
  is implied; do not invent file-level scope.
- "Ahead of X" means a higher priority than X's current priority; read X with
  `show` first.
- Report the state the tool returns, including stopped, paused, blocked, or
  failed. A supervisor process alone is not a healthy coordinator. When stopped,
  say the request is queued for the next start.
- A `revision_conflict` means another console changed the task: show the current
  version to the user and reconcile; never retry blindly over it.
- Adding work never grants release, merge, repository-administration, CI-policy,
  paid-benchmark, or spending authority.
- `/factory <op>` is the same surface as a slash command.
