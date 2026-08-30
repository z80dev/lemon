# Hermes runtime/functionality audit — 2026-08-30

Status: current, source-pinned audit of non-transport agent behavior

## Baselines and scope

- Hermes Agent: [`NousResearch/hermes-agent`](https://github.com/NousResearch/hermes-agent)
  at `4f22543509d1b91dc45bcb369447126c5eb14fb7`.
- Lemon: `64092542f523c24b032a0789516a5366a943ac8a` before the changes documented
  below.
- Primary Hermes references: the official
  [tools reference](https://hermes-agent.nousresearch.com/docs/reference/tools-reference/),
  [tool search guide](https://hermes-agent.nousresearch.com/docs/user-guide/features/tool-search),
  [checkpoints and rollback guide](https://hermes-agent.nousresearch.com/docs/user-guide/checkpoints-and-rollback/),
  [cron guide](https://hermes-agent.nousresearch.com/docs/user-guide/features/cron),
  and [session heartbeat guide](https://hermes-agent.nousresearch.com/docs/user-guide/features/heartbeat).
- Transport count and platform breadth are intentionally out of scope for this
  pass. The comparison asks whether the same work can be performed, not whether
  every Hermes channel has a Lemon adapter yet.

The older 2026-08-11 audit was directionally useful, but several of its Lemon
gaps are no longer current. In particular, Lemon now has provider credential
pools and fallback, progressive tool disclosure, persistent Python kernels,
browser/computer-use/LSP/MCP drivers, checkpoint restore, and a substantially
richer cron runtime. Those capabilities must not remain listed as absent.

## Executive result

Lemon now covers the core non-transport Hermes work loop: local coding tools,
web/browser work, Python execution, MCP and LSP, durable sessions, checkpoints,
memory and skills, native subagents, recurring automation, provider routing,
context compaction, approvals, and operational telemetry. Lemon is already
stronger in native OTP supervision, deterministic simulation/evaluation,
named-node execution, durable multi-agent lineage, and cron lifecycle controls.

The clearest current user-facing runtime hole was Hermes's same-session
heartbeat. Lemon had cron jobs and a separate automation health manager, but it
could not persist one recurring instruction inside the current conversation and
re-enter that conversation only when idle. This pass closes that gap end to end.

The remaining gaps are no longer one missing agent loop. They cluster around
proactive automation suggestions and richer templates, host-side egress
credential injection, micro-compaction, publisher-authenticated updates, and a
few restart/ergonomic edges in asynchronous delegation.

The first-class profile backend also now reaches both product shells: the TUI
browses the live node-aware roster, opens stable canonical chats, and routes
ordinary prompts through `profile.chat`; token-required Web management adds
preview-first create/clone/rename/recoverable-delete over the same store. This
is an ergonomic parity closure, not a second profile engine or persistence
layer.

## Detailed parity matrix

Legend: **covered** means the task is available without an architectural gap;
**lead** means Lemon exposes materially stronger lifecycle or control; **gap**
means Hermes has a current user-facing behavior with no equivalent Lemon path.

| Area | Hermes current behavior | Lemon current behavior | Result / remaining work |
| --- | --- | --- | --- |
| Shell and process work | Shell execution, background processes, process inspection, terminal backends | Approval-gated shell, process manager, background-process state, persistent execution lanes, policy profiles | **Covered**. Hermes has more terminal-backend packaging; no core work-loop blocker. |
| Files and source search | Read/write/patch, grep/find, repo inspection | Read/write/patch, safe local mutation preflight, grep/find, git and repository tools, spill references | **Covered/lead** on mutation safety. |
| Web search and extraction | Search, page fetch, browser and managed tool gateway | Provider-neutral search/extraction with fallback plus multi-tab browser and computer use; `LemonCore.Context` safely previews/resolves public URLs and format-sniffed PDF/Office/notebook/text content through the packaged CLI | **Covered** for bounded text extraction. Scanned/encrypted/font-encoded PDFs deliberately fail closed rather than invoking an unbounded external extractor. |
| Python/code execution | Python execution and programmatic tool calling | `execute_code`, persistent Python kernels, tool calls and structured results | **Covered**. |
| MCP and LSP | MCP tools and progressive disclosure | MCP client/server bridge, LSP driver, capability-aware progressive disclosure | **Covered**. Hermes's single catalog UX is somewhat simpler; Lemon has stronger backend separation. |
| Session durability | Persistent sessions, resume, search, export/prune/stats commands | Shared redacted lifecycle over JSONL/store history with source/package CLI, Web, and TUI search/resume/title/pin/archive/export/prune/delete plus bounded exact aggregate statistics through CLI and read-scoped control plane | **Covered/near** across daily workflows. Lineage, read state, recovery/recap, and richer export formats remain gaps. |
| Checkpoints and rollback | Automatic file checkpoints, list/inspect/restore | Checkpoint/diff/restore tools plus tree-structured session history | **Covered**. Lemon should still consolidate the user guide and make rollback discoverable in every client. |
| Same-session heartbeat | One persisted recurring prompt, idle-only firing, pause/resume/clear, missed-tick coalescing | Added in this pass: durable JSONL heartbeat, same transcript/provider path, user-message priority, pause/resume/clear, restart restore, reset tombstone | **Covered** after this pass. |
| Cron and scheduling | Cron jobs, isolated scheduled turns, schedule management | Cron manager with agent and command jobs, pause/resume/abort, retries/jitter, monitor recovery, preflight, model-drift guard, chained context, and a source/packaged catalog blueprint CLI over exact-confirmed profile skill + cron activation | **Lead** on lifecycle controls. The first safe blueprint UX is covered; richer forms and consent-first suggestions remain a **gap**. |
| Memory | Session search plus long-term memories and learning flows | SQLite full-text durable memory, provider fan-out, session ingest, Honcho provider, scoped tools, auditable `lemon learn`, and token-required `/manage/memory` for bounded/redacted run + learned-provenance inspection and exact revision-bound single-record deletion over the canonical Store | **Covered** for retrieval/storage, bounded source learning, and safe browser inspection. A full journey/learning-graph timeline remains a **gap**. |
| Skills | Install/list/remove skills and official catalog | Registry, discovery, linting, install/import/manage tools, official Hermes catalog browser, curator flows | **Covered**. Ecosystem breadth and single-command import polish still vary. |
| Subagents/delegation | Native subagents, background work, parent interaction | Native `task`, routed `agent`, budgets, run graph, parent questions, isolated `/bg`, named remote nodes | **Lead**. Restart reconciliation for persisted nonterminal asynchronous records and caller-selected join timeouts remain reliability gaps. |
| Provider/model choice | Multiple providers, `hermes auth` credential-pool management, `hermes fallback` inspection/editing, selectable presets and MoA | Provider registry, credential pools, fallback, session pins, routing policy, live model selection, and source/packaged `lemon providers` plus admin `providers.configure` inspection/editing | **Covered** for normal models and operational fallback/pool management. Named mixture-of-agents presets and the Portal subscription proxy remain **gaps**. |
| Specialist profiles and roster | Hermes exposes selectable agent configuration/profile workflows around its runtime | Lemon has durable profiles, isolated derived workspaces, node-aware roster, stable canonical chats, packaged CLI/control plane, TUI roster/lifecycle, and token-required preview-first Web management | **Covered** for normal lifecycle across CLI/TUI/Web. Import/restore, profile-scoped cron, groups, and merged multi-controller rosters remain gaps. |
| Context management | Auto/lean compaction, micro-compaction, tool search | Auto-compaction, overflow recovery, tool-result spill, guardrails, progressive disclosure | **Covered** for context survival. Per-result micro-compaction and provider-native compaction are **gaps**. |
| Approvals and trust | Tool policy, managed scope, sandbox/egress options | Central exec approvals, tool policy profiles, untrusted-result fencing, capability boundaries, node authentication, and explicitly enabled supervised 1Password/Bitwarden/argv-only secret sources behind the encrypted store | **Covered/lead** in local policy and host credential sourcing. Host-side egress credential injection remains a **gap**. |
| Reliability | Persistent sessions, cron recovery, background processes | OTP supervision, durable stores, retries, run ownership, terminalization, named-node cancellation | **Lead**, with the asynchronous boot reconciler noted above still missing. |
| Observability | CLI diagnostics, telemetry and session inspection | structured introspection, run graph, usage/cost diagnostics, proof artifacts, health/readiness, support bundles | **Lead**. |
| Updates and scripting | update command, backup/recovery, config/model/session/cron CLIs | Release channels plus registry-driven non-mutating update plan, exact-confirm apply, private history/receipt-bound rollback; setup/doctor/config/secrets/model/provider/session-statistics/proof commands; script send; and source/packaged atomic backup/verify/restore | **Covered/lead** for safe managed-release and local-state recovery lifecycle. Schema-2 manifests checksum-authenticate artifacts but lack publisher signatures, and the current client has a post-download rather than exact in-flight byte cutoff. Some install-plugin and fleet-restart ergonomics remain gaps. |

## Same-session heartbeat delivered in this pass

The new behavior deliberately matches the important Hermes semantics while
using Lemon's session ownership model:

1. A heartbeat is stored as an append-only `session_heartbeat` custom entry in
   the same JSONL session file.
2. A due heartbeat enters `CodingAgent.Session` as an ordinary user turn, so it
   uses the same transcript, provider, tools, approvals, compaction, and prompt
   cache path as a user prompt.
3. It fires only while the session is idle. A queued prompt, steer, redirect,
   follow-up, parent answer, or asynchronous follow-up wins; missed ticks
   coalesce into one due turn.
4. A fire claim is persisted before provider dispatch. Restarts therefore do
   not replay an already-claimed tick.
5. Pause preserves the instruction. Resume re-anchors the next tick instead of
   immediately replaying stale elapsed time. Clear writes a tombstone so an
   older active record cannot reappear.
6. Reset persists that clear tombstone before rotating the session identity. If
   persistence fails, reset fails without rotation. Cancelled/stale timer tokens
   cannot revive the old heartbeat.
7. Control-plane lookup accepts the logical TUI session key as well as the
   persisted JSONL header ID. Multiple live owners of one logical key fail
   closed with a conflict instead of selecting one arbitrarily.
8. `/heartbeat` and `/hb` expose status, set, pause, resume, and clear in the
   TUI. `sessions.heartbeat` is admin-scoped and validates the runtime response
   before returning it.

See [Session heartbeats](../user-guide/session-heartbeats.md) for usage and the
focused live-runtime proof.

## Provider auth and fallback follow-on

A follow-on source audit compared Hermes's official
[`hermes auth`](https://github.com/NousResearch/hermes-agent/blob/4f22543509d1b91dc45bcb369447126c5eb14fb7/website/docs/reference/cli-commands.md)
and
[`hermes fallback`](https://github.com/NousResearch/hermes-agent/blob/4f22543509d1b91dc45bcb369447126c5eb14fb7/website/docs/user-guide/features/fallback-providers.md)
surfaces with Lemon's actual runtime. Lemon already had the harder execution
semantics—credential pools, health cooldowns, session pins, and provider
fallback—but only the contributor Mix task and read-only `providers.status`
made that state operationally visible. Installed users could not safely edit
fallbacks or pool references.

That UX gap is now closed by one shared provider-configuration boundary used by
source and packaged `lemon providers` commands and the admin-scoped
`providers.configure` method. It edits only `runtime.provider_routing`, accepts
credential references rather than values, preserves comments, validates before
atomic replacement, previews by default at the service/RPC boundary, and
requires exact confirmation for destructive changes. Responses are redacted to
provider/pool names and counts. A deterministic provider-stub smoke starts the
real Lemon applications and proves the configured credential rotation,
cross-provider fallback, destructive guard, and no-fallback HTTP 400 terminal
path without using live credentials.

## Automation blueprint UX follow-on

The already-safe `LemonAutomation.Blueprint` and catalog-scoped control-plane
methods now have one shared source and packaged CLI surface:

- `lemon blueprints` lists the bounded local catalog; inspect and validate show
  only normalized hashes, counts, provenance, policy, and schedule metadata.
- A bundle ID plus `--profile` previews by default. The CLI sends no root,
  path, prompt, skill body, command, environment, or secret field.
- `activate` is the only mutation and requires the exact 64-character digest
  from a fresh preview. The long-running control plane re-plans under the
  existing lock and creates the stable job only through `CronManager.add_new/1`.
- Repeating preview plus activation reports `unchanged` and retains one job.
  JSON success/error documents and exit codes are stable and redact transport
  reasons rather than stringifying runtime terms.

The live blueprint CLI proof drives both the source launcher and an assembled
`lemon_runtime_min` instance against separate temporary homes, catalogs,
profiles, stores, and ports. Both paths perform list/inspect/validate, preview,
activation, and duplicate-safe replay through the real control-plane and cron
manager while asserting that catalog paths, prompt text, the operator token,
and the isolated secrets key never appear in CLI output.

The same boundary now powers the authenticated `/manage/providers` page. Its
fallback, pool, activation, and credential-reference controls are preview-first,
bind apply to an opaque target-config revision, require exact confirmation for
destructive changes, and render only provider/pool identities and counts.
Credential references are re-entered for apply, filtered from LiveView logs,
and never retained or rendered.

The authenticated `/manage/blueprints` page now consumes the shared
`LemonAutomation.Blueprint.Catalog` boundary. It exposes bounded-ID catalog
selection and validation, read-only profile previews, exact digest
confirmation, stale-plan refusal, and duplicate-safe replay. Its independent
LiveView projection excludes manifest prose, prompts, skill bodies, commands,
environment values, paths, tokens, and service error terms from socket state
and rendered HTML.

The Bun TUI now projects the same boundary through `/blueprints` and
`/blueprint`. Its picker, inspect/validate receipts, profile preview, and
activation state allow only bounded IDs, counts, actions, booleans, and
digests. Activation obtains a fresh preview before sending a nonqueueable admin
request; wrong or stale digests mutate nothing, clear the pending plan, and
preserve the profile draft. An authenticated real-Bandit proof drives the
production Bun client through list/inspect/validate, non-mutating preview,
wrong-digest refusal, exact create, and unchanged replay while planted manifest
prose, prompt/skill content, paths, and the operator token remain absent.

## Prioritized remaining runtime work

### P0 — reliability and safety closure

- Reconcile persisted nonterminal background/subagent records at runtime boot so
  accepted work cannot remain permanently ambiguous after a host crash.
- Add explicit caller-selected join timeout/cancellation ergonomics for every
  delegation surface, while retaining server-side hard bounds.
- Build the host-side egress credential-injection boundary before treating
  remote/sandbox execution as safe for arbitrary third-party secrets.

### P1 — high-value user parity

- Extend the shipped 1Password, Bitwarden Secrets Manager, and bounded
  command-backed sources only when a new adapter can preserve the shared
  argv-only runner, bootstrap non-recursion, and value-free diagnostic contract.
- Add an opt-in automation suggestion workflow and richer safe template forms;
  keep suggestions advisory until a user confirms the schedule and destination.
- Add named mixture-of-agents presets through Lemon's existing model-routing
  boundary rather than a parallel agent engine.
- Aggregate session statistics now ship through the shared lifecycle boundary,
  source/package CLI, and read-scoped control plane with exact totals and
  bounded redacted dimensions. Richer lineage/read-state/recovery workflows
  remain the session-management gap.

### P2 — refinement

- Add micro-compaction for individually large tool results and evaluate
  provider-native compaction behind the existing context boundary.
- Extend the shipped `/learn` plus `/manage/memory` provenance view into a
  bounded memory/skill lineage timeline only if it remains a projection over
  Lemon's existing stores.
- Consolidate checkpoints, rollback, memory, scheduling, and model fallback into
  one task-oriented user guide and first-run command discovery path.

## Verification contract

Heartbeat changes should keep these lanes green:

```bash
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=test mix test \
  apps/coding_agent/test/coding_agent/session_heartbeat_test.exs \
  apps/coding_agent/test/coding_agent/session_registry_test.exs --seed 1
MIX_ENV=test mix test \
  apps/lemon_control_plane/test/lemon_control_plane/methods/session_heartbeat_test.exs \
  apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs \
  apps/lemon_control_plane/test/lemon_control_plane/auth/authorize_test.exs --seed 1
cd clients/tui && bun test test/commands/commands.test.ts && bun run check
MIX_ENV=test mix run scripts/live_session_heartbeat_smoke.exs
```

The TUI profile vertical adds focused command and shell integration coverage in
`test/commands/profiles.test.ts` and `test/integration/profiles-app.test.ts`.
Its live proof must cross an authenticated real Bandit WebSocket with isolated
profile state and verify that canonical TUI prompts arrive at `profile.chat`
with stable `agent:<id>:main` routing; fake-server tests alone are not the live
acceptance claim.

The live smoke starts the real control-plane and coding-agent applications,
restores an overdue JSONL session, resolves a logical key that is deliberately
different from its persisted header ID, dispatches the recurring turn through
the normal provider stream, exercises pause/resume/clear through
`sessions.heartbeat`, reloads the file, and verifies the clear tombstone.

Blueprint CLI changes should additionally keep these lanes green:

```bash
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=test mix test \
  apps/lemon_cli/test/lemon_cli/blueprints_command_test.exs \
  apps/lemon_cli/test/lemon_cli/command_registry_test.exs \
  apps/lemon_automation/test/lemon_automation/blueprint_test.exs \
  apps/lemon_control_plane/test/lemon_control_plane/methods/blueprints_test.exs \
  apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs --seed 1
bash -n bin/lemon rel/overlays/bin/lemon scripts/live_blueprint_cli_smoke
scripts/live_blueprint_cli_smoke
```
