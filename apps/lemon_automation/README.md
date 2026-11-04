# LemonAutomation

<!-- Maintenance: strict Credo cleanup keeps runtime behavior unchanged. -->

Cron scheduling, heartbeats, scheduled-result delivery, and automation orchestration for agents in the Lemon umbrella project. This OTP application manages the full lifecycle of scheduled and manually triggered prompt or operator-command runs, from cron expression parsing through job execution, completion tracking, chat delivery, and event broadcasting.

## Architecture Overview

LemonAutomation is built around supervised cron, goal-loop, kanban,
skill-curation, and synthesis workers managed by a `one_for_one` supervisor.
Heartbeats are not a separate process: they are cron jobs, and their policy runs
inside `CronManager` terminalization.

Automation registers its cron reference provider with `LemonSkills.CuratorReferences`
at application start. Every curator entry point reads all persisted cron jobs,
including disabled jobs. References are complete names in prompt text or
`meta.skill` / `meta.skills`; the skills app does not depend on automation.
When automation is unavailable, curation skips automatic archival and reports why.

```
LemonAutomation.Supervisor
  |-- Task.Supervisor (LemonAutomation.TaskSupervisor)
  |-- CronManager     (GenServer - scheduling engine, heartbeat policy, delivery)
  |-- GoalContinuationManager (GenServer - supervised one-shot goal continuation)
  |-- GoalLoopManager (GenServer - preview goal judge loop tick)
  |-- KanbanDispatcher (GenServer - durable board task leasing)
  |-- SkillCuratorManager (GenServer - idle learned-skill maintenance)
  |-- SynthesisRunnerManager (GenServer - scheduled skill synthesis)
```

### Execution Flow

The CronManager ticks every 60 seconds, identifies due jobs, and spawns supervised tasks that submit prompt runs to `LemonRouter` or run operator-owned local commands directly:

```
CronManager (tick every 60s)
    |
    +-- finds due jobs via CronJob.due?/1
    +-- applies jitter delay if configured
    +-- atomically claims scheduled CronRun slot in CronStore
    +-- emits :cron_run_started event
    +-- spawns Task via TaskSupervisor
            |
            +-- checks private CronAdmission callback when configured (fail closed)
            +-- RunSubmitter.submit/2
                    |
                    +-- forks session key into sub-session for isolation
                    +-- reads/injects CronMemory context into prompt
                    +-- RunCompletionWaiter.submit_and_wait/2
                            |
                            +-- assigns fixed run id and pre-subscribes
                            +-- calls LemonRouter.submit(params)
                            +-- waits for terminal event and unsubscribes
                            |
                            +-- returns through a monitored Task ref owned by CronManager
                                    |
                                    +-- updates CronStore
                                    +-- applies monitor/preflight/heartbeat delivery policy
                                    +-- emits :cron_run_completed
                                    +-- forwards prompt-job summary to the base session and sends the
                                        result to the chat chosen by CronDelivery (explicit deliver_to,
                                        originating chat, or paired owner chat) through
                                        LemonChannels.Supervision and its durable outbox
                                    +-- one-shot (`once`) jobs are deleted after their run finishes
```

Before a scheduled launch, CronManager checks the persisted run table for
pending/running runs for the same job, then claims a deterministic scheduled-run
slot through `LemonCore.Store.put_new/3`. It skips duplicate scheduled starts
while an active run exists, and competing dispatchers claiming the same scheduled
slot preserve the first persisted run instead of overwriting it. Prompt runs
claim their fixed router ID before submission. A timeout, worker death after
submission, or lost acknowledgement retains that invocation as active and
reconciling: it is not a retry-safe failure. Recovery checks durable router
completion before releasing ownership, including after manager restart.
Unsubmitted work and local command jobs use their normal terminalization path.
Definite scheduled failures can retry when `max_retries` is greater than zero.
The terminal source run persists retry due time, attempt, and root/source
lineage. Restart rebuilds the wake timer from that state, while a deterministic
retry ID and atomic claim enforce one run per `{root, attempt}`. Retries are
separate `CronRun` records with `triggered_by: :retry`; manual and wake runs do
not retry by default. Workers are monitored supervised tasks; standalone
fallback is explicit.
Operators can abort an active cron run by cron run ID. Cancellation uses the
claimed router ID and records abort intent before dispatch. Unknown outcomes
remain under reconciliation and are not automatically retried. Confirmed
abort terminalizes once and ignores late submitter completions.
Cron lifecycle actions also record durable audit events in `:cron_audit_events`
through `CronStore.record_audit/2`. The audit stream covers job lifecycle
changes, manual run requests, run start/abort/retry/stale recovery, and
scheduled-run claim/suppression decisions. Operator APIs can read raw IDs from
`CronStore.list_audit_events/1`; support diagnostics redact audit IDs, job/run
IDs, and reasons.

**Wake** provides immediate out-of-schedule triggering. It creates runs with
`triggered_by: :wake`, submits through the same configured
`:cron_run_submitter` used by CronManager (normally RunSubmitter ->
LemonRouter), and routes completion back through CronManager.

**GoalContinuationManager** runs persistent-goal continuations. It accepts one
active session goal at a time and starts work through `TaskSupervisor` with
`origin: :goal` and `queue_mode: :followup`. Goal targets persist their `cwd`;
continuations and the read-only judge use that directory rather than daemon cwd.
The goal records the accepted router run ID and bounded completion result.

**GoalLoopManager** runs conservative goal loops. `run_once/2` performs one
judge tick. `start_loop/2` starts one bounded supervised loop per
session, waits for each submitted continuation to emit `:run_completed`, and
stops at `max_ticks`, failure, timeout, or a terminal judge verdict. Passing
`auto: true` persists opt-in auto-loop intent in `LemonAgent.Workspace.GoalStore`; the
manager scheduler scans active goals and re-starts only those persisted loops
when no loop for that session is already running. Loop status and auto state are
stored in `LemonAgent.Workspace.GoalStore` and emitted as redacted goal events.
The manager synchronously claims the fixed run ID before each judge or
continuation enters router submission. A hard stop (the default) disables auto
restart, aborts that owned run once, kills the loop task, and prevents another
tick. Router abort tombstones are serialized with submission acceptance, so a
hard stop cannot miss a run accepted before the submit callback returns. A
graceful stop disables auto restart and lets the bounded loop finish. Manager
call deadlines are computed above configured judge/continuation wait deadlines.
Hard-stop results include a sanitized `router_abort` status. An
`:outcome_unknown` result is reported without retrying the abort, because the
first request may already have taken effect; definite callback errors are
reported only as `:rejected`, without their raw terms.
An accepted continuation timeout, waiter crash, or abrupt loop-worker exit is
also an unknown completion outcome, not a failed submission. The manager keeps
the fixed run ownership in `reconciling`, blocks overlapping restarts, and
releases it only after a durable terminal run record is observed or an explicit
hard-stop result proves cancellation.

`GoalJudge` supports explicit verdicts for tests/manual control, a pluggable
`judge_runner` route with `judge_model` metadata, and deterministic fallback
behavior. The persisted-auto scheduler is tested through the real goal loop and
router judge path. Dev and prod default `goal_judge_runner` to
`GoalJudge.RouterRunner`, the production-shaped route: it submits an isolated
`:goal_judge` run through `LemonRouter`, waits for completion, parses a JSON
verdict, and feeds it through the normalizer. Tests cover that route through
the real router, a router `RunProcess`, and `RunCompletionWaiter` with a
deterministic runtime. Set `LEMON_GOAL_JUDGE_MODEL` to pin the judge run model.
Judge failures pause the goal by default, with an explicit `:continue_once`
policy for fail-open one-shot continuation.

The session-scoped `goal` agent tool exposes set/status/start/stop/pause/resume
and a bounded asynchronous run-once action. Prompt `cron` jobs created by the
agent tool inherit the current repository cwd and accept an explicit model pin.
Neither automatically creates a worktree: use a dedicated target directory
when other editors are active. See the
[coding automation workflow](../../docs/user-guide/reminders-and-heartbeats.md#coding-goals-and-scheduled-coding-jobs).

Every automation path that both submits and waits uses
`RunCompletionWaiter.submit_and_wait/2`. Cron, goal judge, autonomous goal
continuation, and Kanban worker runs subscribe to their fixed
run id before router submission and always unsubscribe after a terminal result.
A goal-loop ownership claim runs synchronously after subscription and before
submission; rejection prevents the router call.
A router run-id mismatch is an explicit error rather than a late subscription
to a replacement id, because a synchronous completion may already have fired.

**KanbanDispatcher** runs durable coding tasks through the same router and native
coding sessions as interactive work. From a CLI or TUI coding session, ask the
agent to use the `kanban` tool:

1. `board_create` with `name` and a repository `workspace` (defaults to the
   current project), then `task_create` with a concrete coding task.
2. `dispatch_start` with `board_id`, optional `max_concurrency` (1–8, default 1)
   and optional `model` (`provider:model`).
3. `task_get` or `board_get` to inspect progress and results;
   `dispatch_status` to inspect worker and reconciliation counts.
4. `dispatch_stop` to stop leasing and cancel the board's router runs.

Workers lease dependency-unblocked cards and execute with `origin: :kanban`.
The `kanban` tool is blocked inside workers to prevent recursive dispatch. A
Git-backed board gets a separate `<repo>/.worktrees/kanban-<task_id>` checkout
on `lemon-kanban/<task_id>` for each task. By default, changes stay there for
manual review and are **not** automatically committed, pushed, or merged.
Inspect `task.meta.kanbanRun.cwd` and `.branch` to find them. Tasks without an assignee
use the default agent, not the dispatcher's lease-owner ID.

Before router submission, the exact lease records the fixed `run_id`, session,
worktree location and `kanbanRun.status = "running"`. Completion marks the card
done and persists the bounded result summary at `task.meta.kanbanRun.output`;
the full conversation remains available under the linked session/run.

Failures record a sanitized `lastFailure` and stop that card from being leased
again, even on boards without a `blocked` column. Correct the cause, then
explicitly `task_update` its status back to the board's first column to retry.
There is no unbounded automatic retry loop.

A timeout, lost waiter or ambiguous submission retains its run ID and lease
with `kanbanRun.status = "outcome_unknown"`. It occupies a concurrency slot
until durable completion is reconciled; expiry and manager restart cannot
launch a second editor in the same worktree. Restart the dispatcher for a board
after a runtime restart to resume reconciliation. Hard stop aborts claimed
router runs once, not just waiter processes. Unknown abort outcomes retain
their leases for reconciliation and are reported in the stop result's `aborts`.

### Reviewed commits and optional publication

Set `coding_workflow: {}` on `kanban` `board_create` to opt into a coding →
independent reviewer → local commit workflow. Omit it (or use `false`) to retain
the coding-only behavior above. This requires an isolated Git worktree and an
explicitly configured Git author/committer identity; Lemon never invents one.

The registered `reviewer` persona receives the task and exact staged diff in a
separate, read-only session. `reviewModel` can pin its model. A blocking review
gets one corrective coding pass; a second rejection or invalid verdict blocks
the card. Neither an editor's successful run nor manually moving the card to
`done` bypasses review. Binary/submodule diffs and oversized diffs fail closed.
The controller commits only the approved tree and refuses changes made after
review. It does not run commit hooks, merge into your checkout, or push by default.

Publication requires explicit configuration, for example:

```json
{
  "action": "board_create",
  "name": "Reviewed fixes",
  "workspace": "/absolute/path/to/repo",
  "coding_workflow": {
    "publish": {
      "mode": "pull_request",
      "remote": "origin",
      "repository": "owner/repository",
      "base": "main",
      "draft": true
    }
  }
}
```

Use `"mode": "branch"` with `"remote": "origin"` to push only the reviewed
commit without opening a PR; a local bare Git remote is suitable for testing.
PR mode requires an installed, authenticated `gh` CLI and pushes the reviewed
branch before `gh pr create`. No force-push is used. `draft` defaults to true.
An existing PR is accepted only when its repository/head/base and head commit
match. Ambiguous push/PR outcomes keep the lease and are reconciled by read-only
queries: Lemon never retries a possibly successful remote mutation.

`task_get` exposes `meta.codingWorkflow`: phase, coding/review run and session
IDs, reviewed tree, branch, commit SHA, approval, publication status, and `prUrl`.
The Work dashboard shows the phase, approval, commit and PR link while keeping
instructions and review findings private. Stop records cancellation before
terminating workers; it cannot undo an already-created commit or remote update.
Restart the board dispatcher after a runtime restart to resume the same
checkpoint without replaying a completed editor or reviewer.
Late terminal writes require the original lease ID.

**Heartbeat** (`LemonAutomation.Heartbeat`) is Lemon's one heartbeat
mechanism: a cron job whose `meta` has `heartbeat: true` (atom or string key).
It is scheduled, run, and delivered like every other cron job. During
terminalization `CronManager` calls `Heartbeat.apply_policy/2`: a completed run
whose output trims to exactly `"HEARTBEAT_OK"` is marked suppressed, kept in run
history, emits `:heartbeat_suppressed`, and is not delivered; any other outcome
emits `:heartbeat_alert` and is delivered. Heartbeat schedules are cron
schedules, so intervals must be cron-exact.

**CronDelivery** (`LemonAutomation.CronDelivery`) chooses where a delivered
run result is sent, in order: `deliver_to: "none"` (nowhere); an explicit
`"telegram:<chat_id>[:<thread_id>]"` or `"discord:<channel_id>[:<thread_id>]"`;
the originating chat when the job's session key is a channel-peer key of a
registered chat platform; otherwise the paired owner chat (the first
`gateway.telegram.allowed_chat_ids` entry when Telegram is enabled, else
`gateway.discord.default_channel_id` when Discord is enabled); otherwise
nowhere. `RunNotifications` binds router invocations to the exact target before
submission; `LemonChannels.Supervision` owns bounded completion/failure rendering,
durable admission and per-kind/job/run/status deduplication. Telegram `/remind`
(`LemonChannels.Reminders`) and the agent `cron` tool create ordinary jobs through
`CronManager` and rely on this resolution.

### Remote supervision

Goals and kanban boards use the same target grammar as cron. Set `deliver_to` on
the `goal` tool's `set` or `kanban` tool's `board_create`: `auto` uses the originating
Telegram/Discord account/chat/topic, then the configured owner; `none` opts out;
`telegram:<chat_id>[:<thread_id>]` or `discord:<channel_id>[:<thread_id>]` selects an
explicit target. Channel-created boards preserve their origin even when workers
run in isolated sessions. Programmatic callers store these options in goal/board
`meta["deliverTo"]` and board `meta["notificationSessionKey"]`.

Known terminal results produce notices with task/run identity, bounded redacted
summary, and reviewed commit/PR when present. An uncertain submission or abort is
not reported as completed/failed: inspect the existing run and reconcile it.
Goal loops that pause or exhaust their bound report incomplete work rather than
claiming success. Existing CLI/TUI goal and kanban tools still control start,
status, stop and explicit retry; cron retains its scheduled retry policy.

Approval-requiring tools remain blocked until the corresponding channel's
**Approve once** or **Deny** control resolves the exact pending request.
Controls bind the full approval ID and pending snapshot to the immutable run,
session, account, chat and topic; stale, expired, foreign and failed decisions
never acknowledge success. Remote controls cannot grant persistent policy.
See [channel supervision](../lemon_channels/README.md#automation-supervision)
for delivery and recovery guarantees.

**SkillCuratorManager** runs Lemon's learned-skill curator after the runtime has
been idle long enough and the persisted curator interval gate is due. It asks
`LemonSkills.Curator` to apply conservative stale/archive/reactivation
transitions, then submits the generated review prompt to `LemonRouter` only when
agent-authored skills require a consolidation pass. Curator review runs default
to a learning-only tool policy that exposes `read_skill`, `skill_manage`,
`remember`, and `recall`; override it with `tool_policy` in the curator config
when an operator needs a narrower or broader surface. A submitted review updates
the curator report with the router run id for auditability.

### Session Isolation

Each cron run executes in a forked sub-session (e.g., `agent:abc:main:sub:cron_12345`) to prevent cron activity from polluting the originating session's conversation history. Completion summaries are forwarded back to the base session as synthetic `run_completed` entries with `meta.cron_forwarded_summary = true`. The result is also sent through the `LemonRouter.ChannelsDelivery` -> `LemonChannels` path to the chat chosen by `CronDelivery`, so jobs created from the TUI, web UI, or CLI reach the paired owner chat and channel-origin jobs return to their chat even when no process is subscribed to the session topic.

### Persistent Cross-Run Memory

The `CronMemory` module gives each cron job a markdown file that accumulates run results across executions. On each run, the prompt is augmented with the memory file's contents so the agent has context from prior runs. The memory file auto-compacts when it exceeds 24,000 characters, retaining the most recent 14,000 characters and summarizing older content.

### Portable Skill and Automation Blueprints

`LemonAutomation.Blueprint` activates a versioned, unpacked bundle containing
one or more audited skills and exactly one agent-backed cron definition. The
control-plane catalog is `~/.lemon/bundles/<bundle-id>/`; its RPC methods accept
only the safe `bundleId`, never a caller-provided filesystem path.

Activation is always preview-first. The preview's `confirmationDigest` binds
the normalized manifest, skill content hashes, target profile, exact cron
projection, and current destination/job state. Activation replans under a lock,
requires that exact digest, stages and re-audits copied skill bytes, enables the
skills only inside the derived profile workspace, then claims the stable cron
ID through `CronManager.add_new/1`. A replay with identical content is
unchanged; a changed destination, stale digest, or ID collision fails without
overwriting the existing job.

Version 1 is intentionally narrow: no archives, symlinks, commands, shell
scripts, environment injection, arbitrary working directories, memory-file
overrides, secret-like manifest values, non-UTC schedules, or overwrite mode.
The public list/inspect/validate/preview/activate results omit paths, skill
bodies, prompt text, and secret values. See
[`docs/user-guide/skills.md`](../../docs/user-guide/skills.md#portable-skill-and-automation-bundles)
and the harmless disabled example under
`examples/skill-automation-bundles/daily-note/`.

## Module Inventory

| Module | File | Purpose |
|--------|------|---------|
| `LemonAutomation` | `lib/lemon_automation.ex` | Top-level facade with `defdelegate` functions |
| `LemonAutomation.Application` | `lib/lemon_automation/application.ex` | OTP application and supervisor setup |
| `LemonAutomation.Blueprint` | `lib/lemon_automation/blueprint.ex` | Validates, previews, digest-confirms, and idempotently activates portable profile skill + cron bundles |
| `LemonAutomation.Blueprint.Catalog` | `lib/lemon_automation/blueprint/catalog.ex` | Resolves bounded local bundle IDs and provides the shared Web/control-plane list, inspect, validate, preview, and activate boundary |
| `LemonAutomation.CronManager` | `lib/lemon_automation/cron_manager.ex` | Core scheduling GenServer; owns in-memory job state, persists to CronStore, handles ticks, execution, and completion |
| `LemonAutomation.CronJob` | `lib/lemon_automation/cron_job.ex` | Job struct with CRUD operations, `due?/1` predicate, serialization |
| `LemonAutomation.CronRun` | `lib/lemon_automation/cron_run.ex` | Run struct with state machine transitions (pending -> running -> completed/failed/timeout/aborted) |
| `LemonAutomation.CronSchedule` | `lib/lemon_automation/cron_schedule.ex` | Cron expression parser and next-run time computation |
| `LemonAutomation.CronStore` | `lib/lemon_automation/cron_store.ex` | Persistence layer using `LemonCore.Store` (tables: `:cron_jobs`, `:cron_runs`, plus `:cron_settings` for the durable global pause marker) |
| `LemonAutomation.CronMemory` | `lib/lemon_automation/cron_memory.ex` | Persistent markdown-based cross-run memory for cron jobs |
| `LemonAutomation.Tools.Cron` | `lib/lemon_automation/tools/cron.ex` | The agent `cron` tool (status/list/add/update/pause/resume/pause_all/resume_all/abort/remove/run/runs); registered with `LemonAgent.ToolRegistry` by `LemonAutomation.Application`, so sessions are offered it through the platform tool registry; non-Lemon session ids (e.g. TUI `tui-…`) fall back to `agent:<id>:main` |
| `LemonAutomation.CronCommandRunner` | `lib/lemon_automation/cron_command_runner.ex` | Supervised no-agent local shell command runner for operator-created command cron jobs |
| `LemonCore.Doctor.CronDiagnostics` | `apps/lemon_core/lib/lemon_core/doctor/cron_diagnostics.ex` | Core-owned redacted support-bundle diagnostics for cron jobs and runs |
| `LemonAutomation.Heartbeat` | `lib/lemon_automation/heartbeat.ex` | Heartbeat policy (`meta.heartbeat` jobs; `HEARTBEAT_OK` suppression) applied during CronManager terminalization |
| `LemonAutomation.CronDelivery` | `lib/lemon_automation/cron_delivery.ex` | Resolves the shared automation target grammar; `RunNotifications` binds invocations and hands terminal facts to channels |
| `LemonAutomation.GoalContinuation` | `lib/lemon_automation/goal_continuation.ex` | Builds and submits one persistent-goal continuation run through LemonRouter |
| `LemonAutomation.GoalContinuationManager` | `lib/lemon_automation/goal_continuation_manager.ex` | Supervised task entrypoint for one-shot goal continuation |
| `LemonAutomation.GoalJudge` | `lib/lemon_automation/goal_judge.ex` | Normalizes preview goal-loop verdicts |
| `LemonAutomation.GoalLoop` | `lib/lemon_automation/goal_loop.ex` | Applies one judge verdict to submit, complete, or pause a durable goal |
| `LemonAutomation.GoalLoopManager` | `lib/lemon_automation/goal_loop_manager.ex` | Supervised goal-loop entrypoint with opt-in persisted auto scheduling |
| `LemonAutomation.SkillCurator` | `lib/lemon_automation/skill_curator.ex` | Applies idle/config gates and submits learned-skill curator prompts |
| `LemonAutomation.SkillCuratorManager` | `lib/lemon_automation/skill_curator_manager.ex` | Periodic idle scheduler for background skill curation |
| `LemonAutomation.KanbanDispatcher` | `lib/lemon_automation/kanban_dispatcher.ex` | Supervised durable-board task leasing, execution, completion, and failure marking |
| `LemonAutomation.KanbanRunWorker` | `lib/lemon_automation/kanban_run_worker.ex` | Converts leased kanban tasks into router runs with board/task provenance and recursive-kanban blocking |
| `LemonAutomation.KanbanWorktree` | `lib/lemon_automation/kanban_worktree.ex` | Creates per-task git worktrees under `.worktrees/` for isolated kanban worker execution |
| `LemonAutomation.Wake` | `lib/lemon_automation/wake.ex` | Manual immediate job triggering with batch and pattern-matching support |
| `LemonAutomation.RunSubmitter` | `lib/lemon_automation/run_submitter.ex` | Builds run params, pre-subscribes to bus, submits to LemonRouter, appends to CronMemory |
| `LemonAutomation.RunCompletionWaiter` | `lib/lemon_automation/run_completion_waiter.ex` | Owns fixed-id pre-subscribe/submit/wait cleanup and parses terminal events |
| `LemonAutomation.Events` | `lib/lemon_automation/events.ex` | Event emission helpers for all automation events |

## Configuration

LemonAutomation behavior is controlled through cron job fields plus a small application-level curator config:

- **Tick interval**: Hardcoded at 60,000ms (`@tick_interval_ms` in CronManager)
- **Default timeout**: 300,000ms (5 minutes) per job, overridable per-job via `timeout_ms`
- **Retry policy**: `max_retries` defaults to `0`; `retry_backoff_ms` defaults to `30_000` and applies to scheduled failure/timeout retries
- **Output truncation**: Run output capped at 1,000 characters in CronStore; forwarded summaries capped at 12,000 bytes
- **Memory file limits**: 24,000 chars max per memory file, 8,000 chars injected into prompts, 2,000 chars per run result entry
- **Memory file location**: Defaults to `~/.lemon/cron_memory/{job_id}.md`, overridable via `memory_file` field on the job or in `meta`
- **Goal judge runner**: dev/prod default to `LemonAutomation.GoalJudge.RouterRunner`; set `LEMON_GOAL_JUDGE_MODEL` or pass `judge_model` from the control plane/TUI to choose a specific judge model
- **Goal loop scheduler**: automatic per-goal scheduling persists across restarts; `:goal_loop_scheduler_interval_ms` defaults to 30,000 and `:goal_loop_scan_limit` defaults to 50.
- **Skill curator**: `config :lemon_automation, :skill_curator, enabled: true, agent_id: "default", interval_hours: 168, min_idle_hours: 2, tool_policy: %{allow: ["read_skill", "skill_manage", "remember", "recall"]}`

## Usage

### Creating a Cron Job

```elixir
{:ok, job} = LemonAutomation.add_job(%{
  name: "Daily Report",
  schedule: "0 9 * * *",
  agent_id: "agent_abc",
  session_key: "agent:agent_abc:main",
  prompt: "Generate daily status report"
})
```

### With Local Time, Jitter, and Retries

```elixir
{:ok, job} = LemonAutomation.add_job(%{
  name: "Morning Check",
  schedule: "0 9 * * 1-5",
  agent_id: "agent_abc",
  session_key: "agent:agent_abc:main",
  prompt: "Check system status",
  timezone: "local",
  jitter_sec: 30,
  max_retries: 2,
  retry_backoff_ms: 60_000
})
```

`timezone: "UTC"` (the default) evaluates the schedule in UTC; `"local"` uses
the server's OS wall-clock time. IANA names such as `"America/New_York"` use
Tzdata with daylight-saving rules. Creation/update rejects invalid or
unavailable zones. Missing DST slots are skipped and repeated slots use only
their first occurrence; next-run values are UTC instants. See the
[timezone guide](../../docs/user-guide/reminders-and-heartbeats.md#timezones-and-daylight-saving-changes).

### One-Shot Jobs and Delivery Targets

```elixir
# Fires once at 14:30 local time on 28 September, then is deleted.
{:ok, job} = LemonAutomation.add_job(%{
  name: "Reminder: call the bank",
  schedule: "30 14 28 9 *",
  timezone: "local",
  once: true,
  agent_id: "agent_abc",
  session_key: "agent:agent_abc:main",
  prompt: "Remind the user to call the bank.",
  deliver_to: "telegram:123456789"
})
```

A `once` job is disabled when its scheduled run is claimed, so a restart or
slow run cannot fire it twice, and it is deleted after that run (and any retry)
finishes. `deliver_to` accepts `"none"`, `"telegram:<chat_id>[:<thread_id>]"`,
`"discord:<channel_id>[:<thread_id>]"`, or `nil`/`""`/`"auto"` for the default
resolution described under **CronDelivery**; any other value is rejected.

### Operator Command Job

Control-plane operators can create no-agent command jobs with `command` instead
of `agent_id`/`session_key`/`prompt`. Command jobs run under the
`CronManager` supervised task path, store output in cron run history, and do
not create LemonRouter runs. They are delivered to chat only when they set an
explicit `deliver_to` target; otherwise `CronDelivery` resolves them to nowhere.

```elixir
{:ok, job} = LemonAutomation.add_job(%{
  name: "Disk Usage Snapshot",
  schedule: "hourly",
  command: "df -h /",
  cwd: "/tmp"
})
```

### Required Fields

All jobs require `name` and `schedule`. Prompt jobs also require `agent_id`,
`session_key`, and `prompt`; no-agent command jobs require `command` instead.
Updates preserve the job target type: prompt jobs can update `prompt`, command
jobs can update `command`, `cwd`, and `env`, and routing fields remain
immutable.

| Field | Description |
|-------|-------------|
| `name` | Human-readable job identifier |
| `schedule` | Cron expression or supported shorthand |
| `agent_id` | Target agent ID for prompt jobs |
| `session_key` | Routing key for prompt jobs (e.g., `"agent:{id}:main"`) |
| `prompt` | Text sent to the agent on each run |
| `command` | Local shell command for no-agent operator jobs; mutually exclusive with `prompt` |

### Optional Fields

| Field | Default | Description |
|-------|---------|-------------|
| `enabled` | `true` | Whether the job is active |
| `timezone` | `"UTC"` | `"UTC"`, `"local"` (server wall-clock), or an available IANA name; DST gaps skip slots and folds use the first occurrence |
| `admission` | `nil` | Private, operator-configured product admission for profile-backed agent jobs; denied/unavailable decisions never dispatch or retry. See [controller API](../lemon_control_plane/README.md#private-cron-admission). |
| `deliver_to` | `nil` | Delivery target: `nil` (originating chat, else paired owner chat), `"none"`, `"telegram:<chat_id>[:<thread_id>]"`, or `"discord:<channel_id>[:<thread_id>]"` |
| `once` | `false` | One-shot: disabled when its scheduled run is claimed, deleted after that run finishes |
| `jitter_sec` | `0` | Random delay spread in seconds |
| `timeout_ms` | `300_000` | Max execution time (5 minutes) |
| `max_retries` | `0` | Number of retries after scheduled failure/timeout |
| `retry_backoff_ms` | `30_000` | Delay before retry runs |
| `cwd` | current runtime cwd | Working directory for command jobs |
| `env` | `%{}` | Environment overrides for command jobs |
| `memory_file` | auto-generated | Path to persistent cross-run memory file |
| `meta` | `nil` | Arbitrary metadata map |

### Cron Expression Format

```
* * * * *
| | | | +-- Day of week (0-7, 0 and 7 are Sunday)
| | | +---- Month (1-12)
| | +------ Day of month (1-31)
| +-------- Hour (0-23)
+---------- Minute (0-59)
```

Supported cron syntax: `*` (every), `N` (specific), `N-M` (range), `*/N` (step), `N,M,O` (list). Lists and ranges can be combined (e.g., `0,30 9-12,18 * * *`).

Supported schedule shorthands are normalized into 5-field cron expressions before
storage. Interval shorthands must map cleanly to cron step fields, so minute
intervals divide 60 and hour intervals divide 24:

| Shorthand | Stored cron |
|-----------|-------------|
| `every 30m`, `15 minutes` | `*/30 * * * *`, `*/15 * * * *` |
| `hourly`, `every 2h` | `0 * * * *`, `0 */2 * * *` |
| `daily at 9am`, `every day at 17:45` | `0 9 * * *`, `45 17 * * *` |
| `weekdays at 09:30` | `30 9 * * 1-5` |
| `weekly monday at 8am`, `fridays at 18:15` | `0 8 * * 1`, `15 18 * * 5` |

### Managing Jobs

```elixir
# List all jobs (sorted by created_at_ms descending)
LemonAutomation.list_jobs()

# Update a job (agent_id and session_key are immutable)
LemonAutomation.update_job(job.id, %{enabled: false})

# Remove a job
LemonAutomation.remove_job(job.id)

# Run a job immediately (manual trigger)
LemonAutomation.run_now(job.id)

# Get run history (opts: limit, status, since_ms)
LemonAutomation.runs(job.id, limit: 10)
```

### Wake (Immediate Triggering)

```elixir
# Trigger a single job (must be enabled)
{:ok, run} = LemonAutomation.Wake.trigger("cron_abc123")

# Trigger with context metadata
{:ok, run} = LemonAutomation.Wake.trigger("cron_abc123",
  context: %{reason: "incident response"})

# Skip if already running
{:ok, run} = LemonAutomation.Wake.trigger("cron_abc123",
  skip_if_running: true)

# Trigger by name pattern (case-insensitive)
results = LemonAutomation.Wake.trigger_matching("heartbeat")

# Trigger all enabled jobs for an agent
results = LemonAutomation.Wake.trigger_for_agent("agent_abc")
```

### Heartbeats

A heartbeat is an ordinary cron job whose `meta` has `heartbeat: true` (atom or
string key). It runs in an isolated sub-session like every cron job and is
delivered by `CronDelivery`. Schedules are cron schedules, so intervals must be
cron-exact (`every 30m`, `every 2h`, `daily at 8am`, ...).

```elixir
{:ok, job} = LemonAutomation.add_job(%{
  name: "heartbeat-agent_abc",
  schedule: "every 30m",
  timezone: "local",
  agent_id: "agent_abc",
  session_key: "agent:agent_abc:main",
  prompt: "Work through HEARTBEAT.md; reply HEARTBEAT_OK if nothing needs attention.",
  meta: %{heartbeat: true, agent_id: "agent_abc"}
})

LemonAutomation.Heartbeat.heartbeat?(job)                    # => true
LemonAutomation.Heartbeat.healthy_response?("  HEARTBEAT_OK\n") # => true
```

The TUI `/heartbeat every <interval> <prompt>` command creates or updates this
per-agent job (`meta.heartbeat`, `timezone: "local"`, `agent:<id>:main`).

**Suppression rules**: `Heartbeat.apply_policy/2` runs synchronously in
`CronManager` terminalization, after the monitor and preflight policies. Only a
`:completed` run whose output trims to exactly `"HEARTBEAT_OK"` is suppressed:
`CronRun.suppress/1` marks it in cron history, `:heartbeat_suppressed` is
emitted, and nothing is delivered. Any other outcome (including failures and
timeouts) emits `:heartbeat_alert` with `severity: :warning` and is delivered
unless the monitor or preflight policy already withheld it. Non-heartbeat jobs
pass through unchanged.

### Events

All events are broadcast on the `"cron"` bus topic as `%LemonCore.Event{}` structs:

| Event | Emitted By | When |
|-------|-----------|------|
| `:cron_tick` | CronManager | Every 60s tick |
| `:cron_job_created` | CronManager | Job added |
| `:cron_job_updated` | CronManager | Job updated |
| `:cron_job_deleted` | CronManager | Job removed |
| `:cron_run_started` | CronManager, Wake | Run begins |
| `:cron_run_completed` | CronManager | Run finishes (terminalization) |
| `:heartbeat_suppressed` | `Heartbeat` policy in CronManager terminalization | Heartbeat run replied exactly "HEARTBEAT_OK" |
| `:heartbeat_alert` | `Heartbeat` policy in CronManager terminalization | Any other heartbeat outcome |

```elixir
LemonCore.Bus.subscribe("cron")

receive do
  %LemonCore.Event{type: :cron_run_completed, payload: payload} ->
    IO.puts("Run #{payload.cron_run_id}: #{payload.status}")
end
```

### CronSchedule API

```elixir
# Parse and validate
{:ok, parsed} = LemonAutomation.CronSchedule.parse("*/15 * * * *")
LemonAutomation.CronSchedule.valid?("0 9 * * *")

# Next run computation
next_ms = LemonAutomation.CronSchedule.next_run_ms("0 9 * * *", "UTC")
next_dt = LemonAutomation.CronSchedule.next_run_datetime("0 9 * * *", "UTC")
times = LemonAutomation.CronSchedule.next_runs("*/15 * * * *", "UTC", count: 5)

# Check if a DateTime matches
LemonAutomation.CronSchedule.matches?("0 9 * * *", datetime)
```

### CronStore API

```elixir
# Jobs
CronStore.put_job(job)
CronStore.get_job(job_id)
CronStore.delete_job(job_id)
CronStore.list_jobs()
CronStore.list_enabled_jobs()
CronStore.list_due_jobs()

# Runs
CronStore.put_run(run)
CronStore.claim_run(run)
CronStore.claim_scheduled_run(job, scheduled_for_ms, router_run_id)
CronStore.get_run(run_id)
CronStore.list_runs(job_id, limit: 10, status: :completed, since_ms: timestamp)
CronStore.list_all_runs(limit: 50)
CronStore.active_runs(job_id)
CronStore.cleanup_old_runs(50)  # keep last 50 per job
```

## CronRun State Machine

```
CronRun.new(job_id, triggered_by)  => :pending
CronRun.start(run, run_id)        => :running
CronRun.complete(run, output)     => :completed
CronRun.fail(run, error)          => :failed
CronRun.timeout(run)              => :timeout
CronRun.suppress(run)             => suppressed: true (combinable with any terminal state)
```

Predicates: `CronRun.active?/1` (pending or running), `CronRun.finished?/1` (completed, failed, or timeout). Retry attempts use `triggered_by: :retry` and carry `retry_attempt`, `retry_of`, and `retry_root_id` in run metadata.

## Dependencies

| Dependency | Type | Purpose |
|-----------|------|---------|
| `lemon_agent` | Umbrella | `LemonAgent.ToolRegistry` registration and agent tool types for the `cron` tool |
| `lemon_ai` | Umbrella | Content structs returned by the `cron` tool |
| `lemon_core` | Umbrella | Store, Bus, Clock, Id generation, SessionKey, Event |
| `lemon_router` | Umbrella | Run submission via `LemonRouter.submit/1` |
| `jason` | Hex | JSON serialization |

## Testing

```bash
# All automation tests
mix test apps/lemon_automation

# Specific test file
mix test apps/lemon_automation/test/lemon_automation/cron_schedule_test.exs

# Portable bundle validation, confirmation, rollback, and replay
mix test apps/lemon_automation/test/lemon_automation/blueprint_test.exs --seed 1

# Focused cron diagnostics/support proof
MIX_ENV=test mix test \
  apps/lemon_core/test/lemon_core/doctor/cron_diagnostics_test.exs \
  apps/lemon_core/test/lemon_core/doctor/support_bundle_test.exs \
  --seed 1

# Focused cron automation/control-plane/gateway lane
MIX_ENV=test mix test \
  apps/lemon_automation/test/lemon_automation/cron_job_test.exs \
  apps/lemon_automation/test/lemon_automation/cron_schedule_test.exs \
  apps/lemon_automation/test/lemon_automation/cron_store_test.exs \
  apps/lemon_automation/test/lemon_automation/cron_run_test.exs \
  apps/lemon_automation/test/lemon_automation/cron_manager_retry_test.exs \
  apps/lemon_automation/test/lemon_automation/cron_manager_worker_lifecycle_test.exs \
  apps/lemon_automation/test/lemon_automation/cron_manager_scheduler_lock_test.exs \
  apps/lemon_automation/test/lemon_automation/cron_manager_update_test.exs \
  apps/lemon_automation/test/lemon_automation/cron_manager_forwarding_test.exs \
  apps/lemon_automation/test/lemon_automation/cron_manager_unavailable_test.exs \
  apps/lemon_automation/test/lemon_automation/cron_delivery_test.exs \
  apps/lemon_automation/test/lemon_automation/heartbeat_test.exs \
  apps/lemon_control_plane/test/lemon_control_plane/methods/cron_methods_test.exs \
  apps/lemon_automation/test/lemon_automation/tools/cron_test.exs \
  --seed 1

# Optional manual full-runtime restart smoke (boots runtime_full twice)
MIX_ENV=dev mix run --no-start scripts/live_cron_runtime_restart_smoke.exs

# Provider-backed goal-judge proof
ZAI_API_KEY="$(MIX_ENV=dev mix run --no-start -e 'Logger.configure(level: :emergency); Logger.remove_backend(:console); {:ok, _} = Application.ensure_all_started(:lemon_core); IO.write(LemonCore.Secrets.fetch_value("llm_zai_api_key") || "")')" \
LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 \
LEMON_GOAL_JUDGE_MODEL="zai:glm-5-turbo" \
scripts/test path apps/lemon_automation/test/lemon_automation/goal_judge_router_live_test.exs --include integration --seed 1

# Provider-backed kanban dispatcher proof
secret_file=$(mktemp "${TMPDIR:-/tmp}/lemon-zai-secret.XXXXXX")
LEMON_SECRET_OUTPUT="$secret_file" MIX_ENV=dev mix run --no-start -e '
Logger.configure(level: :emergency)
Logger.remove_backend(:console)
{:ok, _} = Application.ensure_all_started(:lemon_core)
case LemonCore.Secrets.fetch_value("llm_zai_api_key") do
  value when is_binary(value) and value != "" -> File.write!(System.fetch_env!("LEMON_SECRET_OUTPUT"), value)
  _ -> System.halt(66)
end
' >/dev/null 2>&1
ZAI_API_KEY="$(cat "$secret_file")" \
LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 \
LEMON_KANBAN_LIVE_MODEL="zai:glm-5-turbo" \
scripts/test path apps/lemon_automation/test/lemon_automation/kanban_dispatcher_live_test.exs --include integration --seed 1
rc=$?
rm -f "$secret_file"
exit "$rc"

# With coverage
mix test --cover apps/lemon_automation
```

### Test Files

| Test File | Coverage |
|-----------|----------|
| `tools/cron_test.exs` | The `cron` agent tool against a real `CronManager`: add/list/update/pause/resume/abort/remove, session and agent defaults, delivery targets, run history, and registry registration |
| `cron_job_test.exs` | CronJob struct creation, update, due?, serialization |
| `blueprint_test.exs` | Portable manifest policy, staged revalidation, profile-local enablement, exact confirmation, rollback, stable cron provenance, and idempotent replay |
| `cron_run_test.exs` | CronRun state transitions, duration computation, serialization |
| `cron_schedule_test.exs` | Cron parsing, next_run computation, matches?, common patterns, `"local"` timezone occurrences |
| `cron_store_test.exs` | Persistence CRUD, filtering, ordering, cleanup_old_runs |
| `cron_manager_retry_test.exs` | Scheduled retry/backoff, restart reconstruction, deterministic attempt uniqueness, stale recovery, and manual no-retry behavior |
| `cron_manager_worker_lifecycle_test.exs` | Monitored submitter crash and task-supervisor start failure terminalization |
| `cron_manager_scheduler_lock_test.exs` | Scheduled ticks and manager restarts skip duplicate launches when a persisted active run exists and recover stale active runs as timeouts |
| `cron_manager_update_test.exs` | Immutable field rejection, mutable field updates |
| `cron_manager_forwarding_test.exs` | Summary forwarding to main/channel_peer sessions and channel outbox delivery; default delivery to the paired owner chat (including non-Lemon session ids), explicit `deliver_to` and `"none"`, heartbeat suppression vs. delivery, and one-shot delivery then removal |
| `cron_delivery_test.exs` | `deliver_to` validation and target resolution (explicit, originating chat, Telegram/Discord owner chat, unpaired) |
| `events_test.exs` | Event emission for all event types |
| `heartbeat_test.exs` | `apply_policy/2` suppression/alert behavior and exact `[SILENT]` handling |
| `run_completion_waiter_test.exs` | Bus-based completion waiting, output truncation |
| `run_submitter_test.exs` | Router submission, session key forking, error handling, memory file writes |
| `goal_loop_test.exs` | Goal loop verdicts, bounded loops, auto scheduling, router judge proof, authoritative run tracking, and hard-stop abort/no-next-tick semantics |
| `goal_judge_router_live_test.exs` | Opt-in provider-backed router judge proof; passed locally on 2026-05-15 with Z.ai `glm-5-turbo` |
| `kanban_dispatcher_test.exs` | Durable kanban task leasing, bounded concurrency, real-worker dispatch proof, completion, failure, crash marking, hard-stop reclaim, stale-result rejection, and restart reconciliation |
| `kanban_dispatcher_live_test.exs` | Opt-in provider-backed dispatcher proof; passed locally on 2026-05-15 with Z.ai `glm-5-turbo` |
| `kanban_run_worker_test.exs` | Router request construction, run wait behavior, and failure return for leased kanban tasks |
| `wake_test.exs` | Wake triggering, batch operations, pattern matching, agent filtering |

### Key Testing Patterns

Tests use injectable modules for `router_mod`, `waiter_mod`, `bus_mod`, and `memory_mod` to isolate units from LemonRouter and LemonCore.Bus. The `CronManager.tick()` cast forces a tick cycle for deterministic testing. Store tables are cleared in `setup` blocks for `async: false` tests.
