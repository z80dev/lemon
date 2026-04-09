# LemonGateway AGENTS.md

Gateway execution layer for the Lemon AI system. Handles engine lifecycle, execution-slot scheduling, transport ingress that still lives in gateway, and real-time run events on the bus.

## Quick Orientation

LemonGateway is the execution backend behind router-owned conversations. It does NOT render output to channels directly and it does NOT own queue semantics anymore. Router-owned `SessionCoordinator` processes decide collect/followup/steer/interrupt behavior and submit queue-semantic-free `ExecutionRequest` values into the gateway.

Gateway-native transports such as email, Farcaster, and webhook are ingress shims only. They normalize inbound requests to `LemonCore.RunRequest` and submit through `LemonCore.RouterBridge`; they must not call `LemonRouter.*` modules directly.

**Entry point**: `LemonGateway.Runtime.submit_execution(%ExecutionRequest{})`.
The old `LemonGateway.Runtime.submit/1` compatibility path is gone; do not reintroduce it.

**Core loop**: Router -> `ExecutionRequest` -> Scheduler -> ThreadWorker -> Run -> Engine -> bus events.

**Key principle**: Gateway owns slot allocation, worker/process lifecycle, and engine safety rails. `ThreadWorker` is now a dumb per-conversation launcher; `EngineLock` remains defense-in-depth, not the source of product semantics.

## Architecture

```
+-----------------------------------------------------------------------+
|                           Transports                                   |
|  Telegram (lemon_channels)  Discord (lemon_channels)  XMTP (lemon_ch) |
|  Email (SMTP/webhook)  SMS (Twilio)  Voice (Twilio/Deepgram)          |
|  Farcaster (Frame)  Webhook (HTTP sync/async)                          |
+-------------------------------------+---------------------------------+
                                      |
                RunRequest via LemonCore.RouterBridge.submit_run/1
                                      |
                          LemonRouter.RunOrchestrator
                                      |
                         Runtime.submit_execution/1
                                      |
+-------------------------------------+---------------------------------+
|                          Scheduler                                     |
|  - Accept already-resolved execution requests                          |
|  - Derive thread_key from router-provided conversation_key/session     |
|  - Route to ThreadWorker (create if needed via ThreadWorkerSupervisor) |
|  - Slot allocation: max_concurrent_runs concurrency limit              |
+-------------------------------------+---------------------------------+
                                      |
                          ThreadWorker (per session)
|  - Simple FIFO request launcher for one conversation key               |
|  - Request slot -> on grant -> start Run via RunSupervisor             |
|  - Terminate when idle (queue empty + no active run)                   |
+-------------------------------------+---------------------------------+
                                      |
                              Run (GenServer)
|  - Acquire EngineLock                                                  |
|  - Resolve engine from EngineRegistry                                  |
|  - Call engine.start_run(job, opts, self())                            |
|  - Receive {:engine_event, run_ref, event} and {:engine_delta, ...}    |
|  - Broadcast to LemonCore.Bus("run:<run_id>")                         |
|  - Store ChatState on completion for auto-resume                       |
|  - Release lock + slot on finalize                                     |
+-------------------------------------+---------------------------------+
                                      |
                              Engine (behaviour)
|  Lemon (native CodingAgent) | Claude (CLI) | Codex (CLI)              |
|  Opencode (CLI) | Pi (CLI) | Echo (test)                              |
+-----------------------------------------------------------------------+
```

### Bus Event Flow

```
Run -> LemonCore.Bus("run:<run_id>") -> LemonRouter.RunProcess
                                     -> LemonRouter.StreamCoalescer
                                     -> LemonChannels.Outbox -> Telegram/Discord/etc.
```

Bus event types: `:run_started`, `:run_completed`, `:delta`, `:engine_started`, `:engine_completed`, `:engine_action`.

## Key Files and Purposes

### Core Pipeline (read these first)

| File | Module | What It Does |
|------|--------|-------------|
| `lib/lemon_gateway.ex` | `LemonGateway` | Public API facade for execution submission and health helpers. |
| `lib/lemon_gateway/runtime.ex` | `Runtime` | Submit and cancel API. Preferred entry is `submit_execution/1`. |
| `lib/lemon_gateway/execution_request.ex` | `ExecutionRequest` | Gateway input contract with no queue-mode semantics. |
| `lib/lemon_gateway/scheduler.ex` | `Scheduler` | GenServer: thread routing plus slot-based concurrency (`max_concurrent_runs`). |
| `lib/lemon_gateway/thread_worker.ex` | `ThreadWorker` | GenServer: per-conversation launcher/slot waiter, no collect/followup/interrupt policy. |
| `lib/lemon_gateway/run.ex` | `Run` | GenServer: engine lifecycle, bus event emission, steer/cancel, lock management |
| `lib/lemon_gateway/engine.ex` | `Engine` | Behaviour: `id/0`, `start_run/3`, `cancel/1`, `supports_steer?/0`, `steer/2`, resume callbacks |
| `lib/lemon_gateway/types.ex` | `Types`, `Types.Job` | Legacy compatibility types. Do not add new queue semantics here. |
| `lib/lemon_gateway/event.ex` | `Event`, `Event.Delta` | Event constructors (`:started`, `:action_event`, `:completed`) and `Delta` struct |

### Engine Implementations

| File | Module | Notes |
|------|--------|-------|
| `lib/lemon_gateway/engines/cli_adapter.ex` | `Engines.CliAdapter` | **Read this first.** Shared logic for all CLI engines: subprocess start, event stream consumption, resume formatting, cancellation. Also handles gateway tool injection for the lemon engine. |
| `lib/lemon_gateway/engines/lemon.ex` | `Engines.Lemon` | Native engine: delegates to `CodingAgent.CliRunners.LemonRunner`. Only engine that supports steering. Ensures `:coding_agent` app is started. |
| `lib/lemon_gateway/engines/claude.ex` | `Engines.Claude` | Claude Code CLI: delegates to CliAdapter with `AgentCore.CliRunners.ClaudeRunner` |
| `lib/lemon_gateway/engines/codex.ex` | `Engines.Codex` | Codex CLI: delegates to CliAdapter with `AgentCore.CliRunners.CodexRunner` |
| `lib/lemon_gateway/engines/droid.ex` | `Engines.Droid` | Factory Droid CLI: delegates to CliAdapter with `AgentCore.CliRunners.DroidRunner` |
| `lib/lemon_gateway/engines/opencode.ex` | `Engines.Opencode` | Opencode CLI: delegates to CliAdapter with `AgentCore.CliRunners.OpencodeRunner` |
| `lib/lemon_gateway/engines/pi.ex` | `Engines.Pi` | Pi CLI: delegates to CliAdapter with `AgentCore.CliRunners.PiRunner` |
| `lib/lemon_gateway/engines/echo.ex` | `Engines.Echo` | Test engine: echoes prompt back, no subprocess, useful for integration tests |

### Configuration and Resolution

Gateway config comes from the canonical TOML `[gateway]` section only, via `LemonCore.GatewayConfig`. Transport config (Telegram, Discord, XMTP) is read exclusively from the canonical gateway config path -- not from `Application.get_env` overlays. Test-only override via `Application.get_env(:lemon_gateway, LemonGateway.Config)` is allowed only in test env.

| File | Module | Notes |
|------|--------|-------|
| `lib/lemon_gateway/config.ex` | `Config` | GenServer holding all runtime config. Access via `Config.get/0` or `Config.get(:key)`. |
| `lib/lemon_gateway/config_loader.ex` | `ConfigLoader` | Loads from `LemonCore.GatewayConfig.load/0` and parses into typed structs (Project, Binding, queue, SMS, email, etc.) |
| `lib/lemon_gateway/binding_resolver.ex` | `BindingResolver` | Resolves engine/cwd/agent metadata for gateway-owned transports. Delegates to `LemonCore.BindingResolver`. |
| `lib/lemon_gateway/engine_directive.ex` | `EngineDirective` | Strips `/claude`, `/codex`, `/lemon`, etc. from user input to select engine |
| `lib/lemon_gateway/engine_registry.ex` | `EngineRegistry` | GenServer: engine ID -> module mapping. Also does cross-engine resume token extraction. |
| `lib/lemon_gateway/engine_lock.ex` | `EngineLock` | GenServer: per-session mutex with FIFO wait queue, configurable timeout, process monitoring, stale lock sweeping |

### Registries and Supervisors

| File | Module | Notes |
|------|--------|-------|
| `lib/lemon_gateway/application.ex` | `Application` | OTP supervision tree: Config, registries, schedulers, SMS, voice, health server |
| `lib/lemon_gateway/run_supervisor.ex` | `RunSupervisor` | DynamicSupervisor for Run processes (temporary restart strategy) |
| `lib/lemon_gateway/thread_registry.ex` | `ThreadRegistry` | Unique-key Registry wrapper for ThreadWorker lookup by thread_key |
| `lib/lemon_gateway/thread_worker_supervisor.ex` | `ThreadWorkerSupervisor` | DynamicSupervisor for ThreadWorker processes |
| `lib/lemon_gateway/transport_registry.ex` | `TransportRegistry` | GenServer: transport ID -> module mapping with enable/disable awareness |
| `lib/lemon_gateway/transport_supervisor.ex` | `TransportSupervisor` | Supervisor starting all enabled transports |

### Voice System

| File | Module | Notes |
|------|--------|-------|
| `lib/lemon_gateway/voice/call_session.ex` | `Voice.CallSession` | Per-call GenServer: manages Deepgram STT, ElevenLabs TTS, LLM pipeline |
| `lib/lemon_gateway/voice/twilio_websocket.ex` | `Voice.TwilioWebSocket` | WebSocket handler for Twilio Media Streams (mulaw audio) |
| `lib/lemon_gateway/voice/deepgram_client.ex` | `Voice.DeepgramClient` | WebSocket client for Deepgram real-time STT |
| `lib/lemon_gateway/voice/recording_manager.ex` | `Voice.RecordingManager` | Starts dual-channel recording via Twilio REST API |
| `lib/lemon_gateway/voice/recording_downloader.ex` | `Voice.RecordingDownloader` | Downloads recordings as WAV to `~/.lemon/recordings/<date>/` |
| `lib/lemon_gateway/voice/webhook_router.ex` | `Voice.WebhookRouter` | Plug router for voice webhooks (TwiML response, WebSocket upgrade) |
| `lib/lemon_gateway/voice/audio_conversion.ex` | `Voice.AudioConversion` | PCM-to-mulaw transcoding and MP3/ID3 detection |
| `lib/lemon_gateway/voice/config.ex` | `Voice.Config` | Voice credential resolution (Twilio, Deepgram, ElevenLabs) |

### SMS System

| File | Module | Notes |
|------|--------|-------|
| `lib/lemon_gateway/sms/inbox.ex` | `Sms.Inbox` | GenServer: stores inbound SMS, extracts verification codes, supports wait/claim |
| `lib/lemon_gateway/sms/webhook_server.ex` | `Sms.WebhookServer` | Bandit HTTP server for Twilio SMS webhooks |
| `lib/lemon_gateway/sms/webhook_router.ex` | `Sms.WebhookRouter` | Plug router handling inbound SMS |
| `lib/lemon_gateway/sms/twilio_signature.ex` | `Sms.TwilioSignature` | HMAC-SHA1 signature validation for Twilio webhooks |

### Gateway-Injected Tools

These tools are added to Lemon engine runs only (not CLI engines) via `CliAdapter.gateway_extra_tools/3`:

| File | Module | Notes |
|------|--------|-------|
| `lib/lemon_gateway/tools/cron.ex` | `Tools.Cron` | Manage cron jobs (status, list, add, update, remove, run, runs) |
| `lib/lemon_gateway/tools/sms_get_inbox_number.ex` | `Tools.SmsGetInboxNumber` | Get the Twilio inbox phone number |
| `lib/lemon_gateway/tools/sms_wait_for_code.ex` | `Tools.SmsWaitForCode` | Block until matching SMS code arrives |
| `lib/lemon_gateway/tools/sms_list_messages.ex` | `Tools.SmsListMessages` | List recent SMS messages |
| `lib/lemon_gateway/tools/sms_claim_message.ex` | `Tools.SmsClaimMessage` | Mark a message as claimed by session |
| `lib/lemon_gateway/tools/telegram_send_image.ex` | `Tools.TelegramSendImage` | Queue image for Telegram delivery (Telegram sessions only) |
| `lib/lemon_gateway/tools/discord_send_file.ex` | `Tools.DiscordSendFile` | Queue a file for Discord delivery (Discord sessions only) |

## How to Add a New Engine

### Step 1: Create the Engine Module

Create `lib/lemon_gateway/engines/my_engine.ex`:

```elixir
defmodule LemonGateway.Engines.MyEngine do
  @behaviour LemonGateway.Engine

  alias LemonCore.ResumeToken
  alias LemonGateway.Types.Job
  alias LemonGateway.Event

  @impl true
  def id, do: "myengine"

  @impl true
  def format_resume(%ResumeToken{value: v}), do: "myengine --resume #{v}"

  @impl true
  def extract_resume(text) do
    case Regex.run(~r/myengine\s+--resume\s+(\S+)/i, text) do
      [_, value] -> %ResumeToken{engine: id(), value: value}
      _ -> nil
    end
  end

  @impl true
  def is_resume_line(line) do
    Regex.match?(~r/^\s*`?myengine\s+--resume\s+\S+`?\s*$/i, line)
  end

  @impl true
  def supports_steer?, do: false

  @impl true
  def start_run(%Job{} = job, opts, sink_pid) do
    run_ref = make_ref()
    resume = job.resume || %ResumeToken{engine: id(), value: UUID.uuid4()}

    # Option A: Use CliAdapter for CLI-based engines
    # LemonGateway.Engines.CliAdapter.start_run(MyRunner, id(), job, opts, sink_pid)

    # Option B: Custom implementation
    {:ok, task_pid} = Task.start(fn ->
      send(sink_pid, {:engine_event, run_ref, Event.started(%{engine: id(), resume: resume})})
      # ... do AI work, optionally send deltas ...
      send(sink_pid, {:engine_delta, run_ref, "partial output"})
      send(sink_pid, {:engine_event, run_ref, Event.completed(%{
        engine: id(), ok: true, answer: "full answer", resume: resume
      })})
    end)

    {:ok, run_ref, %{task_pid: task_pid}}
  end

  @impl true
  def cancel(%{task_pid: pid}) when is_pid(pid) do
    Process.exit(pid, :kill)
    :ok
  end
end
```

### Step 2: Register the Engine

Add to `config/config.exs` or the application env:

```elixir
config :lemon_gateway, :engines, [
  LemonGateway.Engines.Lemon,
  LemonGateway.Engines.Echo,
  LemonGateway.Engines.Codex,
  LemonGateway.Engines.Claude,
  LemonGateway.Engines.Opencode,
  LemonGateway.Engines.Pi,
  LemonGateway.Engines.MyEngine  # Add here
]
```

Or modify the default list in `EngineRegistry.init/1`.

### Step 3: Update EngineDirective (optional)

If you want `/myengine` prefix support, update the regex in `EngineDirective.strip/1`:

```elixir
~r{^/(lemon|codex|claude|droid|opencode|pi|echo|myengine)\b\s*(.*)$}is
```

### Event Protocol

Engines MUST send to `sink_pid`:

1. `{:engine_event, run_ref, Event.started(%{engine: id, resume: token})}` -- at start
2. `{:engine_delta, run_ref, "text"}` -- for streaming (optional, zero or more)
3. `{:engine_event, run_ref, Event.completed(%{engine: id, ok: bool, answer: text, ...})}` -- at end (exactly once)

Optional: `{:engine_event, run_ref, Event.action_event(%{...})}` for tool/action progress.

### If Using CliAdapter

For CLI-based engines wrapping an `AgentCore.CliRunners.*` module, the implementation is minimal. See `Engines.Claude` as a template -- it is ~35 lines, delegating everything to `CliAdapter`.

## How to Add a New Transport

### Step 1: Create the Transport Module

```elixir
defmodule LemonGateway.Transports.MyTransport do
  use GenServer
  use LemonGateway.Transport

  alias LemonGateway.{BindingResolver, Runtime}
  alias LemonGateway.Types.Job
  alias LemonCore.ChatScope

  @impl LemonGateway.Transport
  def id, do: "mytransport"

  @impl LemonGateway.Transport
  def start_link(opts) do
    if LemonGateway.Config.get(:enable_mytransport) == true do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    else
      :ignore
    end
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  def handle_info({:incoming_message, data}, state) do
    scope = %ChatScope{transport: :mytransport, chat_id: data.chat_id}

    request = %LemonGateway.ExecutionRequest{
      run_id: LemonCore.Id.run_id(),
      session_key: "mytransport:#{data.chat_id}:#{data.user_id}",
      prompt: data.text,
      engine_id: BindingResolver.resolve_engine(scope, nil, nil),
      cwd: BindingResolver.resolve_cwd(scope),
      conversation_key: {:session, "mytransport:#{data.chat_id}:#{data.user_id}"},
      meta: %{origin: :mytransport, notify_pid: self()}
    }

    Runtime.submit_execution(request)
    {:noreply, state}
  end

  def handle_info({:lemon_gateway_run_completed, _job, completed}, state) do
    # Handle completion
    {:noreply, state}
  end
end
```

### Step 2: Register

Add to `:transports` in application config, or modify `TransportRegistry.init/1`.

### Best Practices

- Prefer `Runtime.submit_execution/1` (never call Scheduler directly)
- Set `meta.notify_pid: self()` to receive `{:lemon_gateway_run_completed, job, completed}`
- Build stable, unique `session_key` strings (transport:chat:user or similar)
- Return `:ignore` from `start_link/1` when disabled
- Use `BindingResolver` to respect config bindings for engine/cwd/agent metadata

## How to Add Gateway Tools

Gateway tools are injected into Lemon engine runs only (not CLI engines).

### Step 1: Create the Tool Module

```elixir
defmodule LemonGateway.Tools.MyTool do
  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent

  def tool(_cwd, opts \\ []) do
    %AgentTool{
      name: "my_tool",
      description: "Does something useful",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "param" => %{"type" => "string", "description" => "A parameter"}
        },
        "required" => ["param"]
      },
      execute: fn _id, params, _signal, _on_update ->
        result = do_work(params["param"])
        %AgentToolResult{
          content: [%TextContent{text: result}],
          details: %{param: params["param"]}
        }
      end
    }
  end
end
```

### Step 2: Register in CliAdapter

Add to `gateway_extra_tools/3` in `lib/lemon_gateway/engines/cli_adapter.ex`:

```elixir
defp gateway_extra_tools("lemon", job, opts) do
  cwd = job.cwd || Map.get(opts, :cwd) || File.cwd!()
  [
    LemonGateway.Tools.MyTool.tool(cwd, session_key: job.session_key),
    # ... existing tools ...
  ]
end
```

## Testing Guidance

### Running Tests

```bash
# All gateway tests
mix test apps/lemon_gateway

# Specific file
mix test apps/lemon_gateway/test/run_test.exs

# Specific test by line number
mix test apps/lemon_gateway/test/scheduler_test.exs:42

# With tracing
mix test apps/lemon_gateway --trace
```

### Test Structure

Tests are in `apps/lemon_gateway/test/`. Key test files:

| Test File | What It Tests |
|-----------|---------------|
| `run_test.exs` | Run GenServer: init, events, steering, cancellation, lock handling |
| `scheduler_test.exs` | Scheduler: slot allocation and thread routing |
| `thread_worker_test.exs` | ThreadWorker: launch/slot lifecycle and crash handling |
| `engine_registry_test.exs` | Engine registration, lookup, resume extraction |
| `engine_lock_test.exs` | EngineLock: acquire/release, FIFO queueing, timeouts |
| `engine_directive_test.exs` | Directive parsing (`/claude text` -> `{"claude", "text"}`) |
| `config_loader_test.exs` | TOML config parsing into typed structs |
| `binding_resolver_test.exs` | Binding resolution for engine, cwd, agent_id |
| `chat_state_test.exs` | ChatState struct operations |
| `command_registry_test.exs` | Command registration and validation |
| `cancel_flow_test.exs` | End-to-end cancel flow |

`LemonGateway.Run` must convert `engine.start_run/3` crashes into normal error completions so slots, locks, and router observers are always released. Do not let engine startup exceptions kill the run process before `:run_completed` is emitted.
| `queue_mode_test.exs` | Router/gateway boundary coverage for legacy queue-mode adapters that still normalize into `ExecutionRequest` |
| `run_transport_agnostic_test.exs` | Run process transport-agnostic behavior |
| `cli_adapter_test.exs` | CliAdapter shared logic |
| `cli_adapter_claude_test.exs` | Claude-specific CliAdapter behavior |
| `engines/claude_engine_test.exs` | Claude engine unit tests |
| `engines/codex_engine_test.exs` | Codex engine unit tests |
| `lemon_engine_test.exs` | Lemon engine unit tests |
| `renderers/basic_test.exs` | Basic renderer event-to-text |
| `health_test.exs` | Health check system |
| `sms/inbox_test.exs` | SMS inbox store and query |
| `sms/webhook_router_test.exs` | SMS webhook handling |
| `sms/twilio_signature_test.exs` | Twilio signature validation |
| `lemon_gateway/voice/*_test.exs` | Voice subsystem tests |
| `integration/*_test.exs` | Integration tests for engine pipelines |

### Writing Tests

Most tests use `async: false` because they interact with shared GenServers (Config, Scheduler, EngineRegistry). The test helper (`test/test_helper.exs`) sets up:
- Port 0 for web server (random free port)
- Isolated lock directory to avoid collisions with running dev instances

For engine tests, define a test engine module implementing the `Engine` behaviour (see `RunTest.TestEngine` in `run_test.exs` as a template).

For Run tests, you need to set up: `EngineRegistry` (or mock it), `EngineLock`, `RunSupervisor`, `Scheduler`, and `ThreadWorkerSupervisor`. Many tests start the full `LemonGateway.Application` supervision tree.

### Common Test Patterns

```elixir
# Create a test execution request
request = %LemonGateway.ExecutionRequest{
  run_id: LemonCore.Id.run_id(),
  session_key: "test:#{System.unique_integer([:positive])}",
  prompt: "test prompt",
  engine_id: "echo",
  conversation_key: {:session, "test:conversation"},
  meta: %{notify_pid: self()}
}

# Submit and wait for completion
LemonGateway.Runtime.submit_execution(request)
assert_receive {:lemon_gateway_run_completed, _job, completed}, 5000
assert completed.ok == true
```

## Connections to Other Apps

### Dependencies (this app depends on)

| App | What LemonGateway Uses |
|-----|----------------------|
| `agent_core` | `AgentCore.CliRunners.*` (ClaudeRunner, CodexRunner, etc.), `AgentCore.EventStream`, `AgentCore.Types.*` |
| `coding_agent` | `CodingAgent.CliRunners.LemonRunner` (native engine), `CodingAgent.Session`, `CodingAgent.Config` |
| `lemon_core` | `LemonCore.Store` (chat state, runs, progress), `LemonCore.Bus` (event broadcast), `LemonCore.Telemetry`, `LemonCore.ResumeToken`, `LemonCore.ChatScope`, `LemonCore.Binding`, `LemonCore.BindingResolver`, `LemonCore.Secrets`, `LemonCore.GatewayConfig`, `LemonCore.Introspection`, `LemonCore.Event` |
| `lemon_channels` | Compile-time only (`runtime: false`). Telegram/Discord/XMTP adapters are implemented there but consume gateway bus events. |

### Dependents (apps that depend on this)

| App | How It Uses LemonGateway |
|-----|-------------------------|
| `lemon_router` | Subscribes to `LemonCore.Bus` events from Run processes, manages `RunProcess` and `StreamCoalescer` |
| `lemon_channels` | Subscribes to bus events for channel-specific rendering and delivery |
| `lemon_control_plane` | May submit jobs or cancel runs via `Runtime` API |
| `lemon_automation` | Submits jobs for scheduled/cron runs |

### Key Integration Points

1. **Execution submission**: Prefer `LemonGateway.Runtime.submit_execution(%ExecutionRequest{})` to trigger an AI run.
2. **Completion notification**: Set `meta.notify_pid` to receive `{:lemon_gateway_run_completed, job, completed}` when a run finishes.
3. **Bus events**: Subscribe to `LemonCore.Bus` topic `"run:<run_id>"` to receive real-time run events.
4. **Run cancellation**: Call `LemonGateway.Runtime.cancel_by_run_id/2` with the run_id.
5. **Chat state**: `LemonCore.ChatStateStore` manages auto-resume tokens per session.

## Common Debugging

### Inspect Runtime State

```elixir
# Scheduler (in_flight, waitq, max slots)
:sys.get_state(LemonGateway.Scheduler)

# Engine locks (active locks, waiters)
:sys.get_state(LemonGateway.EngineLock)

# Active thread workers
DynamicSupervisor.which_children(LemonGateway.ThreadWorkerSupervisor)

# Active runs
DynamicSupervisor.which_children(LemonGateway.RunSupervisor)

# Look up a specific run
Registry.lookup(LemonGateway.RunRegistry, "run_uuid")

# List registered engines
LemonGateway.EngineRegistry.list_engines()

# Check config value
LemonGateway.Config.get(:max_concurrent_runs)
LemonGateway.Config.get(:auto_resume)
```

### Common Issues

**Stuck runs / slots not releasing**:
- Check `Scheduler` state: `map_size(state.in_flight)` vs `state.max`
- Check `EngineLock` for stale locks (auto-reaped every 30s by default)
- Stale slot requests cleaned up after 30s timeout

**Engine not found**:
- Verify registration: `LemonGateway.EngineRegistry.list_engines()`
- Check composite ID resolution: `"claude:model"` resolves to `"claude"` prefix

**Auto-resume not working**:
- Verify `auto_resume = true` in config
- Check `LemonCore.ChatStateStore.get(session_key)` for stored resume token
- Resume only applies if engine matches (or no engine_id set on job)

**Context overflow**:
- Run auto-clears `ChatState` on context-length errors (multiple languages detected)
- Next run starts fresh without resume token

**Transport not starting**:
- Discord is channels-owned; check `LemonChannels.Application` / adapter boot, not gateway transport startup
- Check `TransportRegistry.enabled_transports()`
- Gateway transport startup here applies only to gateway-native transports

## Introspection Events

ThreadWorker and Scheduler emit introspection events via `LemonCore.Introspection.record/3`:

| Event Type | When | Key Fields |
|---|---|---|
| `:thread_started` | ThreadWorker init | `thread_key` |
| `:thread_message_dispatched` | Request enqueued to worker | `thread_key`, `queue_len` |
| `:thread_terminated` | ThreadWorker terminate | `thread_key`, `queue_len` |
| `:scheduled_job_triggered` | Scheduler receives submit | `engine_id`, `thread_key` |
| `:scheduled_job_completed` | Scheduler releases slot | `in_flight`, `max` |

## Telemetry Events

Emitted via `LemonCore.Telemetry`:

| Event | When | Measurements |
|---|---|---|
| `[:lemon, :gateway, :scheduler, :slot_granted]` | Slot allocated to worker | `in_flight`, `max`, `waitq`, `wait_ms` |
| `[:lemon, :gateway, :scheduler, :slot_queued]` | Worker queued for slot | `in_flight`, `max`, `waitq` |
| `[:lemon, :gateway, :scheduler, :slot_released]` | Slot freed | `in_flight`, `max`, `waitq` |
| `run_start` | Run begins | `session_key`, `engine`, `origin` |
| `run_first_token` | First delta received | `run_id`, `latency_ms` |
| `run_stop` | Run completes | `run_id`, `duration_ms`, `ok?` |

## Dependencies

### Umbrella Apps
- `agent_core` -- CLI runner infrastructure, tool types, event stream
- `coding_agent` -- Native Lemon engine runner, session management
- `lemon_channels` -- Telegram/Discord/XMTP adapters (compile-time dep, `runtime: false`)
- `lemon_core` -- Store, Bus, Telemetry, types, secrets, config loading

### External Libraries
- `jason` -- JSON encoding/decoding
- `uuid` -- UUID generation for run IDs
- `toml` -- TOML config parsing
- `plug` + `bandit` -- HTTP servers (health :4042, SMS webhooks, voice webhooks)
- `gen_smtp` + `mail` -- SMTP email handling
- `earmark_parser` -- Markdown to Telegram entity rendering
- `websockex` + `websock_adapter` -- WebSocket clients (Deepgram STT, Twilio Media Streams)
