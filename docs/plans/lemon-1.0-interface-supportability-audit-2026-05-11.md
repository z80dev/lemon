# Lemon 1.0 Interface Supportability Audit

Status: launch-readiness audit

Last reviewed: 2026-05-11

## Summary

Lemon has enough backend supportability primitives to build a mainstream
operations surface, but the primary user interfaces do not expose them evenly.

Current state:

- Control plane: strongest support surface. It already exposes methods for
  health, logs, sessions, runs, run graphs, run introspection, tasks, cron,
  approvals, skills, events, config, secrets status, channels, transports, and
  usage.
- TUI: strong local daily-use surface for coding-agent sessions, streaming,
  tool lifecycle display, stats, session switching, notifications, overlays, and
  cancellation. It is not yet a broad operational support console.
- Telegram: useful remote execution surface with session commands, model
  selection, cancellation, watchdog actions, and channel-native approval
  buttons. It is not a general diagnostic/admin UI.
- Discord: similar channel-native controls exist for cancellation, watchdog
  actions, and execution approvals, but Discord is not part of the initial
  primary 1.0 surface in the readiness plan.
- Web UI: no longer session-console only. The first `/ops` operations dashboard
  now surfaces runtime/router health, active sessions, recent runs, pending
  approvals, version/build/release metadata,
  observed cron/skill/channel/memory/log activity from introspection,
  cron schedules, recent cron failures, create/edit/delete controls, run-now and
  enable/disable controls, skill store health, skill provenance/status, required-bin
  and missing-requirement summaries, install/update controls through the skill
  installer, enable/disable controls for existing skills, channel transport
  enablement plus config enable/disable controls, live adapter runtime status,
  gateway default editing, Telegram token-secret and allowlist editing,
  configured binding create/edit/delete controls, disconnect/reconnect controls
  for configured adapters,
  support-bundle commands, nested run graph, and explicit next-panel
  placeholders. Telegram now has live bot proof for command handling, progress,
  prompt round-trip, bare `/cancel`, approval-button resolution, and concise
  invalid-model config errors.

G11 is done for the initial 1.0 interface scope: the backend and several client
surfaces exist, and Web now has source-runtime browser proof for the
deterministic echo path plus unified-runtime custom-port boot proof. TUI now has
source-runtime deterministic echo proof, rendered tool-failure proof, and live
cancellation proof against a real cancellable run. Telegram now has live proof
for the basic remote path, approval-button resolution, and a common invalid-model
config failure. Lower-priority Web config panels outside the current support
surface are post-1.0 unless launch messaging expands Lemon into a full admin
console.

## Scope

This audit checked the interfaces named in the 1.0 readiness plan:

- `apps/lemon_control_plane`
- `clients/lemon-tui`
- `apps/lemon_web`
- `apps/lemon_channels` Telegram adapter
- relevant Discord approval/status controls for parity context

The initial audit was code-backed; the companion proof pack now also records
source-runtime browser and Telegram sessions for the launch-critical flows.

## Evidence Map

### Control Plane

The method registry exposes the supportability backend that a mainstream UI can
build on:

- health/status: `health`, `status`, `introspection.snapshot`
- logs: `logs.tail`
- channels: `channels.status`, `transports.status`, `channels.logout`
- sessions: `sessions.list`, `sessions.preview`, `sessions.active`,
  `sessions.active.list`, `session.detail`, `sessions.patch`,
  `sessions.reset`, `sessions.compact`, `sessions.delete`
- runs: `runs.active.list`, `runs.recent.list`, `run.graph.get`,
  `run.introspection.list`
- tasks/subagents: `tasks.active.list`, `tasks.recent.list`
- cron/background work: `cron.list`, `cron.add`, `cron.update`,
  `cron.remove`, `cron.run`, `cron.runs`, `cron.status`
- approvals: `exec.approvals.get`, `exec.approvals.set`,
  `exec.approvals.node.get`, `exec.approvals.node.set`,
  `exec.approval.request`, `exec.approval.resolve`
- skills: `skills.status`, `skills.bins`, `skills.install`, `skills.update`
- config/secrets: `config.get`, `config.set`, `config.patch`,
  `config.schema`, `config.reload`, `secrets.status`, `secrets.list`,
  `secrets.exists`, `secrets.set`, `secrets.delete`
- events: `events.subscribe`, `events.unsubscribe`, `events.ingest`,
  `events.subscriptions.list`
- usage: `usage.status`, `usage.cost`

Conclusion: the support backend is not the primary gap. The gap is surfacing it
coherently and proving the flows at product level.

### Web UI

`LemonWeb.Router` exposes:

- `/`
- `/ops`
- `/ops/runs/:run_id`
- `/sessions/:session_key`
- `/healthz`

`LemonWeb.SessionLive` supports:

- session-bound prompt submission
- multi-file upload
- streaming assistant deltas
- tool action messages from `:engine_action`
- run started and run completed messages

Remaining launch proof outside the Web UI:

- broader live media proof only if Telegram is later marketed as a rich-media
  interface instead of a text-first remote chat interface

`LemonWeb.OpsDashboardLive` now provides the first operations skeleton:

- runtime and router health summary
- version/build/release metadata, including app version, release name/version,
  release channel, source/release mode, git commit/branch/dirty state, Elixir,
  OTP, architecture, and OS
- provider and secrets status summary
- default provider/model/thinking/engine editing and provider secret-reference
  editing for `api_key_secret`, `oauth_secret`, `auth_source`, and `base_url`
- active sessions
- recent completed runs
- pending execution approvals with approve once, session, agent, global, and
  deny actions
- observed cron, skill, channel, memory, and log-related activity from recent
  introspection events
- cron schedule, recent cron failure summary, create/edit/delete controls, and
  run-now/enable/disable controls
- skill store doctor health, installed skill provenance, required binaries,
  missing requirements, install/update controls through the existing installer,
  and enable/disable controls for existing skills
- channel transport enablement, gateway transport enable/disable config
  controls, gateway default editing, Telegram token-secret and allowlist
  editing, configured binding create/edit/delete controls, live adapter runtime
  status, and disconnect/reconnect controls for configured adapters
- support-bundle download plus source-dev and release-runtime commands
- next-panel placeholders for lower-priority config panels outside the initial
  1.0 support surface

`LemonWeb.OpsRunLive` now provides the first run-detail depth:

- event timeline from introspection events
- tool-event list
- failure list
- nested run graph from `parent_run_id`
- direct child-run references from `parent_run_id`
- event-type counts
- run-scoped pending approvals
- support-bundle commands

Conclusion: Web remains the highest-impact G11 slice, and the dashboard plus
first run-detail page now cover the initial 1.0 support surface. Richer actions
and specialized management panels are post-1.0 unless launch messaging changes.

### TUI

The TUI has strong daily-use session features:

- connection lifecycle and ready state
- prompt submission
- streaming session events
- multi-session state
- session picker and running-session listing
- stats overlay
- search overlay
- settings/help/notification overlays
- tool panel, tool execution bar, tool hints, and tool result messages
- cancellation through `/abort`
- busy-state double Escape and double Ctrl+C abort shortcuts covered by tests,
  with source-runtime live proof for double Escape against a real cancellable run
- runtime restart through `/restart`
- generic UI requests through `select`, `confirm`, `input`, and `editor`

Gaps for launch supportability:

- no dedicated approvals queue view
- no cron/background job view
- no skill inventory/status view
- no memory-search event view
- no run graph/subagent tree view beyond task/tool formatting
- no logs/support-bundle command surfaced as a first-class TUI action
- no documented support workflow tying TUI state to `mix lemon.doctor --bundle`

Conclusion: TUI is acceptable as a local coding surface, but not yet a complete
operations/support console.

### Telegram

The Telegram adapter supports useful remote controls:

- `/cancel`
- `/new`
- `/resume`
- `/model`
- `/thinking`
- `/reload`
- `/trigger`
- `/cwd`
- `/topic`
- `/file`
- inline cancel controls for tool status snapshots
- watchdog controls: keep waiting and stop run
- execution approval messages with approve once, deny, session, agent, and
  global decisions
- callback handling that resolves approvals through `LemonCore.ExecApprovals`
- live approval-button proof from a source gateway through the configured
  Telegram bot: `telegram-approval-proof-2026-05-11-1778542579` rendered the
  approval keyboard, accepted `Approve once`, edited the message to
  `Approval: approve once`, and cleared the pending approval store
- live invalid-model config proof:
  `telegram-config-error-fixed-proof-2026-05-11-1778543058` rendered
  `Run failed: unknown model "definitely-missing-model-..."` without leaking
  stack frames after a formatter fix
- text-first Telegram rendering and media support boundary documented in
  `docs/support.md`: markdown entities, progress/status, approval buttons,
  `/file put`, `/file get`, document auto-save, `telegram_send_image`, and
  bounded generated-image auto-send are supported; arbitrary rich media
  generation, image analysis, TTS, and GitHub-identical markdown rendering are
  not stable 1.0 features

Gaps for launch supportability:

- no broad diagnostic command set for recent runs, tool failures, cron jobs,
  skill state, memory searches, or support bundle instructions

Conclusion: Telegram is a credible remote interaction surface, but it should not
carry the operations dashboard burden for 1.0. It needs documented commands,
clear channel rendering boundaries, and clear support fallback to the doctor
bundle.

### Discord

Discord has comparable channel-native controls for:

- status cancellation
- watchdog keep-waiting / stop-run actions
- approval request buttons and approval resolution

Conclusion: useful parity context, but not a primary 1.0 launch surface unless
the launch scope is expanded beyond TUI, Web, and Telegram.

## Supportability Matrix

| Capability | Control plane | TUI | Web | Telegram | Launch state |
| --- | --- | --- | --- | --- | --- |
| Health/status | Yes | Partial | `/healthz` and `/ops` summary | No admin view | Partial |
| Sessions | Yes | Yes | session console and active list | Partial commands | Partial |
| Streaming output | Yes | Yes | Yes | Yes | Good |
| Tool lifecycle | Yes through events/introspection | Yes | Partial messages | Partial status | Partial |
| Tool failures | Yes through run/event data | Partial | Run detail failure list | Partial text | Partial |
| Cancellation | Yes | Yes | No visible control | Yes | Partial |
| Approvals | Yes | generic UI request only | Pending list and resolution actions | Yes | Partial |
| Run timeline | Yes | message stream only | Run detail timeline | No | Partial |
| Run graph/subagents | Yes | Partial task formatting | Nested run graph | No | Partial |
| Tasks/subagents list | Yes | No dedicated view | Child-run references and graph | No | Partial |
| Cron/background jobs | Yes | No | Schedules, recent failures, and observed activity | No | Partial |
| Skills status | Yes | No | Skill health and observed activity | No | Partial |
| Memory searches | Not clearly surfaced as a product view | No | Observed activity only | No | Partial |
| Logs | Yes | No first-class action | Observed activity and support commands | No | Partial |
| Support bundle | Doctor/release runtime exists | No first-class action | Download and commands shown | No | Partial |
| Provider/config status | Yes | No dedicated view | Provider and secrets panel | No | Partial |
| Channel status | Yes | No dedicated view | Transport enablement, bindings, and observed activity | No | Partial |

## Launch Blockers

### P0: Web Operations Dashboard Depth

The first `/ops` skeleton and `/ops/runs/:run_id` detail page exist. Expand them
into the support views a mainstream user expects:

- overview: health, version/build, provider status, channels/transports, current
  release channel
- sessions: active sessions, recent sessions, preview/detail
- runs: active runs, recent runs, run timeline, failure summary
- tools: tool calls, outputs, trust metadata, failed tool calls
- approvals: pending approvals and resolution actions
- tasks: active/recent task and subagent list beyond the run-local graph
- cron: schedules, recent cron runs, failures, create/edit/delete controls, and
  run-now/enable/disable controls
- skills: health, provenance, bins, update/install status
- channels: configured transports, bindings, runtime transport state
- diagnostics: log references, support-bundle command, doctor status

Acceptance criteria:

- Web UI can answer “what is Lemon doing right now?” without terminal access.
- Web UI can answer “why did this run fail?” for common tool/provider/runtime
  failures.
- Web UI can answer “what needs my approval?” without relying on Telegram.
- A product smoke or LiveView test covers at least the dashboard load, health
  summary, active/recent runs panel, observed activity panel, and pending
  approvals panel.

### P0: Product Proof for Interface Happy Paths

Add explicit proof for the three primary surfaces:

- TUI: run a deterministic prompt, show streaming/tool lifecycle, cancel or
  abort a real cancellable run, and verify session stats/running-session state.
- Web: submit deterministic prompt, stream output, inspect run/tool state.
- Telegram: documented setup plus testable adapter-level command/callback
  coverage for run progress, cancel, and approval decisions.

Acceptance criteria:

- Each primary surface has one documented happy path.
- Each primary surface has at least one automated or repeatable smoke check.
- Failure and approval states are covered somewhere other than unit-only tests.

### P1: Support Workflow Entry Points

Expose support-bundle generation and troubleshooting pointers from interfaces:

- TUI command or help entry for doctor/support bundle.
- Web diagnostics panel with exact source-dev and release-runtime commands.
- Telegram fallback message for support bundle and logs when a run fails.

Acceptance criteria:

- A user who hits a setup/runtime issue can discover the support bundle without
  reading source code.
- The issue template, docs, and interface text all point at the same commands.

## Recommended Implementation Slices

### Slice 1: Web Dashboard Skeleton

Status: initial slice implemented.

Add a Web route such as `/ops` or `/dashboard` with support panels:

- health/status
- sessions active/recent
- runs active/recent
- approvals pending
- cron status
- skills status
- channels/transports status

The first implementation uses safe `lemon_core` and `lemon_router` boundaries,
with approval resolution and existing-cron run/toggle actions kept behind
existing runtime APIs.

### Slice 2: Run Detail and Failure Timeline

Status: initial slice implemented.

Add a run detail view:

- run metadata
- event timeline
- tool calls and results
- errors
- graph/subagent tree if available
- support diagnostics references

The first implementation uses shared `LemonCore.Introspection` data and child
run `parent_run_id` references without adding a `lemon_control_plane`
dependency to `lemon_web`.

### Slice 3: Approval Queue Everywhere

Status: initial Web action slice implemented.

Make pending approvals obvious in:

- Web dashboard
- TUI status/overlay or slash command
- Telegram existing inline approval flow, with docs and tests

The control-plane approval API already exists; the work is mostly product
surface and verification.

The first Web implementation adds pending approval resolution on `/ops` through
`LemonCore.ExecApprovals.resolve/2`, including non-expiring approval requests.
Run detail pages also show approvals scoped to the selected run.

### Slice 4: Cron, Skills, and Channel Support Controls

Status: first cron and existing-skill action slices implemented.

The first support panels exist for:

- cron schedules, recent runs, and failures from `LemonCore.Store`
- skill store health from doctor checks and installed skill registry data
- channel transport enablement and configured bindings from Lemon config plus
  runtime adapter status from the channels registry

The Web cron action slices add create/edit/delete, run-now, and enable/disable
controls through the existing `LemonAutomation.CronManager` boundary.
The first Web skill action slice adds installed skill provenance, required-bin
and missing-requirement summaries, enable/disable controls for existing skills
through the existing skills registry/config boundary, and install/update
controls through the existing skill installer. Web form/button submissions are
treated as the explicit approval for the selected install or update operation;
the installer still owns source resolution, audit, activation, lockfile writes,
and registry refresh.
The first Web channel action slice adds gateway transport enable/disable config
controls through canonical `~/.lemon/config.toml` `[gateway]` keys, plus live
adapter status and disconnect/reconnect controls for configured adapters through
the existing channels registry/application boundary.
The second Web channel action slice adds gateway default editing,
`[gateway.telegram]` token-secret/allowlist/deny-unbound editing, and
`[[gateway.bindings]]` create/edit/delete controls through the same canonical
TOML path.

Post-1.0 controls:

- lower-priority config panels beyond defaults, providers, channels, cron,
  skills, approvals, run inspection, runtime health, and support bundles

These are not launch blockers if the initial launch positions Lemon as a daily
developer agent first. They become P0 only if the launch messaging emphasizes a
full operator/admin console.

### Slice 5: Interface Proof Pack

Create a launch proof doc with screenshots or terminal transcripts for:

- TUI deterministic run
- Web deterministic run and dashboard inspection
- Telegram progress/cancel/approval flow

Keep this as a release-candidate checklist artifact rather than a marketing
page.

## Decision

G11 is no longer unknown. For the initial 1.0 support surface, it is closed:

- backend support APIs: mostly present
- TUI daily-use support: credible for initial 1.0
- Telegram remote controls: credible for text-first initial 1.0
- Web operations dashboard: initial skeleton and run-detail page implemented;
  nested run graph, cron create/edit/delete/run controls,
  installed skill provenance/status plus install/update/enable/disable controls,
  channel transport config enable/disable, channel runtime status plus
  disconnect/reconnect controls, gateway default editing, Telegram
  token-secret/allowlist editing, and configured binding create/edit/delete
  controls implemented; version/build metadata implemented; default
  provider/model/thinking/engine editing and provider secret-reference editing
  implemented
- product proof: sufficient for initial 1.0; Web and TUI deterministic source-runtime echo paths
  pass, TUI source-runtime tool-failure rendering and real-run cancellation
  pass, Telegram live bot proof now covers command handling, progress, prompt
  round-trip, bare `/cancel`, approval-button resolution, and concise
  invalid-model config errors; Telegram markdown/media support boundaries are
  documented for text-first 1.0 support

The remaining 1.0 blockers now move back to the broader readiness ledger:
fresh install/artifact proof and safety-depth work. Lower-priority Web
config panels should stay post-1.0 unless Lemon is marketed as a full admin
console at launch.
