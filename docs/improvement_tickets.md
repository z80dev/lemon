# Improvement Tickets

Potential improvements brainstormed per app. Status: `[ ]` open, `[x]` done, `[-]` won't do.

---

## agent_core

| # | Ticket | Description | Status |
|---|--------|-------------|--------|
| AC-1 | Per-tool execution timeouts | Add optional `timeout_ms` to `AgentTool` struct so slow tools get auto-killed in `Loop.ToolCalls.execute_and_collect_tools/6` instead of blocking indefinitely. | `[ ]` |
| AC-2 | Streaming progress callbacks for tools | Add `on_progress(percent, status)` callback alongside `on_update` and emit `{:tool_execution_progress, id, percent, status}` events through `EventStream`. | `[ ]` |
| AC-3 | EventStream backpressure telemetry | Emit `[:agent_core, :event_stream, :backpressure]` and `[:agent_core, :event_stream, :dropped]` telemetry events so operators can monitor queue saturation. | `[ ]` |
| AC-4 | `Agent.get_metrics/1` API | Return `%{queue_size, max_queue, dropped_count, loop_runtime_ms, tool_execution_total_ms, tool_count}` for debugging streaming issues. | `[ ]` |
| AC-5 | Content versioning for CLI runner resumption | Add `content_hash` to context and validate on resume to detect mid-session credential/context changes before continuing. | `[ ]` |

## ai

| # | Ticket | Description | Status |
|---|--------|-------------|--------|
| AI-1 | Pre-request cost estimation | Add `estimate_cost/2` accepting `(model, input_tokens_estimated)` returning predicted output cost range (low/high) for budget enforcement before starting expensive requests. | `[ ]` |
| AI-2 | Token limit enforcer at stream level | Add optional `max_output_tokens` to `StreamOptions` that triggers automatic cancellation with `:token_limit_exceeded` stop reason when streaming output exceeds threshold. | `[ ]` |
| AI-3 | Dynamic provider capability flags | Add `get_provider_capabilities(provider)` returning `%{supports_vision, supports_tool_use, supports_parallel_tool_calls, max_parallel_calls}` for smart model routing. | `[ ]` |
| AI-4 | Real-time usage aggregation during streaming | Add `EventStream.aggregate_usage/1` for mid-conversation budget enforcement rather than post-completion only. | `[ ]` |
| AI-5 | Provider error diagnostics buffer | Rotating buffer of detailed error bundles (request signature, error classification, retry advice, rate limit headers) accessible via `Ai.ErrorDiagnostics.recent_errors/1`. | `[ ]` |

## coding_agent

| # | Ticket | Description | Status |
|---|--------|-------------|--------|
| CA-1 | Session replay mode | `CodingAgent.Session.replay(session_file, from_entry_id, new_tools)` to replay saved JSONL sessions with different tool implementations for side-by-side comparison. | `[ ]` |
| CA-2 | Priority queue in LaneQueue | Add `:priority` field to task submission so critical subagents run ahead of background work without blocking the main loop. | `[ ]` |
| CA-3 | Contextual tool recommendation | `Session.get_suggested_tools(session, prompt_prefix)` using lightweight LLM/embedding ranking to surface top-5 relevant tools with usage hints. | `[ ]` |
| CA-4 | Soft budget limit warnings | `BudgetTracker.soft_limit_warnings/1` returning `%{tokens_used_percent, cost_used_percent, estimated_total_cost}` for graceful degradation before hard limits crash. | `[ ]` |
| CA-5 | Session health check with auto-recovery | `Session.health_check/1` returning `%{is_healthy, stale_tasks, orphaned_locks, recommendations}` with safe ETS/DETS cleanup preserving JSONL history. | `[ ]` |

## coding_agent_ui

| # | Ticket | Description | Status |
|---|--------|-------------|--------|
| CU-1 | Per-request timeout override with validation | Allow callers to specify request-level timeouts via `:timeout` opt, clamped to a configured `max_call_timeout`. | `[ ]` |
| CU-2 | Connection health check (ping/pong) | `ping/1` function returning `{:ok, latency_ms}` or `{:error, :timeout}` to detect stale RPC connections early. | `[ ]` |
| CU-3 | Structured logging with request correlation IDs | Add `request_id: uuid` to all GenServer messages and Logger calls for full request lifecycle tracing. | `[ ]` |
| CU-4 | Concurrent request limit with backpressure | Cap pending requests (default 100), reject with `{:error, :backpressure}` when exceeded to prevent memory bloat. | `[ ]` |
| CU-5 | Debug state snapshot function | `debug_state/1` returning `%{pending_count, input_closed, editor_text, reader_task_status}` without blocking the GenServer. | `[ ]` |

## lemon_automation

| # | Ticket | Description | Status |
|---|--------|-------------|--------|
| LA-1 | Job dry-run capability | `CronSchedule.dry_run(schedule, tz, count: 5)` to preview next N execution times without creating a job. | `[ ]` |
| LA-2 | Auto-disable on repeated failures | Disable jobs after 5 consecutive timeouts with configurable threshold and 24h cooldown re-enable. | `[ ]` |
| LA-3 | Memory file versioning and rollback | Keep last 10 versions of per-job memory snapshots with `CronMemory.get_version(job_id, timestamp_ms)` for debugging. | `[ ]` |
| LA-4 | Predictive load balancing via jitter | Auto-spread overlapping job schedules with per-job jitter to prevent execution clustering during tick intervals. | `[ ]` |
| LA-5 | Templated run result summaries | Configurable `:summary_template` field on jobs with variable interpolation for consistent operator-facing output. | `[ ]` |

## lemon_channels

| # | Ticket | Description | Status |
|---|--------|-------------|--------|
| LC-1 | Adapter health check with degradation mode | Periodic ping via `Registry.healthcheck/1`, mark adapters `:degraded` after 3 failures, route to fallback adapter. | `[ ]` |
| LC-2 | Delivery priority and fairness | `:high/:normal/:low` priority on `OutboundPayload` with per-group fairness throttle to prevent starvation. | `[ ]` |
| LC-3 | Per-adapter chunking strategies | Configurable `:sentence/:word/:paragraph/:custom_regex` chunking instead of hardcoded sentence splitting. | `[ ]` |
| LC-4 | Safe rendering with fallback | Catch renderer exceptions in `Dispatcher`, log with context, fall back to plain-text instead of silencing conversations. | `[ ]` |
| LC-5 | Message delivery attestation | Signed delivery proofs `{payload_hash, platform_response, timestamp}` in a rotating attestation log for compliance audits. | `[ ]` |

## lemon_control_plane

| # | Ticket | Description | Status |
|---|--------|-------------|--------|
| CP-1 | Structured logging with correlation IDs | Add correlation IDs to frame processing for tracing requests through auth, validation, and handler execution. | `[ ]` |
| CP-2 | Per-connection WS rate limiting | Track per-connection request windows with proper 429 headers and retry-after values. | `[ ]` |
| CP-3 | Pre-computed schema validation via ETS | Cache static schemas at startup for direct ETS lookup instead of repeated pattern matching on every request. | `[ ]` |
| CP-4 | Capability-gated method discovery | Make `hello-ok` method/event lists dynamic based on actual capabilities config so clients can adapt. | `[ ]` |
| CP-5 | Centralized error serialization | Extract error transformations (redacting sensitive details) into a dedicated protocol handler module. | `[ ]` |

## lemon_core

| # | Ticket | Description | Status |
|---|--------|-------------|--------|
| CO-1 | Storage backend health check | `Store.health_check/0` returning latency, table counts, last operation time for monitoring and circuit breaker decisions. | `[ ]` |
| CO-2 | JSONL schema migration helpers | Versioned file headers with `JsonlBackend.Migration` helpers for automatic data transformation on codec changes. | `[ ]` |
| CO-3 | Bus topic namespacing | `Bus.Namespace` helper scoping topics to app names (e.g., `"router:run:id"`) to prevent cross-app event misrouting. | `[ ]` |
| CO-4 | Config validation caching with fingerprints | Cache validation results alongside config fingerprints so repeated loads of unchanged config skip validation. | `[ ]` |
| CO-5 | Store wrapper generator macro | `LemonCore.Store.Wrapper.define/2` macro to auto-generate typed wrappers and eliminate identical boilerplate. | `[ ]` |

## lemon_gateway

| # | Ticket | Description | Status |
|---|--------|-------------|--------|
| GW-1 | Queue drain on ThreadWorker termination | Requeue orphaned execution requests back to the Scheduler instead of silently dropping them. | `[ ]` |
| GW-2 | Adaptive slot request timeout with backoff | Exponential backoff in `Scheduler.handle_info(:check_slot_timeouts)` for workers with consistently long wait queues. | `[ ]` |
| GW-3 | Structured logging with run lifecycle context | Persistent Logger metadata with `run_id`, `engine_id`, `session_key`, `thread_key` on all run-related log calls. | `[ ]` |
| GW-4 | EngineLock contention telemetry | Histogram tracking lock wait times, waiter counts per thread_key, and reap events via `LemonCore.Telemetry`. | `[ ]` |
| GW-5 | Stricter ExecutionRequest contract validation | `@enforce_keys` and documentation clarifying required vs optional fields per submission path. | `[ ]` |

## lemon_mcp

| # | Ticket | Description | Status |
|---|--------|-------------|--------|
| MC-1 | Request backpressure with max pending limit | Configurable max pending request limit, reject with automatic rejection when exceeded to prevent memory leaks. | `[ ]` |
| MC-2 | Subprocess health monitoring | Periodic heartbeat pings to detect stalled-but-alive MCP servers with automatic reconnection logic. | `[ ]` |
| MC-3 | Pre-execution parameter schema validation | Validate tool args against JSON Schema `inputSchema` before calling, returning `{:error, :invalid_tool_arguments}` with field details. | `[ ]` |
| MC-4 | Tool schema caching | Memoize tool definitions per `{module, cwd}` pair to avoid repeated fetches in `ToolAdapter`. | `[ ]` |
| MC-5 | Protocol version negotiation with fallback | Attempt initialization with target version, fall back to older supported versions on mismatch. | `[ ]` |

## lemon_router

| # | Ticket | Description | Status |
|---|--------|-------------|--------|
| LR-1 | Queue mode conflict detection telemetry | Surface degradations (`:steer` -> `:followup`) with reason, original_mode, fallback_mode, engine_id context. | `[ ]` |
| LR-2 | Session queue depth and residence time histograms | Track wait durations before execution and identify conversations with pathological queue backlogs. | `[ ]` |
| LR-3 | Bounded pending compaction markers | Cap marker count per session to prevent unbounded creation, with telemetry when limit is approached. | `[ ]` |
| LR-4 | Sticky engine staleness detection | Detect disabled/removed engines on resume, auto-fallback to default via `EngineCatalog` with telemetry. | `[ ]` |
| LR-5 | Separate semantic buffer from platform delivery | Explicit `SemanticBuffer` stage operating independently of transport-level constraints in `StreamCoalescer`. | `[ ]` |

## lemon_services

| # | Ticket | Description | Status |
|---|--------|-------------|--------|
| LS-1 | Configurable restart policy module | Extract hardcoded `@restart_delays` into a `RestartPolicy` behaviour customizable per service via Definition. | `[ ]` |
| LS-2 | Per-service health check timeout | Add `health_check_timeout_ms` to Definition (default 5000) instead of hardcoded value in `health_checker.ex`. | `[ ]` |
| LS-3 | Streaming log retrieval | `stream_logs/2` returning a lazy Stream with offset/limit pagination for large log volumes. | `[ ]` |
| LS-4 | Service dependency ordering | `depends_on: [:postgres, :redis]` field in Definition that blocks startup until dependencies are healthy. | `[ ]` |
| LS-5 | Structured exit reason tracking | Distinguish exit codes, signals (SIGKILL/SIGTERM), and timeouts in State struct and PubSub events. | `[ ]` |

## lemon_sim

| # | Ticket | Description | Status |
|---|--------|-------------|--------|
| SM-1 | Turn-level metadata in State | Add `current_turn: non_neg_integer()` field so projectors and decision frames can reference turn numbers natively. | `[ ]` |
| SM-2 | Event validation hooks before ingest | Optional `event_validator` behaviour with `validate(event) -> :ok \| {:error, reason}` to catch malformed events early. | `[ ]` |
| SM-3 | Structured DecisionOutcome struct | Replace opaque `decision: map()` with typed fields: `decision_text`, `tool_calls`, `reasoning`, `cost` tier. | `[ ]` |
| SM-4 | Pluggable state compression | Optional `state_compressor` behaviour to summarize old plan steps at 100+ turns, reducing serialization cost. | `[ ]` |
| SM-5 | Decision trace collector | Optional `trace_decisions: true` flag collecting full decision frames for introspecting model choices. | `[ ]` |

## lemon_sim_ui

| # | Ticket | Description | Status |
|---|--------|-------------|--------|
| SU-1 | Performance metrics dashboard | Per-turn stats (decision latency, tool calls, token usage, state size) with toggleable time-series graph. | `[ ]` |
| SU-2 | Incremental board rendering via LiveComponents | Only re-render changed cells/cards to reduce WebSocket payload from MBs to KBs on long games. | `[ ]` |
| SU-3 | Configurable simulation speed controls | 1x/2x/5x/10x speed slider and pause/resume buttons via `SimManager.set_speed/2`. | `[ ]` |
| SU-4 | Side-by-side replay comparison | Split pane showing two sims with different models, highlighting decision divergence points. | `[ ]` |
| SU-5 | Live memory file editing | In-dashboard code editor for memory files that syncs changes back to store mid-simulation. | `[ ]` |

## lemon_skills

| # | Ticket | Description | Status |
|---|--------|-------------|--------|
| SK-1 | Circular dependency detection | Graph traversal in `Manifest.Validator` to reject skills with circular skill-to-skill dependencies. | `[ ]` |
| SK-2 | Content-hash manifest cache | Skip re-parsing identical SKILL.md files across instances using hash-keyed cache in Registry. | `[ ]` |
| SK-3 | Structured telemetry for skill operations | `:telemetry.span/3` on install, audit, and register for adoption/failure rate dashboards. | `[ ]` |
| SK-4 | Manifest version migration system | Versioned schema definitions with automatic field promotion for forward-compatible skill evolution. | `[ ]` |
| SK-5 | Skill preview mode | `Installer.preview/2` returning human-readable audit findings report before committing to install. | `[ ]` |

## lemon_web

| # | Ticket | Description | Status |
|---|--------|-------------|--------|
| LW-1 | Message pagination with lazy-loading | Persist to SQLite with cursor-based pagination instead of capping at 250 in-memory messages. | `[ ]` |
| LW-2 | Message search component | Debounced content search with highlighted matches in message bubbles. | `[ ]` |
| LW-3 | Pluggable upload storage backend | `UploadStore` behaviour with FileSystem/Memory/S3 implementations. | `[ ]` |
| LW-4 | Exponential backoff retry for failed submissions | Wrap `LemonRouter.submit/1` with retries and "Retrying..." UI indicator. | `[ ]` |
| LW-5 | Message delivery receipts | PubSub-based `:prompt_received` acknowledgments to prevent duplicate submissions on reconnect. | `[ ]` |

## market_intel

| # | Ticket | Description | Status |
|---|--------|-------------|--------|
| MI-1 | Circuit breaker for external API calls | Track failures per URL in `HttpClient`, return `:circuit_open` after 5 consecutive errors with exponential backoff reset. | `[ ]` |
| MI-2 | Commentary audit ledger | Immutable log of trigger context, market data, AI prompt, and response for compliance replay. | `[ ]` |
| MI-3 | Adaptive price spike thresholds | Replace fixed 10% threshold with volatility-adjusted detection (`median_volatility * 1.5`) in `DexScreener.check_price_signals/1`. | `[ ]` |
| MI-4 | Pre-compiled prompt templates | Handlebars-style templates per vibe/trigger combo to reduce prompt construction overhead in `PromptBuilder`. | `[ ]` |
| MI-5 | Dry-run mode for full pipeline | Log prompts and responses without posting to X, stored with `dry_run: true` flag for validation. | `[ ]` |
