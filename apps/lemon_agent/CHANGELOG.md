# Changelog

All notable changes to `lemon_agent` are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
releases follow [Semantic Versioning](https://semver.org/) from `0.1.0` onward.

## [Unreleased]

**Release version: 0.3.0.**

### Added

- `LemonAgent.AbortSignal.t()` (an `:atomics` reference); abort-signal,
  loop-input and callback typespecs now use it, and the package is
  Dialyzer-clean (#734). No runtime change.
- `LemonAgent.ModelRuntime.OmpBroker.url/0` and `default_url/0` expose the
  broker URL resolution without requiring a token.
- `submit_result` structured subagent results (#602); task-tool action
  telemetry only (#604); optional advisor reviewing each turn (#600);
  experimental opt-in `code_mode` profile (#598).
- Durable steering and follow-up acceptance with withdraw RPCs (#559);
  default-off `features.crash_resume` re-drives cut-off task children (#558).
- `gen_statem` lifecycles (#588), non-blocking callbacks (#587), hibernating
  idle subagents with batched completions (#597), supervision subtrees with
  bounded task admission (#585).
- `LemonAgent.InterruptedToolResult`: one builder for interrupted tool results
  with structured `outcome` (`:unknown | :not_started`) and `reason` (#552).
- `LemonAgent.AbortSignal.subscribe/1`: abort and redirect are delivered as
  `{:lemon_abort, ref, kind}` messages to subscribers (#549).
- Optional GenAI span exporter behaviour with an OpenTelemetry adapter
  (`opentelemetry_api` is optional) (#594).
- `KanbanStore.renew_task_lease/3`: exact-lease guarded lease renewal (#596).
- `AgentTool` `:effect` (`:none | :idempotent | :external`, default `:external`);
  effectful tools cannot start work from `on_stream` (#554).
- `LemonAgent.StreamRules`: dormant `streamPattern` rules that abort and retry
  the model stream with a correction (#599).

- `auth_source = "omp_broker"` resolves any provider's credential from omp's
  auth broker (`LemonAgent.ModelRuntime.OmpBroker`), authoritative and
  fail-closed, with broker-side auth recovery after a rejected token. The
  `omp_gateway` provider falls back to omp's `auth-gateway.token`.
- Broker-backed credentials rotate across all of a provider's broker accounts:
  a provider rate limit (429/quota) is reported to the broker as a catch-all
  block (asynchronous, best-effort) and the same turn retries on the next
  broker account before failing over to another provider.
- `Agent.steer/3` accepts `preempt: false` for synchronous acceptance of
  agent-originated messages at the next turn boundary without skipping issued
  tool calls. Human steering takes priority and keeps its preemption semantics.
  Accepted turn input also survives the final follow-up polling race and remains
  queued when a finite tool-turn budget stops before its delivery.
- `kimi_coding` can select `auth_source = "omp"` to reuse omp's subscription
  login instead of environment or inline API keys, including forced refresh
  after credential rejection and redacted readiness status.
- Opt-in automatic model routing via `[model_routing]` (ordered rules with
  `contains`/`min_chars`/`max_chars`, per-request catalog-projected
  `max_cost_usd` cap that fails closed on unknown pricing, including configured
  additions without explicit pricing, and accounts conservatively for Anthropic
  thinking-output expansion). Explicit model selection always bypasses it.

### Changed

- **Breaking (0.3.0):** agent events are delta-only (#571). Migration: handlers
  must accumulate deltas instead of expecting full partial messages on every
  event; `{:message_update, message, event}` becomes `{:message_update, event}`.
- **Breaking (0.3.0):** steering and follow-up acceptance is acknowledged and
  journaled, and queue settings live in `AgentLoopConfig.hooks` (#559).
  Migration: update custom queue hooks to the acknowledged contract and use
  `Agent.has_steering_messages?/2` for queue checks.
- **Breaking (0.3.0):** retry helpers move to `LemonAi.Retry` (#592).
- Note: `AgentLoopConfig.emit_system_prompt`, `.stream_rules` and
  `.on_stream_rule` live in the new `.hooks` map (same keys, defaults `false`,
  `[]`, `nil`); use `.hooks` for struct literals and field reads.
- `LemonAgent.EventStream` is a facade over the single `LemonAi.EventStream`;
  `push/2` returns `:ok | {:error, :overflow | :canceled}` and no longer times
  out, so producers must handle rejection (#570).
- `AgentLoopConfig`/`Context` system prompts accept `LemonAi.SystemPrompt` blocks
  as well as strings (#563).
- `AbortSignal` levels live in `:atomics` and are garbage-collected with their
  holders; `AbortSignal.TableOwner` and `AbortSignal.clear/1` are removed (#549).

- Queues always consume one message per turn; removed queue mode options,
  mode accessors, queue-clearing helpers, and `Agent.set_session_id/2`.
- Removed the unused `SubagentSupervisor`, registry metadata/session/role
  query helpers, and unguarded `KanbanStore.complete_task/2` and `fail_task/3`.
  Task terminalization uses the lease-guarded APIs.
- Centralized provider ID normalization and passed Azure resolver settings
  explicitly, retaining the provider's existing wire options.
- Unified tool abort checks on `AbortHelpers.check_abort/1`.
- The response loop owns one retry budget (three retries by default), disabling
  nested provider retries so a response makes at most four upstream attempts.
  Rate/concurrency throttles wait at least 10 seconds plus jitter and honor
  server hints; quota exhaustion fails fast with reset details. Idle stream
  timeouts consume the same budget, while abort interrupts retry backoff.
- Provider response options retain `stream_idle_timeout` (300,000 ms silence)
  alongside `stream_timeout` (1,800,000 ms hard ceiling). Standalone event streams
  reset idle expiry on every event; whole-run streams disable both limits so
  long-running tools do not cancel a healthy run.

- Tool registrations expose explicit `{name, module, native_process_ownership}`
  provenance. Unknown contributed tools durably fence module loading,
  construction and execution when native evaluation tracking is enabled;
  audited managed registrations retain their normal launch accounting.
- Normalize aliases and use implicit function-level exception handling in the
  agent loop and its regression tests; runtime behavior is unchanged.
- Anthropic OAuth resolution fails closed: a stored Lemon login that cannot
  refresh or persist now yields no credential instead of falling back to
  ambient Claude Code tokens. OAuth secret resolution passes `:reload_secret`
  so refresh helpers can re-read the secret under their refresh lock.
- OAuth refresh persistence is conditional on the exact encrypted-store login
  revision. A login replacement or logout during a token request wins; the
  obsolete response cannot overwrite it or become selected authentication.
  Storage failures stop refresh resolution without replaying the request.
- Tool execution defaults to a 300,000 ms deadline and at most eight concurrent
  calls. `:infinity` explicitly opts out. `AgentTool.timeout_ms` overrides the
  deadline; native task/wait, delegation, bash, eval, debug, question and browser
  tools retain their own deadlines instead of racing the generic timer.

### Fixed

- OAuth credential resolution, including the Anthropic and Codex paths, adopts
  a login refreshed concurrently by another process instead of returning
  `:oauth_secret_changed` when that login is still fresh.
- Run/session usage budgets fail closed when capped token totals or accumulated
  or projected dollar spend are unknown. Partial provider reports retain their
  nullable telemetry; unknown enforcement totals survive later reports, native
  descendant aggregation, and persisted session restoration instead of becoming
  zero-cost authorization.
- Emit one provider-usage observation per completed attempt, including failed
  retries and empty-response continuations omitted from transcript history;
  native run accounting no longer drops their reported spend.
- Proxy streams preserve nullable usage and costs when replaying restored
  assistant history, rather than crashing request encoding or treating absent
  response counters as measured zero. Offline loopback fixtures cover both sides.
- `Agent.follow_up/3` acknowledges enqueue synchronously, so callers can order
  delivery before releasing active tools. Acceptance does not start an idle
  agent or continue a completed, failed or cancelled run automatically; normal
  in-loop follow-ups retain the ordinary single terminal lifecycle.

## [0.2.0] - 2026-10-13

First release as a standalone package. `lemon_agent` is the `:lemon_agent`
application from the Lemon umbrella; the OTP application name and every
`LemonAgent.*` module name are unchanged.

### Removed

- `LemonAgent.Workspace.HeartbeatStore`; heartbeat configuration and results now
  use automation cron jobs and cron history.

### Fixed

- Rescued agent-loop failures persist their assistant error message and emit an
  error terminal rather than a successful `agent_end`.
- `LemonAgent.ModelRuntime.Credentials` returns the result of storing a
  refreshed OAuth secret instead of `:ok`, so a refused write (for example
  `{:error, :secrets_locked}` during a master-key rotation) fails the
  resolution. A recognised OAuth payload that cannot be resolved now yields no
  credential, rather than the raw payload being used as an API key; the
  warning logs only the error's tag.
- Installable from Hex. The `0.1.0` release's `mix.exs` began with
  `Code.require_file("../../hex_package.exs", __DIR__)`, a file that was not in
  the package, so it failed to load in every consumer project; `0.1.0` is
  retired. The shipped `mix.exs` is now self-contained, and requires
  `lemon_ai` and `lemon_core` as `~> 0.2`.

### Added

- `LemonAgent.ToolRegistry` — runtime tool registration backed by
  `:persistent_term`, so a library or satellite package can add tools to an
  agent without the agent knowing about it at compile time. Built-in tools win
  on a name collision, which keeps a third-party registration from shadowing
  core behaviour by accident. This is the tool-side analogue of the channel
  adapter and engine registries.
- `LemonAgent.Workspace.GoalStore` and `.KanbanStore` — the
  multi-agent work-coordination stores, moved here from `lemon_core`. They are
  built purely on core primitives and every consumer already depended on this
  package.
- `LemonAgent.ProviderConfigResolver` — provider configuration resolution, moved
  here from `lemon_core`, where it had exactly one consumer.
- `LemonAgent.Env` declares the environment variables this package reads, with
  types, defaults and documentation. `LemonCore.Env` aggregates it when present.

### Changed

- `LemonAgent.Security.ExternalContent` is the canonical implementation for
  wrapping untrusted external content. It stays in this package rather than
  moving to `lemon_core` because it is defined in terms of
  `LemonAgent.Types.AgentToolResult` and `LemonAi.Types.TextContent`; a package that
  knows nothing about agents or models cannot host it.
- Vendor-specific social tools are not shipped by the Lemon harness. External
  packages can contribute their own tools through `LemonAgent.ToolRegistry`
  without adding compile-time knowledge to this package.

### Notes

- Depends only on `lemon_ai` and `lemon_core`. This is the package to build on
  if you want an agent loop and tools without a router, channels or a gateway.
