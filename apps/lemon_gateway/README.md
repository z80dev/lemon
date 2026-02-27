# LemonGateway

Multi-engine AI gateway for Elixir. Routes user requests from messaging transports (Telegram, Discord, Email, SMS, Voice, Farcaster, XMTP, Webhooks) to AI engine backends (Lemon, Claude, Codex, Opencode, Pi) with concurrency control, per-session thread isolation, session resumption, and streaming output via an event bus.

Part of the `lemon` Elixir umbrella project.

## Architecture

```
                        +-----------------------------------------+
                        |             Transports                   |
                        | Telegram  Discord  Email  SMS  Voice    |
                        | Farcaster  XMTP  Webhook                |
                        +-------------------+---------------------+
                                            |
                                     Job (Types.Job)
                                            |
                                            v
                        +-------------------+---------------------+
                        |           LemonGateway.Runtime           |
                        |              submit/1                    |
                        +-------------------+---------------------+
                                            |
                                            v
                        +-------------------+---------------------+
                        |         LemonGateway.Scheduler           |
                        |    auto-resume, slot allocation,         |
                        |    thread_key routing                    |
                        +-------------------+---------------------+
                                            |
                                    slot_granted
                                            |
                                            v
                        +-------------------+---------------------+
                        |       LemonGateway.ThreadWorker          |
                        |    per-session job queue (5 modes)       |
                        |    collect | followup | steer |          |
                        |    steer_backlog | interrupt             |
                        +-------------------+---------------------+
                                            |
                                     RunSupervisor
                                     .start_run
                                            |
                                            v
                        +-------------------+---------------------+
                        |          LemonGateway.Run                |
                        |    engine lifecycle, bus events,         |
                        |    streaming deltas, steer/cancel        |
                        +-------------------+---------------------+
                                            |
                                   Engine.start_run
                                            |
                                            v
                        +-------------------+---------------------+
                        |        Engine (behaviour)                |
                        | Lemon | Claude | Codex | Opencode | Pi  |
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

1. A **Transport** (or channel adapter) receives user input, constructs a `Job` struct, and calls `LemonGateway.submit/1`.
2. The **Scheduler** applies auto-resume from stored `ChatState`, derives a `thread_key` from the session key, and routes the job to the appropriate `ThreadWorker`.
3. The **ThreadWorker** manages a per-session job queue with mode-dependent enqueue semantics (collect, followup, steer, steer_backlog, interrupt). When ready, it requests a concurrency slot from the Scheduler.
4. On slot grant, the worker starts a **Run** process via `RunSupervisor`. The Run acquires an `EngineLock`, resolves the engine, and calls `Engine.start_run/3`.
5. The **Engine** executes the AI request (native Elixir session, CLI subprocess, or echo) and streams events (`{:engine_event, run_ref, event}`) and text deltas (`{:engine_delta, run_ref, text}`) back to the Run process.
6. The **Run** broadcasts all events to `LemonCore.Bus` on topic `"run:<run_id>"`. Subscribers (router, channels, control-plane) handle channel-specific rendering and delivery.
7. On completion, the Run stores chat state for auto-resume, releases the engine lock and scheduler slot, and notifies the `ThreadWorker` and any `meta.notify_pid`.

## Supported Engines

| Engine ID | Module | Runner | Steering | Description |
|-----------|--------|--------|----------|-------------|
| `lemon` | `Engines.Lemon` | `CodingAgent.CliRunners.LemonRunner` | Yes | Native Elixir engine with full CodingAgent tool support, session persistence, and mid-run steering |
| `claude` | `Engines.Claude` | `AgentCore.CliRunners.ClaudeRunner` | No | Claude Code CLI wrapper via CliAdapter |
| `codex` | `Engines.Codex` | `AgentCore.CliRunners.CodexRunner` | No | OpenAI Codex CLI wrapper via CliAdapter |
| `opencode` | `Engines.Opencode` | `AgentCore.CliRunners.OpencodeRunner` | No | Opencode CLI wrapper via CliAdapter |
| `pi` | `Engines.Pi` | `AgentCore.CliRunners.PiRunner` | No | Pi CLI wrapper via CliAdapter |
| `echo` | `Engines.Echo` | (in-process Task) | No | Test/debug engine that echoes the prompt back |

### Engine Abstraction

All engines implement the `LemonGateway.Engine` behaviour:

- `id/0` -- unique lowercase string identifier
- `start_run/3` -- starts the AI run, returns `{:ok, run_ref, cancel_ctx}`
- `cancel/1` -- cancels an active run
- `supports_steer?/0` -- whether mid-run message injection is supported
- `steer/2` -- inject text into an active run (optional callback)
- `format_resume/1`, `extract_resume/1`, `is_resume_line/1` -- resume token serialization

CLI-based engines (Claude, Codex, Opencode, Pi) delegate to `Engines.CliAdapter`, which provides shared logic for subprocess management, event stream consumption, resume token formatting, and cancellation.

### Engine Selection Priority

1. Resume token engine (from auto-resume `ChatState`)
2. Inline directive (`/claude`, `/codex`, `/lemon`, etc. via `EngineDirective`)
3. Binding `default_engine` (topic-level, then chat-level)
4. Project `default_engine`
5. Global `default_engine` from config (default: `"lemon"`)

Composite engine IDs like `"claude:claude-3-opus"` are resolved by prefix fallback to `"claude"`.

## Transports

| Transport | Module / Location | Description |
|-----------|-------------------|-------------|
| Telegram | `lemon_channels` (external app) | Telegram Bot API polling/webhooks |
| Discord | `lemon_channels` (external app) | Discord gateway via Nostrum |
| XMTP | `lemon_channels` (external app) | XMTP messaging via Node.js bridge |
| Email | `Transports.Email` | SMTP inbound webhook + outbound delivery via gen_smtp |
| Farcaster | `Transports.Farcaster` | Farcaster Frame-based interactions with Hub validation |
| Webhook | `Transports.Webhook` | Generic HTTP webhook (sync/async modes) |
| Voice | `Transports.Voice` | Real-time phone calls via Twilio + Deepgram STT + ElevenLabs TTS |
| SMS | `Sms.*` | Twilio SMS webhooks with verification code tools |

Transports implement the `LemonGateway.Transport` behaviour (`id/0`, `start_link/1`). They are registered in `TransportRegistry` and started under `TransportSupervisor`. Telegram, Discord, and XMTP are owned by the `lemon_channels` sibling app.

## Module Inventory

### Core

| Module | File | Purpose |
|--------|------|---------|
| `LemonGateway` | `lemon_gateway.ex` | Public API entry point (`submit/1`) |
| `LemonGateway.Application` | `application.ex` | OTP supervision tree |
| `LemonGateway.Runtime` | `runtime.ex` | Internal submit/cancel API |
| `LemonGateway.Config` | `config.ex` | TOML-backed runtime configuration GenServer |
| `LemonGateway.ConfigLoader` | `config_loader.ex` | Loads and parses TOML config into typed structs |
| `LemonGateway.Types` | `types.ex` | Core type definitions (`Job`, `engine_id`, `queue_mode`, `lane`) |
| `LemonGateway.Event` | `event.ex` | Run lifecycle events (plain tagged maps with guards) and `Delta` struct |
| `LemonGateway.ChatState` | `chat_state.ex` | Session state struct for auto-resume tracking |
| `LemonGateway.Cwd` | `cwd.ex` | Default working directory resolver |
| `LemonGateway.Project` | `project.ex` | Project configuration struct (`id`, `root`, `default_engine`) |
| `LemonGateway.Shared` | `shared.ex` | Shared utilities (config access, data normalization, IP parsing) |
| `LemonGateway.DependencyManager` | `dependency_manager.ex` | Centralized app startup, module availability checks, safe bus/telemetry |
| `LemonGateway.AI` | `ai.ex` | Direct HTTP chat completions for OpenAI and Anthropic APIs |
| `LemonGateway.Dev` | `dev.ex` | Development helpers (recompile and hot-reload) |

### Scheduling and Run Execution

| Module | File | Purpose |
|--------|------|---------|
| `LemonGateway.Scheduler` | `scheduler.ex` | Concurrency-limited slot allocator with auto-resume and thread routing |
| `LemonGateway.ThreadWorker` | `thread_worker.ex` | Per-session job queue with 5 queue modes and steer support |
| `LemonGateway.ThreadRegistry` | `thread_registry.ex` | Registry for thread workers (unique key by `thread_key`) |
| `LemonGateway.ThreadWorkerSupervisor` | `thread_worker_supervisor.ex` | DynamicSupervisor for thread workers |
| `LemonGateway.Run` | `run.ex` | Individual run GenServer: engine lifecycle, bus events, steer/cancel |
| `LemonGateway.RunSupervisor` | `run_supervisor.ex` | DynamicSupervisor for run processes (temporary restart) |
| `LemonGateway.EngineLock` | `engine_lock.ex` | Per-session mutex with FIFO queueing, timeouts, and stale lock reaping |

### Engine Layer

| Module | File | Purpose |
|--------|------|---------|
| `LemonGateway.Engine` | `engine.ex` | Behaviour definition for engine plugins |
| `LemonGateway.EngineRegistry` | `engine_registry.ex` | Engine registration, lookup, and resume token extraction |
| `LemonGateway.EngineDirective` | `engine_directive.ex` | Parses `/engine` prefix directives from user input |
| `LemonGateway.Engines.CliAdapter` | `engines/cli_adapter.ex` | Shared CLI subprocess runner for all CLI engines |
| `LemonGateway.Engines.Lemon` | `engines/lemon.ex` | Native CodingAgent engine with steering |
| `LemonGateway.Engines.Claude` | `engines/claude.ex` | Claude Code CLI adapter |
| `LemonGateway.Engines.Codex` | `engines/codex.ex` | OpenAI Codex CLI adapter |
| `LemonGateway.Engines.Opencode` | `engines/opencode.ex` | Opencode CLI adapter |
| `LemonGateway.Engines.Pi` | `engines/pi.ex` | Pi CLI adapter |
| `LemonGateway.Engines.Echo` | `engines/echo.ex` | Test/debug echo engine |

### Transport Layer

| Module | File | Purpose |
|--------|------|---------|
| `LemonGateway.Transport` | `transport.ex` | Behaviour for transport plugins |
| `LemonGateway.TransportRegistry` | `transport_registry.ex` | Transport registration and enable/disable tracking |
| `LemonGateway.TransportSupervisor` | `transport_supervisor.ex` | Supervisor for enabled transports |
| `LemonGateway.Transports.Email` | `transports/email.ex` | Email transport |
| `LemonGateway.Transports.Email.Inbound` | `transports/email/inbound.ex` | Inbound email webhook handler |
| `LemonGateway.Transports.Email.Outbound` | `transports/email/outbound.ex` | SMTP outbound email delivery |
| `LemonGateway.Transports.Farcaster` | `transports/farcaster.ex` | Farcaster transport |
| `LemonGateway.Transports.Farcaster.FrameServer` | `transports/farcaster/frame_server.ex` | Farcaster Frame HTTP server |
| `LemonGateway.Transports.Farcaster.HubClient` | `transports/farcaster/hub_client.ex` | Farcaster Hub validation client |
| `LemonGateway.Transports.Farcaster.CastHandler` | `transports/farcaster/cast_handler.ex` | Cast processing handler |
| `LemonGateway.Transports.Discord` | `transports/discord.ex` | Discord transport helpers |
| `LemonGateway.Transports.Voice` | `transports/voice.ex` | Voice call transport |
| `LemonGateway.Transports.Webhook` | `transports/webhook.ex` | HTTP webhook transport (sync/async) |

### Binding and Rendering

| Module | File | Purpose |
|--------|------|---------|
| `LemonGateway.Binding` | `binding_resolver.ex` | Struct mapping transport/chat/topic to project/engine/queue_mode |
| `LemonGateway.BindingResolver` | `binding_resolver.ex` | Resolves engine, cwd, agent_id, queue_mode from `ChatScope` |
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

### Gateway Tools (injected into Lemon engine runs)

| Module | File | Purpose |
|--------|------|---------|
| `LemonGateway.Tools.Cron` | `tools/cron.ex` | Manage cron jobs via `LemonAutomation.CronManager` |
| `LemonGateway.Tools.SmsGetInboxNumber` | `tools/sms_get_inbox_number.ex` | Get the Twilio inbox phone number |
| `LemonGateway.Tools.SmsWaitForCode` | `tools/sms_wait_for_code.ex` | Block until a matching SMS verification code arrives |
| `LemonGateway.Tools.SmsListMessages` | `tools/sms_list_messages.ex` | List recent SMS messages |
| `LemonGateway.Tools.SmsClaimMessage` | `tools/sms_claim_message.ex` | Mark an SMS as claimed by the current session |
| `LemonGateway.Tools.TelegramSendImage` | `tools/telegram_send_image.ex` | Queue an image for Telegram delivery (Telegram sessions only) |

### Health

| Module | File | Purpose |
|--------|------|---------|
| `LemonGateway.Health` | `health.ex` | Health check system with built-in and custom checks |
| `LemonGateway.Health.Router` | `health/router.ex` | Plug router serving `GET /health` (port 4042) |

## Engine Lifecycle

### Start

1. `Run.init/1` acquires the `EngineLock` for the session's thread key (or fails fast with `:lock_timeout`).
2. `Run.handle_continue(:start_run)` resolves the engine from `EngineRegistry`, resolves the working directory, and calls `engine.start_run(job, opts, self())`.
3. The engine returns `{:ok, run_ref, cancel_ctx}`. For CLI engines, `CliAdapter` starts a runner subprocess and spawns a linked `Task` that consumes the runner's event stream.

### Streaming

- Engines send `{:engine_delta, run_ref, text}` messages for incremental text output.
- The Run process assigns monotonic sequence numbers, builds `Event.Delta` structs, and broadcasts them to `LemonCore.Bus`.
- First-token latency telemetry is emitted on the first delta.

### Completion

- Engines send `{:engine_event, run_ref, completed_event}` when done.
- The Run process stores chat state for auto-resume, emits `:run_completed` to the bus, finalizes the run in `LemonCore.Store`, releases the engine lock and scheduler slot, and notifies the worker and `meta.notify_pid`.
- On context-length overflow errors, the `ChatState` is automatically cleared so the next run starts fresh.

### Steering

- Only the Lemon engine supports steering (`supports_steer?/0` returns `true`).
- When a `ThreadWorker` receives a `:steer` or `:steer_backlog` mode job while a run is active, it casts `{:steer, job, self()}` to the Run process.
- The Run delegates to `engine.steer(cancel_ctx, text)` which injects the text into the active LemonRunner session.
- If steering is rejected (engine does not support it, run completed, or steer fails), the job falls back to `:followup` (for `:steer`) or `:collect` (for `:steer_backlog`).

### Cancellation

- `Runtime.cancel_by_run_id/2` looks up the run in `RunRegistry` and casts `{:cancel, reason}` to the run process.
- The Run calls `engine.cancel(cancel_ctx)`, emits a failed completion event, and terminates normally.

## Queue Modes

| Mode | Behavior |
|------|----------|
| `:collect` | Append to back of queue. Consecutive collect jobs at the front are coalesced into one. |
| `:followup` | Append with debounce merging (500ms window). Auto-promoted to `:steer_backlog` if a run is active and `meta.task_auto_followup` or `meta.delegated_auto_followup` is set. |
| `:steer` | Attempt to inject into active run. Falls back to `:followup` if rejected. |
| `:steer_backlog` | Attempt to inject into active run. Falls back to `:collect` if rejected. |
| `:interrupt` | Cancel the current run and insert at front of queue. |

Queue cap enforcement (`gateway.queue.cap`) drops either the oldest or newest jobs based on the `drop` policy when the cap is exceeded.

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
3. Lemon engine runs can use injected tools (`sms_wait_for_code`, `sms_list_messages`, `sms_claim_message`) to interact with the inbox.
4. Messages can be "claimed" to prevent cross-session conflicts.

## Binding System

Bindings map `transport + chat_id + topic_id` to a project, agent, engine, and queue mode:

```toml
[[gateway.bindings]]
transport = "telegram"
chat_id = 123456789
topic_id = 42
project = "myproject"
agent_id = "coder"
default_engine = "claude"
queue_mode = "steer"
```

`BindingResolver` delegates to `LemonCore.BindingResolver` and provides:
- `resolve_binding/1` -- most specific matching binding
- `resolve_engine/3` -- engine with priority cascade
- `resolve_cwd/1` -- project root directory
- `resolve_agent_id/1` -- agent identifier
- `resolve_queue_mode/1` -- queue mode from binding

## Configuration

Configuration loads from `~/.lemon/config.toml` (the `[gateway]` section) via `LemonCore.GatewayConfig.load/0` and `LemonGateway.ConfigLoader`.

### Core Options

| Key | Default | Description |
|-----|---------|-------------|
| `max_concurrent_runs` | `2` | Maximum concurrent AI runs across all threads |
| `default_engine` | `"lemon"` | Engine when no hint or resume token present |
| `default_cwd` | `nil` | Default working directory (falls back to `$HOME`) |
| `auto_resume` | `false` | Automatically resume sessions from stored `ChatState` |
| `require_engine_lock` | `true` | Acquire per-session mutex before engine runs |
| `engine_lock_timeout_ms` | `60000` | Timeout for engine lock acquisition |

### Transport Enable Flags

| Key | Default | Description |
|-----|---------|-------------|
| `enable_telegram` | `false` | Enable Telegram adapter (via `lemon_channels`) |
| `enable_discord` | `false` | Enable Discord adapter (via `lemon_channels`) |
| `enable_farcaster` | `false` | Enable Farcaster Frame transport |
| `enable_email` | `false` | Enable email transport |
| `enable_xmtp` | `false` | Enable XMTP transport |
| `enable_webhook` | `false` | Enable webhook transport |

### Queue Options (`[gateway.queue]`)

| Key | Default | Description |
|-----|---------|-------------|
| `mode` | `nil` | Default queue mode for jobs |
| `cap` | `nil` | Maximum jobs per thread queue (0 or nil = unlimited) |
| `drop` | `nil` | Drop policy when cap reached: `"oldest"` or `"newest"` |

### TOML Example

```toml
[gateway]
max_concurrent_runs = 2
default_engine = "lemon"
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
default_engine = "lemon"

[[gateway.bindings]]
transport = "telegram"
chat_id = 123456789
project = "myproject"
agent_id = "coder"
default_engine = "claude"
queue_mode = "steer"

[gateway.sms]
inbox_number = "+1234567890"
webhook_port = 4045

[gateway.engines.lemon]
enabled = true

[gateway.engines.claude]
enabled = true
cli_path = "/usr/local/bin/claude"
```

## Event Protocol

Engines emit events to the Run process as `{:engine_event, run_ref, event}` messages where events are plain tagged maps:

| Event Tag | Key Fields | Description |
|-----------|-----------|-------------|
| `:started` | `engine`, `resume`, `title`, `meta` | Run began, includes resume token |
| `:action_event` | `engine`, `action`, `phase`, `ok`, `message` | Tool/action progress |
| `:completed` | `engine`, `ok`, `answer`, `error`, `resume`, `usage` | Run finished |

Streaming text is sent as `{:engine_delta, run_ref, text}` with monotonic sequence numbers assigned by the Run process.

The Run re-emits all events to `LemonCore.Bus` as plain maps on topic `"run:<run_id>"`. Bus event types: `:run_started`, `:run_completed`, `:delta`, `:engine_started`, `:engine_completed`, `:engine_action`.

## Health Check

The health endpoint runs on port 4042 (configurable via `:health_port`). `GET /health` returns JSON with built-in checks for:

- Supervisor process liveness
- Scheduler state (in_flight count, waitq length, max slots)
- RunSupervisor active children
- EngineLock process liveness
- XMTP transport status (when enabled)

Custom health checks can be registered via the `:health_checks` application environment.

## Dependencies

### Umbrella Apps

| App | Purpose |
|-----|---------|
| `agent_core` | CLI runner infrastructure, tool types (`AgentTool`, `AgentToolResult`), event stream |
| `coding_agent` | Native Lemon AI engine (`CodingAgent.CliRunners.LemonRunner`, `CodingAgent.Session`) |
| `lemon_channels` | Telegram, Discord, XMTP adapters (compile-time only dependency, runtime: false) |
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

Tests use `async: false` by default due to shared GenServer state (Config, Scheduler, EngineRegistry). The test helper sets up an isolated lock directory to avoid collisions with running development instances.
