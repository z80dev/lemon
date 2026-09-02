# LemonGateway

Gateway for Lemon's configured singleton native executor. It sits behind router-owned conversations and handles execution-slot scheduling, per-conversation launch isolation, session resumption, and streaming native-executor output via the event bus.

Part of the `lemon` Elixir umbrella project.

## Architecture

```
                        +-----------------------------------------+
                        |   Router / Explicit Legacy Ingress       |
                        | Email  SMS  Voice  Webhook              |
                        +-------------------+---------------------+
                                            |
                               ExecutionCommand
                                            |
                                            v
                        +-------------------+---------------------+
                        |           LemonGateway.Runtime           |
                        |  submit_execution/1 -> ExecutionRequest  |
                        +-------------------+---------------------+
                                            |
                                            v
                        +-------------------+---------------------+
                        |         LemonGateway.Scheduler           |
                        | slot allocation + conversation-key       |
                        | routing from router-supplied requests    |
                        +-------------------+---------------------+
                                            |
                                    slot_granted
                                            |
                                            v
                        +-------------------+---------------------+
                        |       LemonGateway.ThreadWorker          |
                        |   trivial per-conversation launcher      |
                        |   (no queue semantics)                   |
                        +-------------------+---------------------+
                                            |
                                     RunSupervisor
                                     .start_run
                                            |
                                            v
                        +-------------------+---------------------+
                        |          LemonGateway.Run                |
                        |  native execution lifecycle, bus events, |
                        |       streaming deltas, steer/cancel     |
                        +-------------------+---------------------+
                                            |
                                            v
                        +-------------------+---------------------+
                        |       CodingAgent.Executor               |
                        |    configured native executor            |
                        +-------------------+---------------------+
                                            |
                                  events & deltas
                                            |
                                            v
                        +-------------------+---------------------+
                        |          LemonCore.Bus                   |
                        |     topic "run:<run_id>"                 |
                        |   -> LemonRouter -> LemonChannels        |
                        +-----------------------------------------+
```

### Flow

1. Router-owned `SessionCoordinator` decides queue semantics (`collect`, `followup`, `steer`, `interrupt`) and hands queue-semantic-free `%LemonCore.ExecutionCommand{}` values to `LemonGateway.Runtime`.
2. Gateway-owned transports that still live in this app submit `%LemonCore.RunRequest{}` through `LemonCore.RouterBridge`, not directly into gateway internals.
3. The **Scheduler** routes each execution request by the router-supplied `conversation_key`, deduplicates tokenized worker generations, and allocates a concurrency slot.
4. The **ThreadWorker** is only a per-conversation launcher/slot waiter. It does not own product queue semantics. Its run-start attempt budget persists across slot grants; exhausted requests receive one structured terminal completion before later FIFO work advances.
5. On slot grant, the worker starts a **Run** via `RunSupervisor`. The Run acquires `EngineLock` and starts Lemon's native executor.
6. The native executor executes the AI request and streams lifecycle events and deltas back to the Run process.
7. The **Run** broadcasts all events to `LemonCore.Bus` on topic `"run:<run_id>"`. Router and channels consume those events and handle semantic output plus channel rendering.
8. On completion, the Run stores chat state for future auto-resume, releases the engine lock and scheduler slot, and finalizes its lifecycle.

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

Webhook, SMS, and voice are gateway-owned by design, not pending migration: `LemonChannels.Plugin.deliver/1` is fire-and-forget, so it cannot serve webhook's synchronous response, SMS has no reply path at all, and voice needs a live bidirectional session. Email was the one surface that genuinely was a channel, and it moved to `lemon_channels` in phase 2.4 — `LemonChannels.Adapters.Email`. See `docs/platform/transport-unification.md`.

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
the fixed run ID as a durable idempotency key.

## Module Inventory

### Core

| Module | File | Purpose |
|--------|------|---------|
| `LemonGateway` | `lemon_gateway.ex` | Public API entry point for `submit_execution/1` and health helpers |
| `LemonGateway.Application` | `application.ex` | Execution runtime supervision tree with optional health and explicit legacy ingress children |
| `LemonGateway.IngressSupervisor` | `ingress_supervisor.ex` | Supervisor for gateway-owned transport, command, SMS, and voice startup |
| `LemonGateway.Runtime` | `runtime.ex` | Execution submission and cancellation API |
| `LemonGateway.Config` | `config.ex` | TOML-backed runtime configuration GenServer |
| `LemonGateway.ConfigLoader` | `config_loader.ex` | Loads and parses TOML config into typed structs |
| `LemonGateway.ExecutionRequest` | `execution_request.ex` | Gateway-private scheduler adapter with no queue semantics |
| `LemonGateway.Types` | `types.ex` | Shared gateway lane type |
| `LemonGateway.Event` | `event.ex` | Run lifecycle events (plain tagged maps with guards) and `Delta` struct |
| `LemonCore.ChatState` | `../lemon_core/lib/lemon_core/chat_state.ex` | Session state struct for auto-resume tracking |
| `LemonGateway.Cwd` | `cwd.ex` | Default working directory resolver |
| `LemonGateway.Project` | `project.ex` | Project configuration struct (`id`, `root`) |
| `LemonGateway.Shared` | `shared.ex` | Shared utilities (config access, data normalization, IP parsing) |
| `LemonGateway.DependencyManager` | `dependency_manager.ex` | Centralized app startup, module availability checks, safe bus/telemetry |
| `LemonGateway.AI` | `ai.ex` | Direct HTTP chat completions for OpenAI and Anthropic APIs |
| `LemonGateway.Dev` | `dev.ex` | Development helpers (recompile and hot-reload) |

### Scheduling and Run Execution

| Module | File | Purpose |
|--------|------|---------|
| `LemonGateway.Scheduler` | `scheduler.ex` | Concurrency-limited slot allocator keyed by router-supplied conversation keys, with tokenized request deduplication |
| `LemonGateway.ThreadWorker` | `thread_worker.ex` | Per-conversation launcher / slot waiter with no queue-mode logic and bounded total start attempts |
| `LemonGateway.ThreadRegistry` | `thread_registry.ex` | Registry for thread workers (unique key by `thread_key`) |
| `LemonGateway.ThreadWorkerSupervisor` | `thread_worker_supervisor.ex` | DynamicSupervisor for thread workers |
| `LemonGateway.Run` | `run.ex` | Individual run GenServer: native execution lifecycle, bus events, steer/cancel |
| `LemonGateway.RunSupervisor` | `run_supervisor.ex` | DynamicSupervisor for run processes (temporary restart) |
| `LemonGateway.EngineLock` | `engine_lock.ex` | Per-session mutex with FIFO queueing, waiter timeouts, owner-death release, and over-age live-owner observation |

`EngineLock` never transfers an exclusive lock because of age alone. Explicit
release and confirmed owner-process death are the ownership-transfer paths; a
live owner beyond the configured age threshold remains exclusive and emits
`[:lemon, :gateway, :engine_lock, :over_age_live_owner]` telemetry for operators.

Gateway action events preserve nested `action.detail.result_meta` metadata,
including safe failure fields such as `error_type`, `timeout_ms`, and
`exit_code`, so downstream router and control-plane consumers can classify tool
failures without parsing rendered command output.

### Native Execution Boundary

| Module | File | Purpose |
|--------|------|---------|
| `LemonGateway.Executor` | `executor.ex` | Validates and invokes the configured singleton executor |
| `LemonGateway.Workspace` | `workspace.ex` | Workspace directory for channel-bound files, configured rather than read from the agent |

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

### Binding and Legacy Rendering Helpers

| Module | File | Purpose |
|--------|------|---------|
| `LemonGateway.Binding` | `binding_resolver.ex` | Struct mapping transport/chat/topic to project, agent, and queue mode |
| `LemonGateway.BindingResolver` | `binding_resolver.ex` | Resolves cwd, agent_id, and queue_mode from `ChatScope` |
| `LemonGateway.Renderer` | `renderer.ex` | Behaviour for event-to-text rendering |
| `LemonGateway.Renderers.Basic` | `renderers/basic.ex` | Plain-text renderer with action lists and resume info |

### Command System

| Module | File | Purpose |
|--------|------|---------|
| `LemonGateway.Command` | `command.ex` | Behaviour for slash command plugins |
| `LemonGateway.CommandRegistry` | `command_registry.ex` | Command registration and lookup |
| `LemonGateway.Commands.Cancel` | `commands/cancel.ex` | Built-in `/cancel` command |

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
| `LemonGateway.Voice.CallSession` | `voice/call_session.ex` | Per-call GenServer managing STT/TTS pipeline |
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
| `LemonGateway.Tools.Cron` | `tools/cron.ex` | Manage cron jobs and active cron runs via `LemonAutomation.CronManager` |
| `LemonGateway.Tools.SmsGetInboxNumber` | `tools/sms_get_inbox_number.ex` | Get the Twilio inbox phone number |
| `LemonGateway.Tools.SmsWaitForCode` | `tools/sms_wait_for_code.ex` | Block until a matching SMS verification code arrives |
| `LemonGateway.Tools.SmsListMessages` | `tools/sms_list_messages.ex` | List recent SMS messages |
| `LemonGateway.Tools.SmsClaimMessage` | `tools/sms_claim_message.ex` | Mark an SMS as claimed by the current session |
| `LemonGateway.Tools.TelegramSendImage` | `tools/telegram_send_image.ex` | Queue an image for Telegram delivery (Telegram sessions only) |
| `LemonGateway.Tools.DiscordSendFile` | `tools/discord_send_file.ex` | Queue a file for Discord delivery (Discord sessions only) |

### Health

| Module | File | Purpose |
|--------|------|---------|
| `LemonGateway.Health` | `health.ex` | Health check system with built-in and custom checks |
| `LemonGateway.Health.Router` | `health/router.ex` | Plug router serving `GET /health` (port 4042) |

## Native Execution Lifecycle

### Start

1. `Run.init/1` acquires the `EngineLock` for the session's thread key (or fails fast with `:lock_timeout`).
2. The Run resolves the working directory and invokes the configured `CodingAgent.Executor` through `LemonGateway.Executor`.
3. The native executor starts the session and returns the run and cancellation state; vendor CLI subprocesses are never started for a Gateway run.

### Streaming

- The native executor sends `{:engine_delta, run_ref, text}` messages for incremental text output.
- The Run process assigns monotonic sequence numbers, builds `Event.Delta` structs, and broadcasts them to `LemonCore.Bus`.
- First-token latency telemetry is emitted on the first delta.

### Completion

- The native executor sends `{:engine_event, run_ref, completed_event}` when done.
- The Run process stores chat state for auto-resume, emits `:run_completed` to the bus, finalizes the run in `LemonCore.Store`, releases the engine lock and scheduler slot, and notifies the worker and `meta.notify_pid`.
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

```
Incoming Call -> Twilio -> Voice.WebhookRouter -> CallSession GenServer
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

1. Twilio sends SMS webhooks to `Sms.WebhookServer` (validates signatures via `TwilioSignature`).
2. `Sms.Inbox` stores messages with extracted verification codes (4-8 digit sequences).
3. Native executor runs can use injected tools (`sms_wait_for_code`, `sms_list_messages`, `sms_claim_message`) to interact with the inbox.
4. Messages can be "claimed" to prevent cross-session conflicts.

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

`BindingResolver` delegates to `LemonCore.BindingResolver` and provides:
- `resolve_binding/1` -- most specific matching binding
- `resolve_cwd/1` -- project root directory
- `resolve_agent_id/1` -- agent identifier
- `resolve_queue_mode/1` -- queue mode from binding

## Configuration

Configuration loads from `~/.lemon/config.toml` (the `[gateway]` section) via `LemonCore.GatewayConfig.load/0` and `LemonGateway.ConfigLoader`.

### Core Options

| Key | Default | Description |
|-----|---------|-------------|
| `max_concurrent_runs` | `2` | Maximum concurrent AI runs across all threads |
| `default_cwd` | `nil` | Default working directory (falls back to `$HOME`) |
| `auto_resume` | `false` | Automatically resume sessions from stored `ChatState` |
| `require_engine_lock` | `true` | Acquire the per-session mutex before native execution |
| `engine_lock_timeout_ms` | `60000` | Timeout for native-execution lock acquisition |

### Startup Options

| Key | Default | Description |
|-----|---------|-------------|
| `gateway_ingress_enabled` | `false` | Start gateway-owned transports, command registry, SMS inbox/webhook server, and voice supervisors. Default gateway startup is execution-only. |

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

### Legacy Queue Options (`[gateway.queue]`)

| Key | Default | Description |
|-----|---------|-------------|
| `mode` | `nil` | Legacy default queue mode used only while building router-facing submissions from old transport/binding config |
| `cap` | `nil` | Legacy queue cap for compatibility paths that still rely on transport-level queue config |
| `drop` | `nil` | Legacy drop policy when that compatibility queue cap is exceeded |

### TOML Example

```toml
[gateway]
max_concurrent_runs = 2
auto_resume = true
require_engine_lock = true

[gateway.queue]
mode = "followup"
cap = 50
drop = "oldest"

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
`LEMON_GATEWAY_HEALTH_PORT`). `GET /health` returns JSON with built-in checks for:

- Supervisor process liveness
- Scheduler state (in_flight count, waitq length, max slots)
- Configured executor readiness
- RunSupervisor active children
- EngineLock process liveness

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

Tests use `async: false` by default due to shared GenServer state (Config, Scheduler, and the singleton executor boundary). The test helper sets up an isolated lock directory to avoid collisions with running development instances.
