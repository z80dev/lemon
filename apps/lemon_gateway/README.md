# LemonGateway

Gateway for Lemon's configured singleton native executor. It sits behind router-owned conversations and handles global execution permits, fail-fast engine-session ownership, session resumption, and streaming native-executor output via the event bus.

Part of the `lemon` Elixir umbrella project.

## Architecture

```text
Router SessionCoordinator (conversation ordering)
  -> EngineRuntime / LemonGateway.Runtime.submit_execution/1
  -> RunSupervisor -> Run (unique run_id)
  -> EngineSessionClaim (fail fast)
  -> RunStore terminal fence
  -> Slots (global FIFO; Run is the waiter)
  -> cancellation / terminal recheck
  -> CodingAgent.Executor
  -> LemonCore.Bus -> router semantic output -> channels delivery
```

### Supervision tree

```text
LemonGateway.Supervisor (one_for_one)
  +-- Config
  +-- ExecutionSupervisor (rest_for_one)
  |     +-- RunRegistry
  |     +-- Slots (execution permits)
  |     +-- RunSupervisor (DynamicSupervisor)
  +-- TaskSupervisor (bounded Task.Supervisor; voice-call LLM/TTS tasks)
  +-- Health.Server (optional)
  +-- IngressSupervisor (opt-in)
```

The execution subtree has a separate budget of 10 restarts per 5 seconds,
an explicit containment policy. Losing the run registry or the permit authority
stops the run supervisor before new work is admitted, then restarts them in list
order, so a restarted counter cannot oversubscribe execution. Temporary
executions are not replayed; durable receipts and normal reconciliation retain
their existing unknown-outcome semantics. Configuration, voice tasks and ingress
remain independently supervised.

### Flow

1. Router-owned `SessionCoordinator` decides queue semantics (`collect`, `followup`, `steer`, `interrupt`) and hands queue-semantic-free `%LemonCore.ExecutionCommand{}` values to `LemonGateway.Runtime`.
2. Gateway-owned transports that still live in this app submit `%LemonCore.RunRequest{}` through `LemonCore.RouterBridge`, not directly into gateway internals.
3. `Runtime.submit_execution/1` starts a temporary **Run** directly under `RunSupervisor`; `:ok` acknowledges a started or already-live child, not executor admission or completion.
4. The **Run** claims its engine session while it starts, before requesting capacity. A conflicting claim refuses the start: `submit_execution/1` returns `{:error, :session_in_use}` with no Run, permit or terminal record, and the router retries it within its pre-start deadline.
5. After the terminal fence, the Run waits asynchronously in **Slots**' global FIFO. It rechecks terminal/cancellation state before invoking the executor.
6. The native executor streams lifecycle events and deltas back to the Run.
7. The **Run** broadcasts events on `"run:<run_id>"`; router and channels own semantic output and rendering.
8. Completion persists the terminal receipt, then releases the permit and claim exactly once, then notifies, so an observer of the completion can start the session's next run.

Exact-run cancellation removes slot waiters; a late grant cannot authorize a
terminal run to execute. RunRegistry prevents two live Runs for the same run ID.
Router retries only runtime unavailability and a busy engine session, bounded by its pre-start deadline;
definite rejection terminalizes once rather than retrying gateway admission.

Gateway has no separate per-conversation launch queue and no independent waiter
count or wait-time cap. The router's run-process cap bounds normal routed waiters,
but direct runtime callers bypass that protection. See the canonical
[admission inventory and ADR](../../docs/architecture/admission-gates.md).

Native executor death publishes an immediate structured `:executor_down`
completion and releases the permit/claim. The native session runner monitors its
event sink and aborts/saves/stops its owned session when that sink disappears.
Terminal receipts are durable before their bus notification is emitted. Every
Run exit path publishes one: losing the permit authority completes waiting and
running Runs with `:runtime_unavailable`, and an unreadable terminal fence with
`:run_state_unavailable`. A Run registers its run ID before
`submit_execution/1` returns, so the router monitors it while it waits for a permit.
Cancellation of a running native session retains its slot until ordered terminal
tool results and the agent's cancellation/error event have drained. The original
cancellation reason wins even if the executor races with successful completion;
the owned native journal is saved before publishing the terminal receipt. The
executor's `cancel/1` is an asynchronous request: whatever it returns, the Run
holds the permit and claim until the executor process exits. A 15-second drain
deadline bounds an unresponsive executor, without claiming that
an interrupted tool had no effects.

## Singleton Executor Contract

Gateway has one configured top-level executor: `CodingAgent.Executor`, invoked
through the `LemonGateway.Executor` boundary. LemonGateway owns its scheduling,
run lifecycle, event delivery, cancellation, session resumption, and readiness
check. Every gateway run retains the fixed provenance `engine: "lemon"`.

This is an intentional breaking removal of the Gateway engine platform. Gateway
runs cannot be routed to a vendor CLI, custom engine, registered engine, or
`Echo` implementation. Remove legacy `engine`, `default_engine`, and
`engine_preference` keys along with every `[gateway.engines.<id>]` table.
There is no Gateway configuration replacement for selecting a top-level external
or custom executor.

Choose an extension boundary instead:

| Need | Use |
| --- | --- |
| Integrate a model/API | a `LemonAi` provider |
| Add in-process agent capability | a `CodingAgent` tool |
| Delegate bounded work to a subagent | the native `task`/`agent` tools (in-process `CodingAgent.Session`) |

`LemonCore.ResumeToken` continues to support both native-executor and
delegated-task resume tokens. Top-level run provenance remains
`engine: "lemon"` while delegated task records retain their own task identity;
neither field routes Gateway execution. Delegated tasks run as native
in-process subagents; there are no vendor CLI task runners (Claude Code, Codex,
Kimi, OpenCode, and Pi were removed), and no external
runner ever selects or replaces the Gateway executor.

## Transports

| Transport | Module / Location | Description |
|-----------|-------------------|-------------|
| Telegram | `lemon_channels` (external app) | Telegram Bot API polling/webhooks |
| Discord | `lemon_channels` (external app) | Discord gateway via Nostrum |
| XMTP | `lemon_channels` (external app) | XMTP messaging via Node.js bridge |
| Email | `lemon_channels` (external app) | SMTP outbound + inbound webhook, as a channel plugin |
| Webhook | `Transports.Webhook` | Generic HTTP webhook (sync/async modes) |
| Voice | `Voice.*` | Real-time phone calls via Twilio + Deepgram STT + ElevenLabs TTS |
| SMS | `Sms.*` | Twilio SMS webhooks with verification code tools |

Gateway transports implement the `LemonGateway.Transport` behaviour (`id/0`, `start_link/1`). They are registered in `TransportRegistry` and started under `TransportSupervisor` only when gateway ingress is explicitly enabled with `config :lemon_gateway, gateway_ingress_enabled: true`. Telegram, Discord, XMTP and email are owned by the `lemon_channels` sibling app. Voice and SMS are not registry transports; they are dedicated Twilio support services included in the same explicit ingress startup.

`TransportRegistry` publishes the transport map and enabled-transport list as one
immutable persistent-term snapshot at startup. All lookups, including enabled
transport enumeration, are process-call-free. Restart the registry after changing
transport configuration; restart ingress to apply that configuration to running
transport children. A stopped registry exposes no stale registrations.

Webhook, SMS, and voice are gateway-owned by design, not pending migration: `LemonChannels.Plugin.deliver/1` is fire-and-forget, so it cannot serve webhook's synchronous response, SMS has no reply path at all, and voice needs a live bidirectional session. Email was the one surface that genuinely was a channel, and it moved to `lemon_channels` in phase 2.4 — `LemonChannels.Adapters.Email`. See decision D2 in `docs/platform-split.md`.

Webhook submissions use a caller-fixed run ID. If the router cannot confirm
whether a submission took effect, the HTTP request receives a `200` receipt
with `status: "outcome_unknown"` and `retry_safe: false`; this acknowledges the
webhook delivery without claiming that Lemon accepted the run. Callers must
reconcile the returned run ID instead of automatically redelivering. When an
idempotency key is present, Lemon persists that ambiguous receipt and replays it
without submitting another run. Reservations carry a stable run ID and a
lease-owner token. Submission and response receipts are compare-and-swap
updates owned by that token, and an HTTP success is not returned when the
corresponding durable receipt cannot be stored. An expired pending lease may be
reclaimed without duplicating an already accepted run because the router treats
the fixed run ID as a durable idempotency key. Payload-provided idempotency keys
are opt-in and must be non-empty JSON strings; blank, numeric, list, or object
values receive a bounded `422 invalid idempotency key` response before hashing
or reservation. A legacy pending receipt without a run ID remains a permanent
ambiguous fence after upgrade because its original acceptance outcome cannot be
proven safely; retries receive a duplicate `200 legacy_outcome_unknown` receipt
with `retry_safe: false` and never submit another run.

Each authenticated webhook run carries `meta.channel_context` derived from the
integration whose token matched (`channel_id: "webhook"`, the integration ID as
account and peer), never from the payload. The router applies the
`channel_policies["webhook"]` row from that provenance and refuses a `:webhook`
request without it. A token authenticates the integration, not the content it
relays, so by default the provenance is classified `peer_kind: :automation` and
every `bash`, `write`, `edit`, `patch` and `hashline_edit` call needs approval
(the group approval floor). An operator opts one integration out in the global
config only; gateway sections are operator-only, so a project
`.lemon/config.toml` cannot set it, and only a literal boolean `true` counts:

```toml
[gateway.webhook.integrations.ci]
token = "..."
trusted_automation = true   # no approval floor for this integration
```

The webhook idempotency sweep watermark is volatile ETS state owned by the
supervised `Transports.Webhook.Idempotency` ingress child, not by an HTTP caller.
Only successful cleanup advances it. Owner restart resets the schedule without
changing durable reservations or response receipts; missing supervision skips
opportunistic cleanup rather than creating a caller-owned table. Scheduler's
named stats table is likewise created and owned by its existing supervised child.

## Module Inventory

### Core

| Module | File | Purpose |
|--------|------|---------|
| `LemonGateway` | `lemon_gateway.ex` | Public execution-command facade `submit/1` |
| `LemonGateway.Application` | `application.ex` | Execution runtime supervision tree with optional health and explicit legacy ingress children |
| `LemonGateway.IngressSupervisor` | `ingress_supervisor.ex` | Supervisor for gateway-owned transport, SMS, and voice startup |
| `LemonGateway.Runtime` | `runtime.ex` | Execution submission and cancellation API |
| `LemonGateway.ExecutionRequest` | `execution_request.ex` | Gateway-private execution adapter with no queue semantics |
| `LemonGateway.Types` | `types.ex` | Shared gateway lane type |
| `LemonGateway.Event` | `event.ex` | Run lifecycle events (plain tagged maps with guards) and `Delta` struct |
| `LemonCore.ChatState` | `../lemon_core/lib/lemon_core/chat_state.ex` | Session state struct for auto-resume tracking |
| `LemonGateway.AI` | `ai.ex` | Direct HTTP chat completions for OpenAI and Anthropic APIs |

### Scheduling and Run Execution

| Module | File | Purpose |
|--------|------|---------|
| `LemonGateway.Slots` | `slots.ex` | Global FIFO execution permits; live Run processes are the waiters |
| `LemonGateway.Run` | `run.ex` | Individual run GenServer: native execution lifecycle, bus events, steer/cancel |
| `LemonGateway.RunSupervisor` | `run_supervisor.ex` | DynamicSupervisor for run processes (temporary restart) |
| `LemonGateway.EngineSessionClaim` | `engine_session_claim.ex` | Fail-fast Run-owned engine-session Registry claim |
| `LemonGateway.ProgressStore` | `progress_store.ex` | Progress/status message → run id index in the `:progress` store table (registered for the store read cache at boot); backs cancel-by-message |

Engine-session ownership is a unique `{:engine_session, key}` name in
`RunRegistry`, held by the Run itself. `EngineSessionClaim.claim/1` returns
`:ok` or `{:error, :session_in_use}` without waiting. Explicit release and
owner death release the name. There is no lock process, timeout, or ownership
transfer queue.

Gateway action events preserve nested `action.detail.result_meta` metadata,
including safe failure fields such as `error_type`, `timeout_ms`, and
`exit_code`, so downstream router and control-plane consumers can classify tool
failures without parsing rendered command output.

### Native Execution Boundary

| Module | File | Purpose |
|--------|------|---------|
| `LemonGateway.Executor` | `executor.ex` | Validates and invokes the configured singleton executor |

The public engine plugin, registration, enumeration, and test-compliance
surfaces are removed. `EngineInfoBridge` retains transport-registry and
gateway-config capabilities only. Operators must not register Gateway engines or
use external CLI runners as Gateway executors; delegated tasks run as native
in-process subagents.

### Transport Layer

| Module | File | Purpose |
|--------|------|---------|
| `LemonGateway.Transport` | `transport.ex` | Behaviour for transport plugins |
| `LemonGateway.TransportRegistry` | `transport_registry.ex` | Transport registration and enable/disable tracking |
| `LemonGateway.TransportSupervisor` | `transport_supervisor.ex` | Supervisor for enabled transports |
| `LemonGateway.Transports.Webhook` | `transports/webhook.ex` | HTTP webhook transport (sync/async) |

### Legacy Rendering Helpers

| Module | File | Purpose |
|--------|------|---------|
| `LemonGateway.Renderers.Basic` | `renderers/basic.ex` | Plain-text renderer with action lists and resume info |

### SMS

| Module | File | Purpose |
|--------|------|---------|
| `LemonGateway.Sms.Inbox` | `sms/inbox.ex` | Store and query inbound SMS messages |
| `LemonGateway.Sms.WebhookServer` | `sms/webhook_server.ex` | HTTP server for Twilio SMS webhooks |
| `LemonGateway.Sms.WebhookRouter` | `sms/webhook_router.ex` | Plug router for SMS webhook requests |
| `LemonGateway.Sms.TwilioSignature` | `sms/twilio_signature.ex` | Twilio webhook signature validation |
| `LemonGateway.Sms.Config` | `sms/config.ex` | SMS configuration helpers |

### Voice

| Module | File | Purpose |
|--------|------|---------|
| `LemonGateway.Voice.CallSession` | `voice/call_session.ex` | Per-call state machine owning supervised, deadline-bound LLM/TTS work |
| `LemonGateway.Voice.TwilioWebSocket` | `voice/twilio_websocket.ex` | WebSocket handler for Twilio Media Streams |
| `LemonGateway.Voice.DeepgramClient` | `voice/deepgram_client.ex` | WebSocket client for Deepgram STT |
| `LemonGateway.Voice.WebhookRouter` | `voice/webhook_router.ex` | Voice webhook HTTP routing |
| `LemonGateway.Voice.RecordingManager` | `voice/recording_manager.ex` | Starts dual-channel call recording via Twilio REST API |
| `LemonGateway.Voice.RecordingDownloader` | `voice/recording_downloader.ex` | Downloads and saves Twilio recordings locally |
| `LemonGateway.Voice.AudioConversion` | `voice/audio_conversion.ex` | PCM-to-mulaw and MP3 detection utilities |
| `LemonGateway.Voice.Config` | `voice/config.ex` | Voice configuration (Twilio, Deepgram, ElevenLabs credentials) |

### Gateway Tools (injected into native executor runs)

| Module | File | Purpose |
|--------|------|---------|
| `LemonGateway.Tools.SmsGetInboxNumber` | `tools/sms_get_inbox_number.ex` | Get the Twilio inbox phone number |
| `LemonGateway.Tools.SmsWaitForCode` | `tools/sms_wait_for_code.ex` | Block until a matching SMS verification code arrives |
| `LemonGateway.Tools.SmsListMessages` | `tools/sms_list_messages.ex` | List recent SMS messages |
| `LemonGateway.Tools.SmsClaimMessage` | `tools/sms_claim_message.ex` | Mark an SMS as claimed by the current session |
| `LemonGateway.Tools.SmsReleaseInbox` | `tools/sms_release_inbox.ex` | Release the session's exclusive inbox reservation |

File delivery to Telegram and Discord chats is the channel-keyed `send_file`
tool (`CodingAgent.Tools.SendFile` in `coding_agent`), not a gateway tool.

### Health

| Module | File | Purpose |
|--------|------|---------|
| `LemonGateway.Health` | `health.ex` | Health check system with built-in and custom checks |
| `LemonGateway.Health.Router` | `health/router.ex` | Plug router serving `GET /health` (port 4042) |

## Native Execution Lifecycle

### Start

1. `Run.init/1` registers its run ID without waiting for capacity. Admission claims the engine session, checks the terminal fence, then requests a permit.
2. After grant and a terminal/cancellation recheck, the Run resolves the working directory and invokes `CodingAgent.Executor` through `LemonGateway.Executor`.
3. The native executor starts the session and returns the run and cancellation state; vendor CLI subprocesses are never started for a Gateway run.

### Streaming

- The native executor sends `{:engine_delta, run_ref, text}` messages for incremental text output.
- The Run process assigns monotonic sequence numbers, builds `Event.Delta` structs, and broadcasts them to `LemonCore.Bus`.
- First-token latency telemetry is emitted on the first delta.

### Completion

- The native executor sends `{:engine_event, run_ref, completed_event}` when done.
- The Run persists its terminal receipt before publishing `:run_completed`, releases its engine-session claim and permit, and notifies `meta.notify_pid`.
- On context-length overflow errors, the `ChatState` is automatically cleared so the next run starts fresh.

### Steering

- The native executor supports low-level steering for an active session.
- Router-owned `SessionCoordinator` decides whether a submission should be steered, queued, or interrupted before anything reaches the gateway.
- Any fallback from `:steer` / `:steer_backlog` is router behavior, not gateway queue behavior.

### Cancellation

- `Runtime.cancel_by_run_id/2` looks up the run in `RunRegistry` and casts `{:cancel, reason}` to the run process.
- The Run cancels the native executor, emits a failed completion event, and terminates normally.

## Queue Semantics

Queue modes such as `:collect`, `:followup`, `:steer`, `:steer_backlog`, and `:interrupt` are router-owned conversation semantics. The gateway no longer decides those modes for execution requests.

Gateway queue configuration only applies to legacy transport/binding compatibility paths that still emit router-facing run requests before `SessionCoordinator` takes over. Execution submission into the gateway is keyed by router-supplied `conversation_key`.

## Voice Call System

Each call serializes LLM generation and speech synthesis through supervised
tasks. Generation has the existing 30-second HTTP budget and synthesis has the
existing 10-second HTTP budget; timeout or task death advances queued work.
Expired task results and best-effort Twilio playback marks cannot advance a
new synthesis. Incoming audio resets the configured silence deadline; unrelated
events do not. Inactivity starts a goodbye with the existing three-second
shutdown budget. Ending the call terminates its active task.

```
Incoming Call -> Twilio -> Voice.WebhookRouter -> CallSession state machine
                                                      |
                                               TwilioWebSocket
                                            (mulaw audio frames)
                                                      |
                                               DeepgramClient
                                            (raw audio -> text)
                                                      |
                                               LemonGateway.AI
                                            (LLM chat completion)
                                                      |
                                           ElevenLabs TTS API
                                            (text -> audio)
                                                      |
                                              Twilio <- audio
```

- `RecordingManager` starts dual-channel recording via the Twilio REST API when a call connects.
- `RecordingDownloader` saves recordings as WAV files organized by date (`~/.lemon/recordings/<date>/`).
- Audio conversion handles PCM-to-mulaw transcoding and MP3/ID3 detection for ElevenLabs responses.

## SMS Inbox

1. Twilio sends SMS webhooks to `Sms.WebhookServer`. Every request must carry a
   valid `X-Twilio-Signature` (`TwilioSignature`); there is no opt-out. A missing
   auth token (`TWILIO_AUTH_TOKEN` or `[gateway.sms] auth_token_secret`) keeps
   the listener from starting, and missing or bad signatures get 403 with
   nothing stored.
2. `Sms.Inbox` and the listener start only when SMS ingress is usable: gateway
   ingress enabled, `[gateway.sms] webhook_enabled`, and an auth token.
   Webhook-only or voice-only deployments run no inbox. The inbox stores
   messages with extracted verification codes (4-8 digit sequences).
3. Native executor runs get the SMS tools (`sms_get_inbox_number`,
   `sms_wait_for_code`, `sms_list_messages`, `sms_claim_message`,
   `sms_release_inbox`) only while SMS ingress is usable and both the inbox and
   listener are running. Their results are untrusted tool output, fenced before
   the model sees them, because SMS bodies are attacker-controlled.
4. The shared number is reserved by one session at a time. Any SMS tool call
   takes the reservation (or reuses the caller's own); other sessions get
   "reserved by another session" with no number or content. Reservations are
   persisted and never expire: the number stays bound to its holder, across runs
   and restarts, until the holder calls `sms_release_inbox` or an operator clears
   it. A text is bound to the session the number is bound to when it arrives,
   and only that session can list, wait for or claim it. Texts arriving while
   the number is unbound are visible to no session. `include_claimed` is not
   available to agents.
5. After an explicit release the number stays bound to the releasing session
   for a handoff grace period (`[gateway.sms] handoff_grace_ms`, default 10
   minutes; zero or invalid values are rejected at config load). Late texts in
   that window go to the releaser, which may re-reserve at any time; every other
   session is refused. Releasing gives up later codes.
6. Operators can force-clear a stuck reservation with the admin control-plane
   method `sms.inbox.clear`: call it without `confirmToken` to preview the
   holder and get a single-use token, then call it with that `holder` and
   `confirmToken`. The clear is bound to that exact holder and reservation and
   frees the number at once, so a late text for the previous holder that arrives
   after another session reserves goes to that session. This is an accepted cost
   of a forced clear.

   A shared number gives ownership only through explicit release; it cannot
   prove which flow a text belongs to. Session-specific numbers are needed for
   stronger isolation.
7. Ingestion is an atomic insert-if-absent keyed by MessageSid: a replayed
   delivery never overwrites the stored message or its claim and is not offered
   again. A store failure answers 503 so Twilio can retry; lease reads are strict,
   so a store failure refuses the lease instead of granting it.

## Binding System

Bindings map `transport + chat_id + topic_id` to a project, agent, and queue mode:

```toml
[[gateway.bindings]]
transport = "telegram"
chat_id = 123456789
topic_id = 42
project = "myproject"
agent_id = "coder"
queue_mode = "steer"
```

`LemonChannels.BindingResolver` (over `LemonCore.BindingResolver`) provides:
- `resolve_binding/1` -- most specific matching binding
- `resolve_cwd/1` -- project root directory
- `resolve_agent_id/1` -- agent identifier
- `resolve_queue_mode/1` -- queue mode from binding

## Configuration

Configuration is the `[gateway]` section of `~/.lemon/config.toml`, read live through `LemonCore.GatewayConfig` (an ETS-cached read of `LemonCore.Config`). There is no gateway config process: a config reload reaches every reader without a restart, and `LemonGateway.Slots` re-reads `max_concurrent_runs` on each `:config_reloaded` event. A config that cannot be loaded at boot fails startup instead of starting with channels disabled.

### Core Options

| Key | Default | Description |
|-----|---------|-------------|
| `max_concurrent_runs` | `2` | Maximum concurrent AI runs across all threads |
| `default_cwd` | `nil` | Default working directory (falls back to `$HOME`) |
| `auto_resume` | `false` | Automatically resume sessions from stored `ChatState` |

### Startup Options

| Key | Default | Description |
|-----|---------|-------------|
| `gateway_ingress_enabled` | `false` | Start gateway-owned transports, SMS inbox/webhook server, and voice supervisors. Default gateway startup is execution-only. |

### Transport Enable Flags

| Key | Default | Description |
|-----|---------|-------------|
| `enable_telegram` | `false` | Enable Telegram adapter (via `lemon_channels`) |
| `enable_discord` | `false` | Enable Discord adapter (via `lemon_channels`) |
| `enable_xmtp` | `false` | Enable XMTP transport |
| `enable_webhook` | `false` | Enable webhook transport |

There is no `enable_email` gate. The `[gateway] email` block itself is still meaningful — the
channel adapter reads it, so existing relay credentials, sender address and webhook token keep
working. Receiving mail now depends on `LemonChannels.InboundHttp` being enabled and a
webhook token being set; see `LemonChannels.Adapters.Email`.

Discord and email are not gateway transports. If a `discord` or `email` module is added to
`:transports`, `TransportRegistry` ignores it and logs a warning; ownership lives in
`lemon_channels`.

### TOML Example

```toml
[gateway]
max_concurrent_runs = 2
auto_resume = true

[gateway.telegram]
bot_token = "your-token"
allowed_chat_ids = [123456789]
deny_unbound_chats = true

[gateway.projects.myproject]
root = "/path/to/project"

[[gateway.bindings]]
transport = "telegram"
chat_id = 123456789
project = "myproject"
agent_id = "coder"
queue_mode = "steer"

[gateway.sms]
inbox_number = "+1234567890"
webhook_port = 4045

```

## Event Protocol

The configured native executor emits events to the Run process as
`{:engine_event, run_ref, event}` messages where events are plain tagged maps.
The `engine` field is always the fixed top-level provenance `"lemon"`:

| Event Tag | Key Fields | Description |
|-----------|-----------|-------------|
| `:started` | `engine`, `resume`, `title`, `meta` | Run began, includes resume token |
| `:action_event` | `engine`, `action`, `phase`, `ok`, `message` | Tool/action progress |
| `:completed` | `engine`, `ok`, `answer`, `error`, `resume`, `usage` | Run finished |

Streaming text is sent as `{:engine_delta, run_ref, text}` with monotonic sequence numbers assigned by the Run process.

The Run re-emits all events to `LemonCore.Bus` as plain maps on topic `"run:<run_id>"`. Bus event types: `:run_started`, `:run_completed`, `:delta`, `:engine_started`, `:engine_completed`, `:engine_action`.

## Health Check

The health endpoint runs on port 4042 (configurable via `:health_port` or
`LEMON_GATEWAY_HEALTH_PORT`). `GET /healthz` returns JSON with built-in checks for:

- Supervisor process liveness
- Slots-published ETS counters (`in_flight`, `waitq`, `max`), read without calling the permit server
- Configured executor readiness
- RunSupervisor active children

Custom health checks can be registered via the `:health_checks` application environment.

## Dependencies

### Umbrella Apps

| App | Purpose |
|-----|---------|
| `coding_agent` | Configured singleton native executor and in-process tools |
| `lemon_core` | Shared primitives: `Store`, `Bus`, `Telemetry`, `ResumeToken`, `ChatScope`, `Binding`, `Secrets`, `GatewayConfig` |

### External Libraries

| Library | Purpose |
|---------|---------|
| `jason` | JSON encoding/decoding |
| `uuid` | UUID generation for run IDs |
| `toml` | TOML configuration parsing |
| `plug` + `bandit` | HTTP servers (health port 4042, SMS webhooks, voice webhooks) |
| `gen_smtp` + `mail` | SMTP email handling |
| `earmark_parser` | Markdown-to-Telegram entity rendering |
| `websockex` + `websock_adapter` | WebSocket clients (Deepgram STT, Twilio Media Streams) |

## Testing

```bash
# Run all gateway tests
mix test apps/lemon_gateway

# Run a specific test file
mix test apps/lemon_gateway/test/run_test.exs

# Run with verbose output
mix test apps/lemon_gateway --trace
```

Tests use `async: false` by default due to shared GenServer state (Config, Slots, and the singleton executor boundary).
