# Single Native Top-Level Executor Plan

> **⚠ SUPERSEDED (2026-08-21):** The vendor CLI task-subagent layer this plan
> deliberately *retained* was subsequently removed in full. `lemon_cli_runners`
> (the Claude Code, Codex, Kimi, OpenCode, and Pi runners), the
> `LemonCore.SubagentRunner`/`LemonCore.SubagentRegistry` contracts, and the
> `[runtime.cli.*]` configuration sections no longer exist — `[runtime.cli]` is
> rejected by config validation. **All subagents now run natively in-process**
> as `CodingAgent.Session` executions coordinated by `CodingAgent.Coordinator`.
> This document remains as the historical record of the top-level executor
> cutover; read every "retained vendor task runner" statement below as
> since-deleted.

**Date:** 2026-08-19  
**Status:** Proposed replacement  
**Scope:** Remove external CLIs and custom gateway engines as top-level conversation runtimes while retaining vendor CLIs as task-level subagent runners.

## Decision

Lemon will have exactly one top-level conversation executor: the native `CodingAgent.Session` runtime.

Codex, Claude, Kimi, OpenCode, and Pi will remain available only as CLI-backed delegated task runners registered through `LemonCore.SubagentRegistry` and invoked by CodingAgent's `task` tool. They will not be selectable by channels, router requests, profiles, bindings, webhooks, the control plane, the TUI, persisted session preferences, or model-name inference.

`LemonGateway` remains. It continues to own scheduling, global slots, per-conversation launch serialization, active-run lookup, cancellation, lifecycle normalization, progress mapping, persistence, telemetry, and Bus events. `LemonGateway.Run` will invoke one configured executor module directly instead of resolving an engine ID through `LemonGateway.EngineRegistry`.

The final topology is:

```text
User / channel / control plane / agent tool
  -> LemonCore.RunRequest               # no top-level engine selector
  -> LemonRouter.SubmissionBuilder
       resolves agent, model, thinking, prompt, cwd, policy, native resume,
       queue mode, and conversation identity
  -> LemonCore.ExecutionCommand
  -> LemonGateway.Runtime
  -> Scheduler -> ThreadWorker -> Run
  -> configured singleton CodingAgent.Executor
  -> CodingAgent.Session
       -> task tool
       -> LemonCore.SubagentRegistry
       -> LemonCliRunners.*Subagent
       -> Codex / Claude / Kimi / OpenCode / Pi CLI runner
```

This is also an explicit decision to remove the public custom top-level engine extension contract. `LemonGateway.Engine`, runtime engine registration, custom engine resume syntax, engine-list configuration, and `LemonPlatformTest.EngineCase` will no longer be supported. A custom engine may migrate to `LemonCore.SubagentRunner` only if delegated task semantics are appropriate; there is no replacement plugin API for owning arbitrary top-level conversations.

## Evidence, Reconciliation, and Assumptions

### Confirmed repository facts

1. Ingress builds `%LemonCore.RunRequest{}` and the router resolves it into `%LemonCore.ExecutionCommand{}`. The command currently carries `engine_id`, while model, thinking level, system prompt, agent identity, ACP callbacks, and other execution data are partly carried in `meta`.
2. `LemonRouter.SessionCoordinator` owns queue modes and conversation coordination. `LemonGateway.Scheduler` and `ThreadWorker` use the router-owned `conversation_key`; `LemonGateway.Run` additionally acquires `EngineLock` and currently resolves `job.engine_id` through `EngineRegistry`.
3. `CodingAgent.GatewayEngine.SessionRunner` already contains the production native session-driving behavior: start/resume, event translation, images, tool policy, provider model/thinking/system prompt, ACP filesystem callbacks, async-followup handling, and channel-specific tools.
4. Vendor gateway adapters and vendor task subagents are separate shells over the same CLI runners. The task path does not use Gateway `Scheduler`, `Run`, global slots, or `EngineLock`.
5. `CodingAgent.Tools.Task.Followup` uses `engine_id: "echo"` in a production router fallback for asynchronous task follow-ups. Echo is therefore not test-only.
6. `CodingAgent.Tools.Agent` exposes a model-visible `engine_id` and creates another router-managed top-level run. It is not the CLI task-runner seam.
7. Gateway's current engine behavior has ten callbacks when identity, resume syntax, capability probes, execution, cancellation, steer, and redirect are counted. The singleton needs only the four execution-control callbacks defined below; identity and resume parsing must not be recreated as executor callbacks.
8. `LemonCore.EngineCatalog` hard-codes `lemon`, `echo`, and all vendor IDs. Removing only `SubagentRegistry` synchronization does not make vendor IDs unroutable; the catalog itself and all routing consumers must be removed.
9. `LemonCore.EngineInfoBridge` publishes `:engine_registry`, `:transport_registry`, and `:gateway_config`. Deleting `EngineRegistry` without removing the first capability would silently disable custom resume parsing while leaving a dead contract.
10. Vendor `ResumeFormat` registrations are needed to format and preserve delegated runner resume metadata, but global resume parsing must not be used by top-level/channel resume selection after this cutover.

### Resolved review disagreements

| Question | Resolution |
|---|---|
| Preserve the original architectural direction? | Yes. Both reviews confirmed one native top-level executor, retained Gateway lifecycle ownership, and retained CLI task runners. |
| Delete vendor adapters first? | No. This ordering is unsafe. All supported selectors and stored routing paths become native-only before any selected engine is deleted. |
| Is Echo test infrastructure? | No. Migrate production async-followup fallback to native execution before deleting Echo. |
| Should the singleton copy the full `LemonGateway.Engine` behavior? | No. Define exactly four execution-control callbacks plus the existing sink-message protocol. Drop ID, resume, and capability-probe callbacks. |
| When can `CliAdapter` be deleted? | Native resume formatting and `Renderers.Basic` stop using it in the executor-introduction phase. The module remains only until vendor gateway adapters are removed, then is deleted in the same phase as those adapters. |
| Does removing `routable?/0` decouple task runners from routing? | Not by itself. `EngineCatalog` hard-codes the same IDs, so the catalog and all routing consumers must also be deleted. |
| Rename task parameter `engine` to `runner` now? | No. This cutover preserves the task/subagent public contract and its `"internal"` sentinel. In the task schema, `engine` already means delegated runner ID, not top-level runtime selection. Renaming it is a separate model-facing breaking change and is deferred. This retained field is not a compatibility shim for top-level engines. Documentation must explicitly distinguish the meanings. |
| Is task cancellation already proven? | No. The current abort monitor kills `session.pid`; it does not invoke the optional `SubagentRunner.cancel/1`. The cutover gate must prove the OS subprocess and event stream terminate. The retained path must call runner cancellation when available before falling back to wrapper termination. |
| Are custom engines an implementation detail? | No. `LemonGateway.Engine`, `EngineRegistry`, and `LemonPlatformTest.EngineCase` are documented public contracts. Their removal is an intentional breaking API change and must be released and documented as such. |

### Assumptions and prerequisites

- `CodingAgent.Session` remains the supported product runtime for every top-level run.
- Fixed top-level `engine: "lemon"` fields are retained temporarily as read-only provenance for event/store/API compatibility. They never select execution.
- Vendor task resume identity must remain representable, but accepting a vendor resume token as task input is not required by this change.
- Before rollout, release owners must inventory deployment-local configuration and third-party calls that cannot be discovered in the repository. The diagnostic release described in Phase 0 is the mechanism for doing so.
- The custom-engine removal must ship under the repository's breaking-change/versioning policy. The exact release number is a release-management choice, not an unresolved architecture decision.
- No destructive migration of historical tokens, policies, or RunStore records is allowed during the initial cutover. That retained data is the rollback boundary.

## Scope

### Required cutover work

- Introduce and bind a singleton Gateway executor implemented by CodingAgent.
- Preserve native execution inputs, lifecycle events, cancellation, steer, redirect, queueing, persistence, and health semantics.
- Make every top-level ingress and stored selection path native-only before deleting any engine.
- Migrate Echo-backed async task follow-up delivery to the native parent session path.
- Define explicit native resume and stale-state behavior.
- Remove top-level engine selection from core requests, router logic, CodingAgent's `agent` tool, Gateway/webhook configuration, channels, control plane, TUI, profiles, projects, bindings, and persisted session policy.
- Remove vendor gateway adapters and the `lemon_cli_runners -> lemon_gateway` dependency while retaining vendor subagents, runners, schemas, configuration resolvers, and delegated resume formats.
- Remove the custom Gateway engine public contract, registry, Echo, engine compliance kit, and engine introspection bridge capability.
- Keep top-level runtime provenance and task-runner provenance distinct.
- Update tests, architecture rules, configuration/schema documentation, operator diagnostics, package documentation, changelogs, and product smoke coverage.

### Non-goals

- Collapsing `LemonGateway` into CodingAgent or the router.
- Moving scheduler, slots, RunStore/Bus ownership, or queue coordination.
- Changing normal task concurrency or routing vendor tasks through Gateway slots.
- Adding task-level resume input or continuation to the `task` schema.
- Closing the capability gap between old top-level vendor engines and current task runners.
- Renaming `task.engine`, task result `engine`, or the `"internal"` task sentinel in this change.
- Removing or renaming top-level event provenance fields in this change.
- Removing `ResumeToken.engine`; it remains the namespace for native and delegated tokens.
- Removing `EngineLock` during the functional cutover.
- Renaming every remaining internal use of “engine” where it denotes historical event schema or delegated-runner provenance.
- Collapsing or reversing the existing `coding_agent -> lemon_gateway` dependency.

## Current Architecture

### Top-level execution flow

```text
Ingress
  -> RunRequest(engine_id, model, resume, cwd, policy, metadata)
  -> SubmissionBuilder
       StickyEngine
       ModelSelection(model + inferred engine)
       ResumeResolver(engine-aware explicit/auto resume)
       ConversationKey
  -> ExecutionCommand(engine_id, resolved metadata)
  -> LemonGateway.Runtime
  -> ExecutionRequest -> Types.Job
  -> Scheduler -> ThreadWorker -> Run -> EngineLock
  -> EngineRegistry.get_engine(engine_id)
  -> LemonGateway.Engine.start_run/3
```

For the native path, the registered implementation is `CodingAgent.GatewayEngine`, which starts `CodingAgent.GatewayEngine.SessionRunner`. For vendor paths, `LemonCliRunners.Engines.*` delegates to `LemonGateway.Engines.CliAdapter`. Echo is registered by Gateway and is also used by CodingAgent's router fallback for async task completion.

### Delegated task flow

```text
CodingAgent.Session
  -> task tool (`engine` means task runner)
  -> CodingAgent.Tools.Task.Execution
  -> CodingAgent.Tools.Task.Runner.execute_via_cli_engine/9
  -> LemonCore.SubagentRegistry
  -> LemonCliRunners.*Subagent.start/1
  -> vendor runner process and normalized event stream
```

The task layer owns its own concurrency, progress, result reduction, and abort behavior. It returns answer, error, stderr, requested model/thinking level, current action, and vendor resume-token metadata. It currently starts new CLI sessions; it does not accept a resume token on a later task invocation.

### Current failure domains

- The router owns invalid-request resolution, queue transitions, and conversation identity.
- Gateway `Run` owns top-level start errors, event normalization, persistence, terminal Bus events, progress mappings, slot release, and active-run completion notification.
- The native session runner owns session startup/resume and conversion of session events/crashes into the Gateway sink protocol.
- A vendor task runner fails inside CodingAgent task infrastructure, not inside Gateway. Its OS subprocess is outside the Gateway slot and lock domain.
- `EngineLock` is acquired after a Gateway slot is granted, so lock contention can consume a slot. That is a later cleanup concern, not a reason to alter it during this cutover.

## Target Architecture and Ownership

### Router

The router resolves:

- agent/profile identity;
- model precedence and routing-feedback model choice;
- thinking level and system prompt;
- cwd and tool policy;
- native explicit or auto-resume;
- queue mode and session transition;
- a router-owned `conversation_key`;
- diagnostic rejection of removed engine selectors.

It does not select or infer a runtime.

### Gateway

Gateway owns:

- configured singleton-executor validation;
- global slots and per-conversation FIFO launch;
- active-run lookup and cancellation;
- `Run` lifecycle and exactly-once terminalization;
- Bus events, RunStore records, progress mapping, telemetry, and slot release;
- mapping steer/redirect acceptance back to `ThreadWorker` and router coordination;
- health and introspection of executor readiness.

Gateway does not enumerate executors, parse executor-specific resumes, or depend on CodingAgent at compile time.

### Native executor

`CodingAgent.Executor` owns:

- defensively starting `:coding_agent` when Gateway is already alive;
- starting or resuming one native CodingAgent session;
- preserving all session options and channel-specific extra tools;
- translating session events to the Gateway sink protocol;
- native cancel, steer, and redirect;
- native session persistence and resume-file handling.

### Task layer and vendor package

The task layer continues to own task concurrency, runner discovery, progress, result metadata, and cancellation. `lemon_cli_runners` continues to own vendor CLI configuration, JSONL/event schemas, subprocess runners, `*Subagent` implementations, and vendor resume formats. No vendor package registers with Gateway.

## Invariants

1. **One top-level executor:** every supported top-level run reaches `CodingAgent.Executor`; no runtime ID is resolved per request.
2. **No dangling selector:** no supported selector, stored preference, resume picker, configuration key, or API field can name an engine before that engine is removed.
3. **Gateway lifecycle ownership:** executors emit lifecycle data only to `Run`; they do not write RunStore, release slots, or publish Bus terminal events directly.
4. **Exactly-once finalization:** success, executor start error, start exception/exit/throw, native session crash, cancellation, and missing terminal output result in at most one terminal event, one RunStore finalization, one worker completion, and one slot release.
5. **Resolved execution fidelity:** the executor receives run/session identity, prompt, images, cwd, lane, tool policy, native resume, conversation identity, and existing metadata required by CodingAgent.
6. **Control fidelity:** cancel is total and idempotent for any control context; steer and redirect preserve current router/worker acceptance semantics; redirect falls back to steer only when redirect reports `:unsupported`.
7. **Native resume only at top level:** top-level explicit/automatic resumes accept only `%ResumeToken{engine: "lemon"}`. Vendor tokens are never reinterpreted as native IDs.
8. **Delegated identity remains separate:** task records and results retain the actual runner ID; top-level run records retain fixed `"lemon"` provenance. Neither field controls routing.
9. **No reverse dependency:** `lemon_gateway` never gains a compile-time dependency on `coding_agent`. Root runtime configuration supplies the implementation module.
10. **Task capacity remains separate:** vendor task processes continue to bypass Gateway's global top-level slot cap. Their capacity remains CodingAgent task concurrency and must be documented operationally.
11. **Rollback data is preserved:** historical vendor resume state, session policies, channel indexes, and RunStore records remain readable and are not destructively rewritten during the cutover.
12. **No final compatibility shim:** temporary warnings, hard migration errors, quarantine reads, and the old native adapter may exist between phases; no selector alias, engine registry facade, or deprecated field remains in the final target.

## Public Contracts and Provenance

### Removed public contract

The following are intentionally removed as a breaking change:

- `LemonGateway.Engine`;
- `LemonGateway.EngineRegistry` registration and lookup APIs;
- configured/custom engine module lists;
- custom top-level resume syntax through EngineRegistry/EngineInfoBridge;
- `LemonPlatformTest.EngineCase` and Echo engine compliance fixtures;
- channel and API selection of custom engines.

There is no public general-purpose replacement top-level runtime plugin. Supported migration destinations are:

- a `LemonAi` provider/model integrated into the native session;
- a CodingAgent tool/plugin for agent-visible functionality;
- `LemonCore.SubagentRunner` when the integration is delegated task execution.

The singleton `:lemon_gateway, :executor` binding is product wiring and a test-injection seam, not a documented multi-implementation plugin registry. Production configuration binds `CodingAgent.Executor`; tests may bind one deterministic fake.

### Retained provenance fields

| Surface | Meaning after cutover | Routing role |
|---|---|---|
| Top-level RunStarted/action/completion/RunStore/control-plane `engine` | Fixed `"lemon"` runtime provenance | None |
| Task tool/store/result `engine` | Actual task runner ID such as `codex`, `claude`, or `internal` | Dispatches only within `SubagentRegistry` |
| `ResumeToken.engine` | Resume-token namespace | Top-level accepts only `"lemon"`; task metadata may contain vendor IDs |
| `task.engine` tool parameter | Delegated task-runner choice | Never selects Gateway execution |

Control-plane run projections and TUI session status may continue reading top-level `engine`, but it is read-only provenance. Task views must continue showing vendor runner IDs without rewriting them to `"lemon"`.

## Singleton Executor Contract

Add a Gateway-owned internal behavior, `LemonGateway.Executor`, with exactly four callbacks:

```elixir
@callback start_run(
  request :: LemonGateway.ExecutionRequest.t(),
  opts :: run_opts(),
  sink_pid :: pid()
) :: {:ok, run_ref :: reference(), control_ctx :: term()} | {:error, term()}

@callback cancel(control_ctx :: term()) :: :ok

@callback steer(control_ctx :: term(), text :: String.t()) ::
  :ok | {:error, :unsupported | term()}

@callback redirect(control_ctx :: term(), text :: String.t()) ::
  :ok | {:error, :unsupported | term()}
```

### Callback rules

- `start_run/3` returns a unique `run_ref` and opaque control context or a synchronous error. It must not publish to Bus or RunStore.
- `cancel/1` is total and idempotent for every term, including stale, nil, partial, or already-completed contexts.
- `steer/2` and `redirect/2` return `{:error, :unsupported}` when the operation is unavailable. Other errors reject the corresponding router transition.
- `Run` handles redirect as follows: call `redirect/2`; on `:ok`, acknowledge redirect; on `{:error, :unsupported}`, call `steer/2` and acknowledge/reject as a redirect according to that result; on any other error, reject. The native implementation supports both operations directly.
- Executor identity, resume formatting, resume extraction, resume-line detection, `supports_steer?/0`, and `supports_redirect?/0` are not callbacks.

### Sink protocol

Preserve the current internal message protocol during this cutover:

```elixir
{:engine_event, run_ref, Event.started(fields)}
{:engine_event, run_ref, Event.action_event(fields)}
{:engine_delta, run_ref, text}
{:engine_event, run_ref, Event.completed(fields)}
```

`Run` accepts messages only for its current `run_ref`, appends normalized events, accumulates deltas, and owns terminalization. Renaming these internal messages is deferred; retaining them does not preserve a selectable-engine contract.

### Required request and metadata fidelity

`CodingAgent.Executor` must receive `LemonGateway.ExecutionRequest` directly. The transitional `LemonGateway.Types.Job` adapter is removed in the final cleanup rather than becoming the new executor API.

The request/opts path must preserve:

- `run_id`, `session_key`, `conversation_key`, prompt, images, cwd, lane, native resume, and tool policy;
- `meta[:model]`, `meta[:thinking_level]`, `meta[:system_prompt]`, and `meta[:agent_id]`;
- `meta[:acp_session_id]`, `meta[:acp_client_fs_read_text_file]`, and `meta[:acp_client_fs_write_text_file]`;
- `meta[:async_followups]`/`meta["async_followups"]`;
- origin/channel/progress/notification metadata consumed by Gateway lifecycle code;
- `stream_fn`, stream options, approval timeout, delta callback, and other existing run opts used by native tests/embedders;
- session-key-derived Cron, SMS, Telegram-send-image, and Discord-send-file extra tools.

Making all metadata first-class command fields is a separate schema design. This cutover preserves the existing resolved shape rather than combining two migrations.

### Boot and dependency rules

- Bind `config :lemon_gateway, :executor, CodingAgent.Executor` in top-level runtime configuration.
- `LemonGateway` resolves the module dynamically from configuration. It must not alias, call, or depend on `CodingAgent.Executor` at compile time.
- Gateway validates at boot that exactly one module is configured, loadable, and exports the four callbacks. Missing or invalid production wiring fails startup with an explicit configuration error.
- `LemonGateway.Runtime.available?/0` requires both Scheduler liveness and valid configured-executor wiring. It must not report healthy merely because Scheduler is alive.
- `CodingAgent.Executor.start_run/3` retains defensive `Application.ensure_all_started(:coding_agent)` behavior because Gateway may start first.
- Failure to start CodingAgent returns an executor-start error that `Run` converts into one failed completion; it must not strand a scheduled run.
- Gateway tests bind a deterministic fake executor through test configuration or per-test injection. The fake is test-only and is not shipped as an operator-selectable runtime.

## Native Resume and Stale-State Policy

### Canonical identity

- Keep `%LemonCore.ResumeToken{engine: "lemon", value: session_id}`.
- Keep the router conversation key shape `{:resume, "lemon", session_id}` during this change.
- Keep `ResumeToken.engine` and vendor `ResumeFormat` registrations because delegated results still carry vendor identity and formatting.

### Explicit top-level resume

- Accept only a native token.
- Reject a structured or parsed token whose engine is not `"lemon"` with an actionable `unsupported_top_level_resume_engine` error. Do not silently strip the vendor, reinterpret its value as a CodingAgent session ID, fall back to a new native conversation, or dispatch it to a task runner.
- Channel `/resume` selectors and recent-session menus expose only native records. Canonical native syntax remains `lemon resume <session_id>` plus the existing native index/selection UX.
- A native explicit token whose session file is missing or corrupt fails with an actionable native-resume error. It must not silently create an empty session under the requested ID.

### Automatic resume

- `ResumeResolver` and `SessionCoordinator` use persisted state only when `last_engine == "lemon"` and the token is non-empty.
- Persisted non-native chat state is ignored for selection, logged/telemetrized as legacy state, and left untouched. The next successful native completion may naturally overwrite the current chat state with a native token.
- If a native auto-resume points to a missing or corrupt session file, quarantine it for that attempt, emit a diagnostic, and start a fresh native session. Preserve the stale record until the fresh completion replaces it.
- Stamp resume provenance (`:explicit`, `:auto`, or nil) into resolved execution metadata so the native executor can distinguish explicit failure from automatic stale-state fallback without teaching Gateway about CodingAgent storage paths.

### Channel and history stores

Apply native-only filtering to:

- `LemonCore.ChatStateStore` reads;
- Telegram `StateStore` selected resume values and `ResumeIndexStore` recent/message indexes;
- Discord's `:discord_selected_resume` records;
- RunStore-backed recent resume lists and inline selector parsing;
- session coordination that derives an active conversation key from ChatState.

Do not delete non-native records during the initial rollout. Historical RunStore and control-plane records remain readable. Rollback therefore restores old parsing behavior without requiring a reverse data migration.

### Resume parsing boundary

- Remove the `:engine_registry` capability and `extract_resume/1`/`list_engines/0` functions from `LemonCore.EngineInfoBridge`; retain its transport-registry and gateway-config capabilities.
- Remove `LemonChannels.EngineRegistry`, including its EngineInfoBridge fallback and generic EngineCatalog-based parser. Replace it with a native-only, line-strict resume parser or direct native-only calls to `ResumeToken.extract_resume(text, "lemon")` and `ResumeToken.is_resume_line(line, "lemon")`.
- Never call global `ResumeToken.extract_resume/1` from a top-level/channel resume path, because vendor formats remain globally registered for delegated metadata.

## Echo Async-Followup Migration

Echo deletion is blocked until production async task follow-up behavior is migrated and verified.

`CodingAgent.Tools.Task.Followup` has two paths:

1. delivery to a live parent `CodingAgent.Session` through `handle_async_followup/2`;
2. a router fallback that currently submits `engine_id: "echo"`.

Change the router fallback before removing Echo:

- submit a normal native `RunRequest` with no engine selector;
- preserve parent session key, parent agent ID, cwd, queue mode, task/run IDs, and merged metadata;
- preserve the `"async_followups"` list so `CodingAgent.Executor.SessionRunner` calls `CodingAgent.Session.handle_async_followup/2` rather than treating the text as an unrelated user prompt;
- preserve the unknown-parent-agent fallback to `"default"`;
- preserve `followup`, `steer_backlog`, and other delivery-mode transitions selected by `CodingAgent.AsyncFollowups`;
- ensure task output is not prefixed or transformed by Echo and does not bypass native session policy.

This intentionally changes the router fallback from direct Echo pass-through to native parent-session processing. It may add a native model turn, latency, and cost; that trade is accepted to maintain one top-level policy and presentation owner.

## Capability Tradeoffs

| Capability | Old top-level vendor path | Retained task path / decision |
|---|---|---|
| Direct channel ownership by vendor CLI | Supported | Removed |
| Direct vendor answer as final channel output | Supported | Removed; native agent receives the task result first |
| Vendor top-level resume | Supported | Removed; explicit vendor tokens are rejected at top level |
| Vendor resume identity in delegated result | Supported | Retained as `resume_token` metadata |
| Delegated continuation input | Vendor modules expose resume/continue APIs | Not exposed by current task schema; deferred |
| Images/attachments to vendor CLI | Gateway adapter carried images | Current task schema does not; capability is intentionally lost in this cutover |
| Gateway tool policy/approval context to vendor | Gateway adapter carried policy/session context | Current task path does not provide equivalent propagation; intentionally not added here |
| System prompt and ACP filesystem bridging to vendor | Gateway adapter had plumbing | Not part of current task contract; intentionally lost |
| Vendor stream/progress | Direct top-level stream | Retained as normalized task progress, then summarized/presented by native Lemon |
| Concurrency control | Gateway slots and EngineLock | CodingAgent task concurrency; not capped by Gateway slots |
| Cancellation | Gateway engine cancel callback | Retained task cancellation must prove wrapper and OS subprocess termination |
| Custom arbitrary top-level engine | Public Engine plugin | Removed with no general top-level replacement |
| Model/provider choice | Sometimes inferred a gateway engine from model text | Remains native `LemonAi` model/provider resolution only |

Normal provider/model IDs must continue to resolve through LemonAi. A string formerly treated as an engine or composite engine ID must either be a valid LemonAi model ID or fail with a model-resolution error; it must never select a vendor CLI.

## Required Phase Order

Each phase is independently gated. No later phase begins until its gate passes.

### Phase 0 — Breaking-contract preflight and diagnostics

**Changes**

1. Announce removal of custom `LemonGateway.Engine` support and external top-level engines under the breaking-release policy.
2. Add operator/preflight diagnostics for:
   - gateway/global/project/binding/profile `default_engine` and legacy `engine` aliases;
   - webhook integration `default_engine`;
   - session `preferred_engine`/`preferredEngine`;
   - request `engine_id`/`engineId`;
   - `LEMON_GATEWAY_DEFAULT_ENGINE`;
   - `[gateway.engines.*]`, `config :lemon_gateway, :engines`, persisted `:registered_engines`, and `:lemon_core, :known_engines`;
   - custom engine modules and vendor top-level resume state.
3. Remove engine keys from tracked reference configuration before any adapter becomes unreachable.
4. Document that `[runtime.cli.<vendor>]` remains valid and is not a removed engine configuration surface.
5. Preserve warnings for one migration release, then turn removed public config/API fields into hard actionable errors in Phase 2. Do not silently ignore them.

**Gate**

- The reference configuration contains none of the removed keys.
- A legacy config fixture reports every offending path, including a per-webhook integration default and custom engine module list.
- The diagnostic distinguishes task CLI configuration from top-level engine configuration.
- No runtime behavior has changed.

**Rollback**

Remove the diagnostics. No data or execution path has changed.

### Phase 1 — Introduce and prove the singleton executor alongside the registry

**Changes**

1. Add `LemonGateway.Executor` and configured-module validation.
2. Add `CodingAgent.Executor` and rename/move the current session runner to `CodingAgent.Executor.SessionRunner`.
3. Keep a temporary `CodingAgent.GatewayEngine` adapter delegating to the new executor so registry dispatch remains a rollback path. Delete this adapter later; it is not part of the final target.
4. Bind the production executor in `config/config.exs`; provide deterministic fake-executor injection for Gateway tests.
5. Point native resume parsing/formatting directly at `LemonCore.ResumeToken`.
6. Change `LemonGateway.Renderers.Basic` to format resume tokens through `ResumeToken.format_plain/1`, not an engine module.
7. Make Gateway health and `Runtime.available?/0` validate executor wiring while the old registry still serves runs.
8. Preserve all resolved request fields, metadata, sink events, cancellation, steer, redirect, and channel extra tools.

**Gate**

- Executor contract tests cover start success/error/raise/exit, total cancel, steer, redirect, and redirect-to-steer fallback.
- Native executor tests cover new session, persisted resume, images, model, thinking, system prompt, policy/approval, ACP callbacks, async-followup metadata, and Telegram/Discord extra tools.
- Booting Gateway before CodingAgent and then starting a native run succeeds through the executor implementation.
- Missing/invalid executor configuration is explicitly unhealthy and fails startup; it never accepts a stranded run.
- Existing registry dispatch remains unchanged, providing a configuration/code rollback path.

**Rollback**

Remove the executor binding and new modules; registry behavior is still intact.

### Phase 2 — Make every supported top-level route native-only

This phase is atomic. It occurs while all old engines still exist, so an overlooked selector is caught before deletion rather than becoming an unknown-engine failed conversation.

**Changes**

1. At the router boundary, reject non-nil top-level engine selectors other than the temporary fixed `"lemon"` internal value. Stamp internal execution as `"lemon"` until selection fields are removed later.
2. Remove engine selection from:
   - channel request builders, directives, slash-command options, status text, and bindings;
   - Gateway project/binding/global config and per-webhook integration config/metadata;
   - router public submission, inbox, retries, and profile/session resolution;
   - control-plane `agent.engine_id`, `agent.inbox.send.engineId`, `sessions.patch.preferredEngine`, session/identity `defaultEngine`, and protocol schemas;
   - `CodingAgent.Tools.Agent` schema, validation, labels, and RunRequest construction;
   - TUI `/engine`, `preferredEngine` writes, and routing help;
   - custom engine/operator module-list configuration.
3. Delete `LemonRouter.StickyEngine`; simplify `ModelSelection` to model precedence only while retaining routing-feedback model selection and thinking/system-prompt behavior.
4. Make explicit/automatic resume native-only and quarantine legacy state as specified above.
5. Replace channel custom/generic engine resume parsing with native-only parsing and filter recent session lists/indexes.
6. Migrate `CodingAgent.Tools.Task.Followup` from Echo selection to native/no-selector submission.
7. Keep new top-level event/store provenance fixed at `"lemon"`; keep task runner provenance unchanged.
8. Hard-reject removed config/API fields with actionable errors. Transitional warnings from Phase 0 may remain, but no alias affects execution.

**Gate**

- A matrix covering channels, control plane, `CodingAgent.Tools.Agent`, webhook integrations, TUI, profiles, projects, bindings, inbox/retry paths, and direct `RunRequest` submission proves no supported path can select `echo`, a vendor engine, or a custom engine.
- `/codex`, `/claude`, XMTP directives, Discord's engine option, Telegram engine hints, TUI `/engine`, and legacy API fields are absent or return the documented migration error; none reaches Gateway as an engine ID.
- Provider/model selection still reaches native CodingAgent without engine inference.
- Explicit vendor tokens are rejected; persisted vendor state is ignored without deletion; native recent-session selection remains functional.
- Missing/corrupt explicit native resume fails; missing/corrupt auto-resume starts fresh with a diagnostic.
- Async task router fallback reaches the native parent session, preserves delivery metadata/queue mode, and no code path selects Echo.
- All old engines remain installed for safety, but are unreachable from supported top-level interfaces.

**Rollback**

Re-enable old selector/resume code. Quarantined data was not deleted, so legacy routing can read it again.

### Phase 3 — Switch Gateway `Run` to the singleton executor

**Changes**

1. Make `LemonGateway.Run` resolve the configured executor once and call it directly. Remove per-run `EngineRegistry` lookup and composite engine-prefix fallback from the active path.
2. Pass `ExecutionRequest` directly to the executor; retain the old Job adapter only until final internal cleanup.
3. Store executor module, `run_ref`, and control context in Run state.
4. Preserve Run ownership of started/action/delta/completed processing, rendering, RunStore, Bus, telemetry, progress mapping, cancellation lookup, worker notification, and slot release.
5. Replace capability probes with the four-callback result semantics.
6. Keep `EngineRegistry`, Echo, old native adapter, and vendor adapters present but unused for rollback until the direct path is proven.

**Gate**

- Direct singleton execution passes new, native-resumed, queued, cancelled, steered, redirected, redirect-fallback, crashed-session, executor-start-error, executor-start-exception/exit, and missing-completion scenarios.
- Each terminal scenario proves exactly one terminal Bus event, RunStore finalization, worker completion, and slot release.
- Same session key and same native resume ID serialize; distinct sessions run in parallel up to the slot cap.
- Queue modes `collect`, `followup`, `steer`, `steer_backlog`, `redirect`, and `interrupt` retain existing transitions.
- Health/introspection identifies fixed native executor readiness rather than registry contents.
- Historical records remain readable.

**Rollback**

Switch `Run` back to registry dispatch. Phase 2's fixed native selection still routes only to the temporary native GatewayEngine adapter.

### Phase 4 — Remove vendor Gateway adapters and Gateway dependency

**Changes**

1. Delete `LemonCliRunners.Engines.{Codex,Claude,Kimi,Opencode,Pi}` and their engine tests.
2. Remove `@engines`, `engines/0`, and `register_engines/0` from `LemonCliRunners.Application`.
3. Remove `lemon_gateway` from `apps/lemon_cli_runners/mix.exs` and architecture policy.
4. Delete `LemonGateway.Engines.CliAdapter` and its tests now that neither native nor vendor Gateway execution uses it.
5. Retain vendor `*Subagent`, `*Runner`, `JsonlRunner`, schemas, config resolvers, `ResumeFormat` registrations, `[runtime.cli.*]`, and delegated resume tokens.
6. Remove only Gateway-engine test fixtures; retain and strengthen subagent/runner suites.

**Gate**

- Starting `lemon_cli_runners` registers task runners, CLI config resolvers, and resume formats but performs no Gateway registration.
- Architecture dependency checks prove `lemon_cli_runners` has no Gateway edge.
- Every vendor remains discoverable only through `SubagentRegistry` and task schema.
- Vendor task dispatch, progress/action updates, stderr/decode errors, partial answer, requested model/thinking metadata, and resume token remain intact.
- Task abort invokes runner cancellation when available and proves both the OS subprocess and normalized event stream terminate.
- No task run appears in Gateway RunRegistry, consumes a Gateway slot, or acquires EngineLock.

**Rollback**

Restore the vendor adapter package version and Gateway dependency. Supported top-level selectors remain disabled, so rollback is safe without changing user routing.

### Phase 5 — Remove the obsolete engine platform and public extension contract

**Changes, in order**

1. Stop and remove `CodingAgent.GatewayEngine` registration from `CodingAgent.Application`; keep `CodingAgent.Executor`.
2. Delete the temporary `CodingAgent.GatewayEngine` adapter and old contract tests.
3. Delete `LemonGateway.Engines.Echo` after the async-followup migration gate has passed.
4. Delete `LemonGateway.EngineRegistry` and remove it from `LemonGateway.Application` supervision.
5. Delete `LemonGateway.Engine`.
6. Remove `:engine_registry` and engine resume/list APIs from `LemonCore.EngineInfoBridge`; retain transport-registry and gateway-config capabilities.
7. Replace any health/status/support view of engine enumeration with singleton executor readiness and fixed native provenance.
8. Delete `LemonPlatformTest.EngineCase`, Echo compliance fixtures, the optional Gateway dependency used only by EngineCase, and CodingAgent's EngineCase test dependency.
9. Remove application-env registration/config for custom engines and persisted engine-module lists.
10. Update published extension documentation and changelogs to state that arbitrary top-level engine plugins are no longer supported.

**Gate**

- A full application boot has no EngineRegistry child and reports configured native executor ready.
- No production module calls `EngineRegistry`, implements `LemonGateway.Engine`, or selects Echo.
- `EngineInfoBridge` transport and gateway-config capabilities still work; its engine capability is gone rather than silently unconfigured.
- `LemonPlatformTest.SubagentRunnerCase` and vendor compliance suites remain available; EngineCase is absent from package docs and dependencies.
- The product runtime performs a native top-level run without any engine registration side effect.

**Rollback**

Requires binary/package rollback because the public behavior and registry are deleted. Historical config/state is still preserved, allowing the old binary to read it. Operators must restore the matching pre-cutover configuration snapshot.

### Phase 6 — Remove internal selection fields, catalog coupling, and obsolete adapters

**Changes**

1. Remove `engine_id` from `LemonCore.RunRequest`, `LemonCore.ExecutionCommand`, `LemonGateway.ExecutionRequest`, retry/follow-up builders, inbox APIs, logs, and fixtures.
2. Delete transitional `LemonGateway.Types.Job` and `ExecutionRequest.from_job/2`, `to_job/1`, and other legacy adapters; migrate Run and executor tests to `ExecutionRequest`.
3. Delete `LemonCore.EngineCatalog` and `:known_engines`/`:registered_engines` configuration.
4. Remove `SubagentRunner.routable?/0`, the `routable?` registry entry field, `SubagentRegistry.sync_engine_catalog/1`, and catalog persistence. Keep the task registry unchanged otherwise.
5. Remove `default_engine` from binding/project/profile/Gateway/webhook structs and parsers and `preferred_engine` from active session policy APIs. Raw historical maps may retain unknown keys but no reader consumes them.
6. Update `LemonCore.EngineRuntime` documentation and router/Gateway logs so they describe resolved execution rather than a resolved engine. Renaming that runtime behavior itself is deferred.
7. Keep `ResumeToken.engine`, `ChatState.last_engine` as the native/legacy discriminator during the rollback window, fixed top-level event provenance, and task runner provenance.
8. Remove obsolete engine tests and replace them with executor, native-resume, fixed-provenance, and selection-rejection coverage.
9. Complete documentation, configuration registry, changelog, architecture policy, and product-smoke updates.

**Gate**

- Public and internal top-level request shapes contain no engine selector.
- No model-to-engine inference, sticky engine state, EngineCatalog, routability synchronization, custom engine registration, or engine default remains.
- All current top-level events are fixed to `engine: "lemon"`; task records still report actual runner IDs.
- Architecture rules match the final dependency graph.
- Every verification gate below passes against the final target.

**Rollback**

Requires code rollback. Preserved historical state remains compatible with the old binary; no reverse data migration is needed.

### Phase 7 — Rollout cleanup after the rollback window

This phase is required only for rollout artifacts, not for the architectural target:

- remove temporary warning-only diagnostics once hard errors and migration docs have been available for the agreed support window;
- remove deployment backups/quarantine telemetry according to retention policy;
- do not delete historical vendor tokens or policies unless a separately approved destructive migration proves they are no longer needed for rollback/audit.

It must not reintroduce aliases or compatibility facades.

## Exact Module and File Impact

### Core

**Change**

- `apps/lemon_core/lib/lemon_core/run_request.ex`
- `apps/lemon_core/lib/lemon_core/execution_command.ex`
- `apps/lemon_core/lib/lemon_core/binding.ex`
- `apps/lemon_core/lib/lemon_core/binding_resolver.ex`
- `apps/lemon_core/lib/lemon_core/subagent_runner.ex`
- `apps/lemon_core/lib/lemon_core/subagent_registry.ex`
- `apps/lemon_core/lib/lemon_core/engine_info_bridge.ex`
- `apps/lemon_core/lib/lemon_core/engine_runtime.ex` documentation
- `apps/lemon_core/lib/lemon_core/chat_state.ex` documentation/native discriminator semantics
- `apps/lemon_core/lib/lemon_core/config.ex`
- `apps/lemon_core/lib/lemon_core/gateway_config.ex`
- `apps/lemon_core/lib/lemon_core/config/gateway.ex`
- `apps/lemon_core/lib/lemon_core/config/validator.ex`
- `apps/lemon_core/lib/lemon_core/config_migrator.ex` and/or the active config migration/doctor path
- `apps/lemon_core/lib/lemon_core/env/declarations.ex`
- `apps/lemon_core/lib/lemon_core/quality/architecture_policy.ex`
- `apps/lemon_core/lib/lemon_core/quality/architecture_rules_check.ex`

**Delete**

- `apps/lemon_core/lib/lemon_core/engine_catalog.ex`

**Retain**

- `LemonCore.ResumeToken`, `ResumeFormat`, and `ResumeFormats`;
- `LemonCore.SubagentRunner` and `SubagentRegistry` minus routability coupling;
- ChatState/RunStore historical readability.

### Router

**Change**

- `apps/lemon_router/lib/lemon_router/submission_builder.ex`
- `apps/lemon_router/lib/lemon_router/model_selection.ex`
- `apps/lemon_router/lib/lemon_router/resume_resolver.ex`
- `apps/lemon_router/lib/lemon_router/conversation_key.ex`
- `apps/lemon_router/lib/lemon_router/session_coordinator.ex`
- `apps/lemon_router/lib/lemon_router/agent_profiles.ex`
- `apps/lemon_router/lib/lemon_router/router.ex`
- `apps/lemon_router/lib/lemon_router/run_orchestrator.ex`
- `apps/lemon_router/lib/lemon_router/agent_inbox.ex`
- `apps/lemon_router/lib/lemon_router/run_process.ex`
- `apps/lemon_router/lib/lemon_router/run_process/retry_handler.ex`
- `apps/lemon_router/lib/lemon_router/run_process/compaction_trigger.ex`
- session read-model/state projections that expose `preferred_engine`.

**Delete**

- `apps/lemon_router/lib/lemon_router/sticky_engine.ex`

**Retain**

- `SessionCoordinator`, `SessionTransitions`, queue semantics, conversation keys, routing-feedback model selection, and native completion persistence.

### Gateway

**Add**

- `apps/lemon_gateway/lib/lemon_gateway/executor.ex` for the internal four-callback behavior/config validation.

**Change**

- `apps/lemon_gateway/lib/lemon_gateway/runtime.ex`
- `apps/lemon_gateway/lib/lemon_gateway/execution_request.ex`
- `apps/lemon_gateway/lib/lemon_gateway/run.ex`
- `apps/lemon_gateway/lib/lemon_gateway/application.ex`
- `apps/lemon_gateway/lib/lemon_gateway/renderers/basic.ex`
- `apps/lemon_gateway/lib/lemon_gateway/health.ex`
- `apps/lemon_gateway/lib/lemon_gateway/config.ex`
- `apps/lemon_gateway/lib/lemon_gateway/config_loader.ex`
- `apps/lemon_gateway/lib/lemon_gateway/binding_resolver.ex`
- `apps/lemon_gateway/lib/lemon_gateway/project.ex`
- `apps/lemon_gateway/lib/lemon_gateway/transports/webhook.ex`
- `apps/lemon_gateway/lib/lemon_gateway/transports/webhook/config.ex`
- `apps/lemon_gateway/lib/lemon_gateway/transports/webhook/submission.ex`
- `apps/lemon_gateway/lib/lemon_gateway/transports/webhook/invocation_dispatch.ex`
- health/introspection/support projections that assume engine enumeration.

**Delete**

- `apps/lemon_gateway/lib/lemon_gateway/engine.ex`
- `apps/lemon_gateway/lib/lemon_gateway/engine_registry.ex`
- `apps/lemon_gateway/lib/lemon_gateway/engines/cli_adapter.ex`
- `apps/lemon_gateway/lib/lemon_gateway/engines/echo.ex`
- `LemonGateway.Types.Job` from `apps/lemon_gateway/lib/lemon_gateway/types.ex` after all callers migrate.

**Retain**

- Scheduler, slots, ThreadWorker, RunRegistry, ThreadRegistry, RunSupervisor, Run, Bus/RunStore/progress/telemetry ownership, and initially `EngineLock`.

### CodingAgent

**Add/rename**

- `CodingAgent.Executor`
- `CodingAgent.Executor.SessionRunner`, based on the current GatewayEngine session runner.

**Change**

- `apps/coding_agent/lib/coding_agent/application.ex`
- `apps/coding_agent/lib/coding_agent/tools/task/followup.ex`
- `apps/coding_agent/lib/coding_agent/tools/task/runner.ex` for contract-aware cancellation
- `apps/coding_agent/lib/coding_agent/tools/agent.ex`
- `apps/coding_agent/lib/coding_agent/session/presentation.ex` for explicit-versus-auto stale native resume policy
- `apps/coding_agent/mix.exs` to remove EngineCase-only test dependency.

**Delete after cutover**

- `apps/coding_agent/lib/coding_agent/gateway_engine.ex`
- old `gateway_engine/session_runner.ex` path after migration.

**Retain unchanged in public shape**

- task tool `engine` parameter and `"internal"` sentinel;
- task execution/concurrency/result fields;
- current vendor task dispatch inputs;
- native `CodingAgent.Session` event translator and persistence behavior.

### CLI runners

**Change**

- `apps/lemon_cli_runners/lib/lemon_cli_runners/application.ex`
- `apps/lemon_cli_runners/mix.exs`

**Delete**

- `apps/lemon_cli_runners/lib/lemon_cli_runners/engines/codex.ex`
- `claude.ex`
- `kimi.ex`
- `opencode.ex`
- `pi.ex`
- corresponding `test/lemon_cli_runners/engines/*_engine_test.exs`.

**Retain**

- `jsonl_runner.ex`, all vendor `*Runner` and `*Subagent` modules, vendor schemas, CLI resolvers, resume-format tests, runner tests, and SubagentRunner compliance tests.

### Channels

**Change/delete**

- `apps/lemon_channels/lib/lemon_channels/run_request_builder.ex`
- `apps/lemon_channels/lib/lemon_channels/binding_resolver.ex`
- delete/replace `apps/lemon_channels/lib/lemon_channels/engine_registry.ex` with native-only resume parsing;
- Telegram:
  - `adapters/telegram/transport/update_processor.ex`
  - `transport/inbound_actions.ex`
  - `transport/resume_selection.ex`
  - `transport/per_chat_state.ex`
  - `transport/memory_reflection.ex`
  - `adapters/telegram/transport.ex`
  - renderer/recent-resume index handling;
- Discord:
  - `adapters/discord/slash_commands.ex`
  - `adapters/discord/transport.ex`
  - selected-resume and recent-resume handling;
- XMTP `adapters/xmtp/transport.ex` directive and request construction;
- WhatsApp `adapters/whatsapp/transport.ex` binding/request construction;
- channel status/help/config modules that display engine defaults or directives.

Bindings continue to resolve project, agent, cwd, and queue mode; they no longer resolve an engine.

### Control plane

**Change**

- `apps/lemon_control_plane/lib/lemon_control_plane/methods/agent.ex`
- `methods/agent_inbox_send.ex`
- `methods/sessions_patch.ex`
- `session_model.ex`
- `methods/session_detail.ex`
- `methods/agent_identity_get.ex`
- `protocol/schemas.ex`
- health/readiness/status methods for executor readiness;
- run projections remain read-only fixed `engine: "lemon"`;
- task active/recent projections retain actual runner `engine` values.

Remove selector/override summary flags such as `hasEngineOverride`; do not remove run/task provenance fields merely because they share the word `engine`.

### TUI

**Change**

- `clients/tui/src/commands/index.ts`
- `clients/tui/src/commands/model.ts`
- `clients/tui/src/commands/session.ts`
- `clients/tui/src/protocol/types.ts`
- `clients/tui/src/store/session-store.ts`
- `clients/tui/src/app.ts` and status text as needed.

Delete `/engine` and all `preferredEngine` writes. Keep read-only run provenance from `session.engine`, preferably label it “runtime” in user-facing status. Keep task formatters' `engine` display because it is delegated runner provenance.

### Platform test and test wiring

**Delete/change**

- delete `apps/lemon_platform_test/lib/lemon_platform_test/engine_case.ex`;
- delete `apps/lemon_platform_test/test/compliance/echo_engine_test.exs`;
- update `apps/lemon_platform_test/lib/lemon_platform_test.ex`, `mix.exs`, README, and changelog;
- remove EngineCase from generated docs and remove the optional Gateway dependency if no remaining case uses it;
- delete/replace Gateway registry, Echo, CliAdapter, engine contract, and CodingAgent GatewayEngine tests;
- retain `subagent_runner_case.ex` and vendor compliance suites.

### Runtime configuration, workflows, and operator tooling

**Change**

- `config/config.exs` for singleton binding;
- `config/test.exs` to remove engine lists and use real/fake executor wiring as appropriate;
- other tracked config fixtures containing `default_engine` or custom engine lists;
- `.claude/skills/verify-lemon/SKILL.md` to remove Echo/engine-selector instructions;
- `.github/workflows/product-smoke.yml` to replace the Echo control-plane run with a native run. Use a local deterministic OpenAI-compatible HTTP fixture and native provider configuration rather than shipping a production fake executor or requiring external credentials.

## Verification Gates for the Final Implementation

### 1. Boundary and boot gate

- Dependency policy proves `lemon_cli_runners` has no Gateway dependency and Gateway has no CodingAgent dependency.
- Gateway starts before CodingAgent; the first native run starts CodingAgent and completes.
- Missing/unloadable/malformed executor configuration fails explicitly and reports unhealthy.
- CLI runners start independently and populate only task registries/resume formats/config resolvers.
- Final supervision contains no EngineRegistry.

### 2. Native executor contract gate

- New session and persisted native resume work.
- Explicit/auto resume source reaches the executor.
- Model, thinking, system prompt, agent ID, cwd, images, tool policy, approval context, ACP callbacks, async-followup metadata, stream options, and channel extra tools reach `CodingAgent.Session`.
- Started/delta/action/completed translation, partial output accumulation, usage, reasoning/action events, and native resume token survive.
- Start error/raise/exit/throw, native session crash, cancellation, and no terminal output finalize exactly once.
- Cancel is total/idempotent; steer and redirect work; redirect-to-steer fallback occurs only on `:unsupported`.

### 3. Routing, identity, and concurrency gate

- No supported ingress accepts a non-native top-level selector.
- Same session key serializes new runs.
- Same native resume ID serializes resumed runs.
- Distinct native sessions run concurrently only up to the global slot cap.
- Auto-resume is not stored/published before native completion and cannot create a concurrent resume race.
- Queue modes preserve current state transitions and worker acknowledgements.
- `EngineLock` remains behaviorally unchanged during this cutover.

### 4. Resume and stale-state gate

- Explicit native token resumes the expected persisted session.
- Explicit vendor/custom token fails actionably and never reaches executor start.
- Persisted vendor ChatState, Telegram/Discord selection, and recent indexes are filtered without deletion.
- Missing/corrupt explicit native session fails; missing/corrupt auto-resume starts fresh with a diagnostic.
- Recent-session and inline channel selectors show only native tokens.
- Vendor task resume tokens still format with vendor syntax and remain in task result metadata.
- Historical vendor RunStore records remain readable.

### 5. Echo follow-up gate

- Live-session async follow-up remains unchanged.
- Router fallback uses native/no-selector submission.
- Parent session/agent/cwd, task/run IDs, queue mode, delivery mode, and `async_followups` metadata are preserved.
- Unknown parent agent still retries with `"default"`.
- Follow-up reaches `CodingAgent.Session.handle_async_followup/2`; no Echo prefix or Echo selection remains.
- Echo can be deleted without changing async task tests.

### 6. Task delegation gate

- Each vendor is listed only through `SubagentRegistry` and the task schema.
- External task execution never enters Gateway Scheduler/Run/EngineLock.
- Progress/actions, requested model/thinking metadata, stderr/decode errors, partial answers, errors, and resume token survive.
- Abort invokes vendor cancellation when exported and proves the OS child and event stream stop.
- Task concurrency remains governed by CodingAgent task infrastructure.
- Task stores/control-plane/TUI report the runner ID while the parent top-level run reports `"lemon"`.

### 7. Configuration and public API gate

- Removed config keys and legacy aliases produce actionable migration errors, not silent ignores.
- Fixtures cover gateway, project, binding, profile, session policy, per-webhook integration, environment variable, custom engine module list, and known-engine catalog settings.
- Control-plane schemas do not advertise or accept engine selectors.
- CodingAgent's `agent` tool schema has no `engine_id`; model, agent identity, deterministic delegated session key, queue mode, and `continue_session` still work.
- TUI has no `/engine`; channel slash/directive schemas have no engine option.
- `[runtime.cli.*]` continues to load.
- Normal provider/model identifiers resolve through LemonAi; former engine-only/composite strings fail clearly when not valid models.

### 8. Observability, health, and history gate

- Current RunStarted, action, completion, RunStore, active/recent run, and control-plane views report fixed `engine: "lemon"`.
- Task active/recent views report actual runner IDs.
- Health reports Scheduler plus configured-executor readiness, not registry enumeration.
- Introspection still reports active scheduler/thread/run state and historical records.
- No health/status path silently degrades because `EngineInfoBridge.:engine_registry` disappeared; the capability and consumers are removed together.

### 9. Platform and product gate

- Gateway executor tests replace engine behavior/registry/adapter tests.
- `LemonPlatformTest.EngineCase` is absent; `SubagentRunnerCase` and vendor suites remain.
- Product smoke submits through control plane without `engine_id`, reaches native CodingAgent against a local deterministic provider fixture, and observes the deterministic native answer.
- Architecture rule tests reflect the final dependency graph and reject reintroduction of the CLI-runners-to-Gateway edge or Gateway-to-CodingAgent edge.

## Documentation, Configuration, and Changelog Obligations

Update before the final gate:

- `docs/architecture/overview.md`
- `docs/architecture_boundaries.md`
- `docs/config.md`
- `docs/config-registry.md`
- `docs/model-selection-decoupling.md`
- `docs/platform/lemon_core.md`
- `docs/platform/lemon_platform_test.md`
- `docs/platform/bus-events.md` for fixed top-level provenance versus task-runner provenance
- `docs/for-dummies/02-message-journey.md`
- `docs/for-dummies/04-the-traffic-cop.md`
- `docs/for-dummies/05-the-engine-room.md`
- `docs/for-dummies/08-the-foundation.md`
- `docs/release/versioning_and_channels.md` and release notes for the custom-engine breaking change
- relevant app `README.md`, `AGENTS.md`, and `CHANGELOG.md` files for Core, Router, Gateway, Channels, CLI runners, Control Plane, Platform Test, and CodingAgent where those files exist
- `clients/tui/README.md`
- operator/runtime verification skills and support/doctor documentation.

Documentation must state all of the following without ambiguity:

1. top-level runtime is always native Lemon;
2. `model` selects a LemonAi model/provider, not a CLI runtime;
3. `task.engine` selects a delegated runner and is unrelated to top-level provenance;
4. vendor CLI configuration remains under `[runtime.cli.*]`;
5. vendor top-level resume and custom Gateway engines are removed;
6. fixed run `engine: "lemon"` is compatibility provenance only;
7. vendor tasks are not capped by Gateway top-level slots;
8. current task delegation lacks image, ACP, policy, and continuation parity with the removed top-level vendor path;
9. migration errors and the rollback/quarantine policy are documented;
10. the breaking-change and alternative integration seams are published.

Each affected package changelog must record removals and retained behavior. Do not merely delete old documentation; add migration guidance for operators and third-party Engine implementers.

## Keep / Remove / Defer

| Item | Decision | Notes |
|---|---|---|
| Gateway Runtime/Scheduler/slots/ThreadWorker/Run/registries for runs | **Keep** | Gateway remains lifecycle owner. |
| Router SessionCoordinator and queue modes | **Keep** | No queue-semantics rewrite. |
| Native session-driving and event translator | **Keep/rename** | Move under `CodingAgent.Executor`. |
| EngineLock | **Keep for cutover** | Characterize separately. |
| Fixed top-level `engine: "lemon"` provenance | **Keep initially** | Read-only, never routing. |
| `ResumeToken.engine` and native resume tuple identity | **Keep** | Required to separate native and vendor task tokens. |
| SubagentRunner/SubagentRegistry | **Keep** | Remove only routability/catalog coupling. |
| Vendor runners, subagents, JSONL/schemas, CLI config, resume formats | **Keep** | This is the retained product capability. |
| Task parameter/result `engine` and `"internal"` sentinel | **Keep in this change** | Means delegated runner; rename deferred. |
| Vendor Gateway adapters | **Remove** | Only after selectors are unreachable. |
| Echo | **Remove** | Only after async-followup migration. |
| EngineRegistry/Engine/custom plugin API | **Remove** | Intentional breaking public-contract decision. |
| CliAdapter and Types.Job compatibility layer | **Remove** | Executor consumes ExecutionRequest. |
| EngineCatalog/routable synchronization | **Remove** | Vendor IDs remain only in task registry. |
| Top-level engine selectors/defaults/sticky state/inference | **Remove** | Includes webhook, agent tool, TUI, channels, and control plane. |
| EngineInfoBridge engine capability | **Remove** | Retain transport/config capabilities. |
| Platform EngineCase | **Remove** | Retain SubagentRunnerCase. |
| Task-level resume input/continuation | **Defer** | Resume identity remains in result metadata. |
| Task `engine` -> `runner` rename | **Defer** | Separate model-facing/API migration; no alias when eventually done. |
| Images/policy/ACP parity for vendor tasks | **Defer** | Explicit accepted capability gap. |
| Remove/rename EngineLock | **Defer** | Prove router/Gateway serialization equivalence first. |
| Rename sink messages/event provenance/EngineRuntime | **Defer** | Separate schema/naming cleanup. |
| Delete quarantined historical vendor state | **Defer** | Destructive and harms rollback/audit. |
| Collapse Gateway into Router/CodingAgent | **Reject for this scope** | Mixes scheduler ownership with runtime simplification. |

## Acceptance Criteria

The plan is complete only when all of the following are true:

- Every user-, channel-, control-plane-, webhook-, automation-, TUI-, and agent-initiated top-level conversation executes through `CodingAgent.Executor` and `CodingAgent.Session`.
- No supported selector can target an engine before that engine is removed, and no final selector/default/preference field remains.
- `CodingAgent.Tools.Task.Followup` production router fallback is native and Echo-free before Echo deletion.
- The Gateway has one configured executor, no engine registry, no engine behavior, no Echo, and no vendor CLI adapter.
- The executor implements exactly the four specified callbacks and preserves required request metadata, sink events, cancellation, steer, redirect, fallback, and boot semantics.
- Top-level explicit/auto resume is native-only; non-native and stale state follows the reject/quarantine policy without destructive migration.
- Codex, Claude, Kimi, OpenCode, and Pi remain task runners with progress, errors, cancellation, requested model/thinking metadata, and vendor resume-token identity.
- `lemon_cli_runners` has no dependency on `lemon_gateway` and performs no Gateway registration at boot.
- Custom Gateway engines are explicitly removed as a breaking public contract, with migration destinations and release notes.
- `CodingAgent.Tools.Agent`, webhook per-integration defaults, EngineInfoBridge, control-plane schemas, TUI/channel selectors, persisted policies/tokens, health/introspection, architecture rules, platform tests, product smoke, configuration docs, and changelogs all match the target.
- Top-level run provenance remains fixed `"lemon"`; task runner provenance remains the actual task runner; no code conflates the two.
- Gateway scheduling, RunStore/Bus ownership, queue modes, concurrency, cancellation, native resume, steer, redirect, and exactly-once terminalization pass their gates.
- No compatibility shim, selector alias, deprecated field, engine registry facade, or obsolete adapter remains in the final target.