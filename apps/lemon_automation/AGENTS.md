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
- Prompt jobs run in isolated sub-sessions and block the `cron` tool to prevent
  recursive scheduling. Preserve the base session for summary forwarding.
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
- `CronMemory` is job-local markdown, bounded on injection and compacted as it
  grows. Do not create a separate general-purpose memory service here.

## Heartbeats and daily brief

Heartbeats are ordinary cron jobs with `meta.heartbeat == true` (atom or string
key), not a separate process, timer or store. `Heartbeat.apply_policy/2` runs
synchronously after monitor/preflight policy: only completed output trimming to
exactly `HEARTBEAT_OK` is suppressed. Failures, timeouts and other output alert
and deliver. Suppressed runs remain in history.

`[automation] daily_brief = "HH:MM"` reconciles `cron_daily_brief` at boot using
local time and the default main session. Removal removes the job; invalid time
leaves existing jobs untouched. `daily_brief_sync: false` keeps tests isolated.

## Goals and kanban

- One active goal loop per session. Stop disables persisted auto-restart before
  touching external work. Hard stop records durable abort intent before dispatch,
  sends it once, and retains reconciliation on ambiguity; graceful stop permits
  the already bounded loop to finish.
- Reconciliation survives manager restart. Confirmed terminal state releases the
  guard into an error state requiring explicit restart, not another automatic tick.
- Judge failures pause by default; `continue_once` is an explicit policy choice.
- Kanban task terminal writes require the exact lease ID. Stale results cannot
  overwrite a re-leased task. Restart reclaims only unsubmitted old leases;
  tracked router invocations must reconcile before re-leasing. Hard stop kills
  owned waiters, aborts claimed runs once, and retains ambiguous run ownership.
- Git-backed board workers use isolated `.worktrees/kanban-<task_id>` checkouts
  and `lemon-kanban/<task_id>` branches. Never run concurrent editors in one cwd.

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
