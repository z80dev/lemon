# LemonAutomation contributor guide

This app owns cron execution/delivery, persistent goal loops, kanban dispatch and
portable blueprint activation. It composes router runs and existing domain
stores, not a second agent engine. See [README](README.md) and
[reminders and heartbeats](../../docs/user-guide/reminders-and-heartbeats.md).

## Submission and completion

- All submit-and-wait paths use `RunCompletionWaiter`: allocate a fixed run ID,
  claim ownership, subscribe before submission, and clean up after terminal wait.
  A returned different run ID is an error, never a late re-subscription.
- Unknown submission/abort outcomes are not retry-safe. Retain the original ID
  and reconciliation ownership; do not report a definite failed/cancelled run
  while the underlying mutation may have succeeded.
- Tasks are supervised and monitored. Admission failure or worker death must
  terminalize owned work, not leave a permanent active lock. Standalone fallback
  is only for explicitly requested standalone mode.
- Keep arbitrary callback errors, prompts and credentials out of public status.
  Durable state and diagnostics use bounded, sanitized classifications.

## Cron

- `CronManager` owns scheduling and terminalization; `CronStore` owns durable
  jobs, runs and audits. Scheduled slots use deterministic IDs and atomic
  create-once claims so competing managers cannot execute one slot twice.
- Prompt jobs run in isolated sub-sessions and block `cron`, `goal`, `kanban`,
  `agent_message` and `peer` (`RunSubmitter`): recursive scheduling and work
  that would not carry the run's authority. Unblock one only once it carries
  cron authority. Preserve the base session for summary forwarding.
- Prompt jobs never run with more authority than their launcher
  (`CronAuthority`). Agent-session `add` records the session's principal
  (owner) and effective tool policy on the job; agent-session `update`
  intersects the policy atomically (`CronManager.update_from_session/3`).
  Generic updates cannot set or clear `authority`. Every run also intersects,
  for a channel peer base session, that chat's group approval floor and live
  session policy. A malformed record or unreadable layer
  fails the run, never runs it unrestricted.
- The `cron` tool reaches only jobs its session principal owns; operator and
  other principals' jobs read as not found. The principal is exactly the
  trusted session key, or `legacy:<sha256(id)>` for a non-canonical id; it is
  never promoted to the agent's main session (only delivery falls back there).
  Ownership is immutable, so the tool's check before a mutation stays valid.
  `run` records the triggering session's policy on the run
  (`meta.trigger_policy`). The global `pause_all`/`resume_all` hold is
  operator-only and refused by the tool.
- Command jobs are explicit operator-owned local shell work, not router runs.
  They deliver only to an explicit target. Do not silently turn a prompt job into
  a shell command or infer command delivery from the owner chat.
- Consult persisted active runs on tick/restart. Stale recovery uses the same
  terminalization, delivery and retry policy as normal completion.
- Scheduled retry lineage/due time survives restart. Deterministic root/attempt
  IDs and atomic claims prevent duplicate retries. Manual/wake runs are
  single-shot by default; disabled jobs can run manually but cannot be woken.
- Global pause is one durable `CronStore` marker (`:cron_settings` /
  `:global_pause`), never config or app-env. While set, ticks claim no slot,
  retries wait, wake is refused, a claimed-but-unsubmitted scheduled run is
  aborted, and restart leaves stored schedules untouched. In-flight runs and
  explicit `run_now` are unaffected, and per-job `enabled` stays independent.
  `resume_all/0` skips (audits) every slot and retry missed in the pause,
  re-anchors each job to its next slot, and clears the marker last. It never
  catches up. An unreadable marker blocks dispatch pending durable startup
  restoration; it is not a confirmed pause. Failed restoration retries in-process
  with bounded backoff rather than restarting the automation supervision tree.
- The `cron` agent tool lives here (`LemonAutomation.Tools.Cron`) and is
  contributed through `LemonAgent.ToolRegistry` in `Application.start/2`; the
  gateway and coding agent must not name it. Keep its name, schema, result shape
  and unavailable-scheduler error stable.
- Abort by cron run ID persists terminal state and ignores late completions.
- `CronDelivery` handles explicit none/target, originating channel and owner
  fallback; notifications use a stable per-run idempotency key.
- `CronMemory` is job-local markdown at the Lemon-owned
  `cron_memory/<job id>.md` (digest name for unsafe ids), bounded on injection
  and compacted as it grows. No caller chooses the path. I/O goes through
  `read_confined`/`replace_confined` on `LemonCore.ConfinedFS` rooted at the
  state directory: a no-follow handle on `cron_memory`, regular single-link
  file, opened-inode check, exclusive temporary file plus `renameat` (never in
  place), so a directory swapped for a symlink cannot redirect the I/O. Do not
  create a separate general-purpose memory service here.
  Model file tools refuse `cron_memory` (Lemon operator state); only the run
  whose `meta.cron_memory_file` names a job's file may write that one file
  (`CodingAgent.Tools.OperatorState`'s `:operator_state_grant`).

## Heartbeats

Heartbeats are ordinary cron jobs with `meta.heartbeat == true` (atom or string
key), not a separate process, timer or store. `Heartbeat.apply_policy/2` runs
synchronously after monitor/preflight policy: only completed output trimming to
exactly `HEARTBEAT_OK` is suppressed. Failures, timeouts and other output alert
and deliver. Suppressed runs remain in history.

## Goals and kanban

- One active goal loop per session. Stop disables persisted auto-restart before
  touching external work. Hard stop records durable abort intent before dispatch,
  sends it once, and retains reconciliation on ambiguity; graceful stop permits
  the already bounded loop to finish.
- Reconciliation survives manager restart. Confirmed terminal state releases the
  guard into an error state requiring explicit restart, not another automatic tick.
- Judge failures pause by default; `continue_once` is an explicit policy choice.
- Goal work runs only under authority recorded by a trusted setter
  (`LemonAgent.Workspace.GoalAuthority`: session/chat principal, effective
  policy, canonical root; operator surfaces record operator authority).
  `GoalStore.set/3` requires it. Session and chat starters pass their full
  starter authority (`starter:`: session, agent, policy, canonical root); it
  must be the goal's own session and agent and contain the goal target, and it
  narrows policy and root durably before work or auto restart; such starters
  never join a running loop. Judge and continuation params come from
  `GoalAuthority.run_scope/2` at every tick, including recovery: policy
  intersected with the record and with every delegation tool blocked
  (`GoalAuthority.delegation_tools/0`: cron, kanban, goal, task, agent,
  agent_message, peer, nodes), the target re-resolved in the root, and
  `meta.cwd_identity` bound to it (the router refuses goal runs without it; the
  session runner verifies it at start and before every tool call). Missing
  authority is quarantined, never run with ambient policy. Every `GoalStore`
  rewrite is a compare-and-swap against the goal it read (recomputed on
  conflict), so a concurrent pause, resume or loop update cannot restore a
  wider authority.
- Kanban task terminal writes require the exact lease ID. Stale results cannot
  overwrite a re-leased task. Lease renewal uses only monitored live in-VM
  workers and the exact lease ID. Persisted expiry still governs orphan recovery;
  never renew recovered or ambiguous invocations merely because their durable
  run is active. Restart reclaims only unsubmitted old leases; tracked router
  invocations must reconcile before re-leasing. Hard stop kills owned waiters,
  aborts claimed runs once, and retains ambiguous run ownership.
- Kanban work runs only under board authority recorded by a trusted creator
  (`LemonAgent.Workspace.KanbanAuthority`: session principal, policy, canonical
  root, operator publication grant). Missing authority is quarantined; only
  operator surfaces reauthorize, share, grant publication or widen it. Card
  creator/editor and dispatch starter policies only narrow it, durably. Board
  writes (including archive) happen under the board lock. Workers and
  reviewers block every delegation surface (`KanbanAuthority.delegation_tools/0`)
  until it carries authority.
- Routing identity (principal, assignee, session, run, workspace) comes from
  trusted session context, never tool params or chat flags. Only
  `track_leased_run/4` writes run/session identity; control paths read the
  lease-recorded `meta.kanbanRun.runId`, and only provenance-bound runs are
  reused for sessions or notifications.
- Re-resolve the workspace against the authority root at every preparation
  (dispatch and recovery); never promote a workspace to a parent repository.
  Git workers run in controller-created worktrees under
  `~/.lemon/kanban/worktrees` of the board's controller-owned repository
  (`~/.lemon/kanban/repos/<board>.git`); every run request
  carries `meta.cwd_identity`, which the session runner verifies at session
  start and `CodingAgent.ToolRegistry` before every tool call, and
  `meta.mutation_root`, which confines file-mutation tools to that directory
  (`CodingAgent.Tools.FileValidation.confined/2`). Running in the
  caller's directory (non-Git, or worktrees off) needs the operator's
  workspace-bound in-place grant. Never run concurrent editors in one cwd.
- Never run controller Git against the workspace repository beyond discovery
  (`rev-parse`), the commit identity (`config --get user.*`), grant-time
  `remote get-url` and the local `fetch` source: all
  checkout, staging, commit and push go through
  `KanbanGitWorkflow.controller_git/3` (`GIT_DIR`, `GIT_COMMON_DIR` and
  `GIT_WORK_TREE` fixed; the Lemon-written config and the worktree's
  administrative files verified by `KanbanGitSandbox` before each command). Never write keys
  into a controller repository's config; never call `command/3` or
  `System.cmd` directly. Side-effecting and network commands are built once as
  `{exe, args}`, passed to the required `:authorize` callback, then run
  unchanged; publication and reconciliation authorize the full set before any
  network access.
- Controller commits are authorized against the recorded policy's write,
  command and approval rules; publication (including recovery and
  cancellation reconciliation) additionally needs the operator's current
  revision-, settings- and destination-bound grant and pushes only to its
  pinned URLs. Workflow settings never authorize.

## Blueprints

`Blueprint` composes the skill bundle/audit, derived profile workspace and cron
services. Do not introduce another skill registry, profile store or scheduler.

- Preview is non-mutating. Its digest binds manifest, bytes, profile, exact job
  projection and current collision state. Activation replans under lock, copies
  only the audited file set, re-hashes/re-audits staged bytes, and creates the
  stable job last via `CronManager.add_new/1`. Never overwrite a collision.
- Catalog clients supply bounded IDs, not arbitrary paths. Resolve inside the
  trusted catalog, rejecting traversal, symlinks and identity mismatches.
- The agent-prompt bundle contract rejects commands, archives, cwd/env overrides,
  secret-like values and non-UTC schedules. Preserve these checks at the service
  boundary, not only in UI validation.
- Web/TUI/one-shot CLI projections stay content-free; activation requires the
  fresh exact confirmation digest in the long-running runtime. One-shot clients
  must not start a scheduler or perform local activation.

## Verification

From the umbrella root: `mix test apps/lemon_automation/test`.
Use injectable clocks/submitters and bounded event waits; exercise restart,
competing claims, stale leases, ambiguous outcomes and exact confirmation drift.
See [testing](../../docs/testing.md) for live-service lanes.
