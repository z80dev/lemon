# LemonGateway AGENTS.md

Gateway and transport layer for the Lemon AI system. Handles all external messaging transports, AI engine management, and job scheduling.

## Purpose and Responsibilities

**LemonGateway** is the message gateway that:

1. **Transports**: Receives messages from Email, SMS, Voice, Webhook, and Farcaster (Telegram/Discord/XMTP delegated to `lemon_channels`)
2. **Engines**: Manages AI execution via native Lemon, Claude, Codex, OpenCode, Pi, and Echo engines
3. **Scheduling**: Concurrent job execution with slot-based scheduling and per-session thread workers
4. **State Management**: Chat state persistence, auto-resume, and conversation locking
5. **SMS Utilities**: Inbox for receiving SMS codes (2FA, verification)
6. **Voice Calls**: Real-time phone calls via Twilio + Deepgram + ElevenLabs
7. **Commands**: Slash command dispatch (`/cancel`, custom commands)

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Transports                               │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐   │
│  │Telegram │ │Discord  │ │ Email   │ │  SMS    │ │  Voice  │   │
│  │(lemon_  │ │(lemon_  │ │(SMTP/  │ │(Twilio) │ │(Twilio/ │   │
│  │channels)│ │channels)│ │ webhook)│ │         │ │Deepgram)│   │
│  └────┬────┘ └────┬────┘ └────┬────┘ └────┬────┘ └────┬────┘   │
│       └─────────────┴─────────┴─────────┴─────────┘             │
│                              │                                  │
│                       Runtime.submit/1                          │
│                              │                                  │
├──────────────────────────────┼──────────────────────────────────┤
│                           Scheduler                             │
│  ┌───────────────────────────┼──────────────────────────────┐  │
│  │                    Slot Manager                          │  │
│  │              (max_concurrent_runs, default: 2)           │  │
│  └───────────────────────────┼──────────────────────────────┘  │
│                              │                                  │
│                     ThreadWorker (per session)                 │
│  ┌───────────────────────────┼──────────────────────────────┐  │
│  │              Job Queue (queue_mode)                       │  │
│  │  :collect | :followup | :steer | :steer_backlog | :interrupt │
│  └───────────────────────────┼──────────────────────────────┘  │
│                              │                                  │
├──────────────────────────────┼──────────────────────────────────┤
│                           Engines                              │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐  │
│  │  Lemon  │ │  Codex  │ │ Claude  │ │OpenCode │ │ Pi/Echo │  │
│  │ (native)│ │(CLI)    │ │(CLI)    │ │(CLI)    │ │(CLI/test│  │
│  └─────────┘ └─────────┘ └─────────┘ └─────────┘ └─────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### Event Bus Flow

Run processes broadcast events to `LemonCore.Bus` on topic `"run:<run_id>"`. Subscribers (router, channels, control-plane) receive these events for channel-specific delivery. The gateway itself does **not** write to Telegram or other channels directly.

```
Run -> LemonCore.Bus("run:<run_id>") -> LemonRouter.RunProcess
                                     -> LemonRouter.StreamCoalescer
                                     -> LemonChannels.Outbox
```

Bus event types: `:run_started`, `:run_completed`, `:delta`, `:engine_started`, `:engine_completed`, `:engine_action`

## Key Modules

### Core

| Module | Purpose |
|--------|---------|
| `LemonGateway.Application` | OTP supervision tree startup |
| `LemonGateway.Runtime` | Public API: `submit/1`, `cancel_by_run_id/2`, `cancel_by_progress_msg/2` |
| `LemonGateway.Config` | TOML-backed runtime configuration (GenServer); default `max_concurrent_runs: 2` |
| `LemonGateway.Store` | Gateway storage API (delegates to LemonCore.Store) |
| `LemonGateway.ChatState` | Session state struct for auto-resume |
| `LemonGateway.Binding` | Struct mapping transport/chat/topic to project, agent, engine, queue_mode |
| `LemonGateway.BindingResolver` | Resolves engine, cwd, agent_id, queue_mode from a `ChatScope` |
| `LemonGateway.EngineDirective` | Strips leading `/engine` prefix from messages (e.g. `/claude fix this`) |
| `LemonGateway.AI` | Direct HTTP completions for OpenAI (`gpt-*`) and Anthropic (`claude-*`) models |
| `LemonGateway.Health` | Health check system; HTTP endpoint at port 4042 (`GET /health`) |
| `LemonGateway.Run` | Individual run execution - manages engine lifecycle, emits bus events, handles steer/cancel |

### Transport Layer

| Module | Purpose |
|--------|---------|
| `LemonGateway.Transport` | Behaviour for transport plugins (`id/0`, `start_link/1`, optional `child_spec/1`) |
| `LemonGateway.TransportRegistry` | Transport registration and lookup |
| `LemonGateway.TransportSupervisor` | Dynamic supervisor for transports |
| `LemonGateway.Transports.Email` | Email inbound/outbound (inbound webhook + SMTP delivery) |
| `LemonGateway.Transports.Voice` | Voice call transport |
| `LemonGateway.Transports.Webhook` | Generic webhook receiver |
| `LemonGateway.Transports.Farcaster` | Farcaster integration |
| `LemonGateway.Transports.Xmtp` | XMTP stub - legacy removed; delegates status to `lemon_channels` adapter |

**Note**: Telegram, Discord, and XMTP transports are implemented in the `lemon_channels` umbrella app. The `LemonGateway.Telegram.*` namespace contains Telegram-specific helpers used by `lemon_channels`.

### Engine Layer

| Module | Purpose |
|--------|---------|
| `LemonGateway.Engine` | Behaviour for AI engines |
| `LemonGateway.EngineRegistry` | Engine registration and lookup |
| `LemonGateway.EngineLock` | Per-session mutex for engine runs |
| `LemonGateway.Engines.Lemon` | Native Elixir engine (`CodingAgent.CliRunners.LemonRunner`); supports steering |
| `LemonGateway.Engines.Codex` | OpenAI Codex CLI wrapper |
| `LemonGateway.Engines.Claude` | Claude CLI wrapper |
| `LemonGateway.Engines.OpenCode` | OpenCode CLI wrapper |
| `LemonGateway.Engines.Pi` | Pi CLI wrapper |
| `LemonGateway.Engines.Echo` | Test/debug engine that echoes the prompt back; no subprocess |
| `LemonGateway.Engines.CliAdapter` | Shared CLI subprocess runner used by all CLI engines |

### Scheduling

| Module | Purpose |
|--------|---------|
| `LemonGateway.Scheduler` | Slot-based concurrency limiter (GenServer) |
| `LemonGateway.ThreadWorker` | Per-session job queue worker (GenServer); terminates when idle |
| `LemonGateway.ThreadRegistry` | Registry for thread workers (keyed by `thread_key`) |
| `LemonGateway.ThreadWorkerSupervisor` | Dynamic supervisor for workers |
| `LemonGateway.RunSupervisor` | Dynamic supervisor for individual runs |
| `LemonGateway.RunRegistry` | Registry for active runs keyed by `run_id`; used for cancel-by-id |
| `LemonGateway.Run` | Individual run process |

### Command System

| Module | Purpose |
|--------|---------|
| `LemonGateway.Command` | Behaviour for slash command plugins (`name/0`, `description/0`, `handle/3`) |
| `LemonGateway.CommandRegistry` | Registry for command modules; loaded from `:commands` app env |
| `LemonGateway.Commands.Cancel` | Built-in `/cancel` command |

### SMS

| Module | Purpose |
|--------|---------|
| `LemonGateway.Sms.Inbox` | Store and query inbound SMS messages |
| `LemonGateway.Sms.WebhookServer` | HTTP server for Twilio webhooks |
| `LemonGateway.Sms.WebhookRouter` | Router for SMS webhooks |
| `LemonGateway.Sms.TwilioSignature` | Webhook signature validation |

### Voice

| Module | Purpose |
|--------|---------|
| `LemonGateway.Voice.CallSession` | Single call session management |
| `LemonGateway.Voice.TwilioWebSocket` | WebSocket handler for Twilio |
| `LemonGateway.Voice.DeepgramClient` | STT WebSocket client |
| `LemonGateway.Voice.WebhookRouter` | Voice webhook routing |

### Types

| Module | Purpose |
|--------|---------|
| `LemonGateway.Types.Job` | Transport-agnostic job definition |
| `LemonGateway.Types.ChatScope` | Transport-specific chat ID (`transport`, `chat_id`, `topic_id`) |
| `LemonGateway.Types.ResumeToken` | Session resume token (`engine`, `value`) |

### Tools (injected into Lemon engine runs)

| Module | Purpose |
|--------|---------|
| `LemonGateway.Tools.Cron` | Manage `LemonAutomation.CronManager` cron jobs (`status`, `list`, `add`, `update`, `remove`, `run`, `runs`) |
| `LemonGateway.Tools.SmsGetInboxNumber` | Get Twilio inbox number |
| `LemonGateway.Tools.SmsWaitForCode` | Block until matching SMS arrives |
| `LemonGateway.Tools.SmsListMessages` | List recent SMS messages |
| `LemonGateway.Tools.SmsClaimMessage` | Mark a message as claimed by a session |
| `LemonGateway.Tools.TelegramSendImage` | Queue an image for Telegram delivery (Telegram sessions only) |

## Core Types

### Job

```elixir
%LemonGateway.Types.Job{
  run_id: "run_uuid",          # Generated if nil
  session_key: "transport:...", # Stable key for routing and state
  prompt: "user text",
  engine_id: "lemon",           # Resolved engine
  cwd: "/path/to/project",
  resume: %ResumeToken{...},    # For session continuation
  queue_mode: :collect,         # :collect | :followup | :steer | :steer_backlog | :interrupt
  lane: :main,                  # :main | :subagent | :background_exec
  tool_policy: %{},
  meta: %{
    origin: :telegram,          # Source transport atom
    agent_id: "default",
    notify_pid: pid,            # Process to send {:lemon_gateway_run_completed, job, completed}
    progress_msg_id: 123,       # For cancel-by-progress-msg
    disable_auto_resume: false, # Opt out of auto-resume
    model: "...",               # Engine-specific model override
    system_prompt: "...",       # Engine-specific system prompt override
  }
}
```

**Completion notification**: Set `meta.notify_pid` to receive `{:lemon_gateway_run_completed, %Job{}, %Event.Completed{}}` when a run finishes.

### Event.Completed

```elixir
%LemonGateway.Event.Completed{
  engine: "lemon",
  ok: true | false,
  answer: "final answer text",
  error: nil | reason,
  resume: %ResumeToken{} | nil,
  usage: %{} | nil,
  run_id: "run_uuid",
  session_key: "..."
}
```

## Transport Architecture

### Adding a New Transport

1. **Create transport module** at `lib/lemon_gateway/transports/my_transport.ex`:

```elixir
defmodule LemonGateway.Transports.MyTransport do
  use GenServer
  use LemonGateway.Transport

  require Logger
  alias LemonGateway.{BindingResolver, Runtime}
  alias LemonGateway.Types.{ChatScope, Job}

  @impl LemonGateway.Transport
  def id, do: "mytransport"

  @impl LemonGateway.Transport
  def start_link(opts) do
    if enabled?() do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    else
      Logger.info("mytransport disabled")
      :ignore
    end
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  # Handle incoming messages from external service
  def handle_info({:incoming_message, data}, state) do
    scope = %ChatScope{transport: :mytransport, chat_id: data.chat_id, topic_id: nil}

    job = %Job{
      session_key: build_session_key(data),
      prompt: data.text,
      engine_id: BindingResolver.resolve_engine(scope, nil, nil),
      cwd: BindingResolver.resolve_cwd(scope),
      queue_mode: :collect,
      meta: %{
        origin: :mytransport,
        notify_pid: self()
      }
    }

    Runtime.submit(job)
    {:noreply, state}
  end

  # Handle run completion via notify_pid
  def handle_info({:lemon_gateway_run_completed, %Job{} = job, completed}, state) do
    text = if completed.ok, do: completed.answer, else: "Error: #{inspect(completed.error)}"
    send_to_external_service(job.meta[:chat_id], text)
    {:noreply, state}
  end

  defp enabled?, do: LemonGateway.Config.get(:enable_mytransport) == true

  defp build_session_key(data), do: "mytransport:#{data.chat_id}:#{data.user_id}"
end
```

2. **Register in supervision** (if not auto-discovered via `TransportRegistry`).

### Transport Best Practices

- Use `LemonGateway.Runtime.submit/1` to enqueue jobs (never call Scheduler directly)
- Set `meta.notify_pid: self()` to receive completion notifications as `{:lemon_gateway_run_completed, job, completed}`
- Build a stable, unique `session_key` (transport + chat + user + project)
- Return `:ignore` from `start_link/1` if transport is disabled
- Use `BindingResolver.resolve_engine/3` and `BindingResolver.resolve_cwd/1` to respect config bindings
- Users can select engines inline with `/claude text` or `/codex text` (handled by `EngineDirective.strip/1`)

## Engine System

### Engine Types

**Native Engine (Lemon)**:
- In-process Elixir execution via `CodingAgent.CliRunners.LemonRunner`
- No subprocess spawning
- Full tool support with approval context
- Supports steering (mid-run message injection)

**CLI Engines (Codex, Claude, OpenCode, Pi)**:
- Wrap external CLI tools via subprocess
- Use `LemonGateway.Engines.CliAdapter` for common logic
- Resume tokens parsed from CLI output
- Limited steering support (engine-dependent)

**Echo Engine**:
- In-process test/debug engine; echoes prompt back immediately
- No external calls; useful for integration testing

### Engine ID Resolution

Engine IDs can be composite: `"claude:claude-3-opus"` falls back to `"claude"` engine. Priority for engine selection:

1. Resume token engine (from `ChatState` auto-resume)
2. Inline directive (`/claude`, `/codex`, etc.)
3. Topic-level binding `default_engine`
4. Chat-level binding `default_engine`
5. Project `default_engine`
6. Global `default_engine` from config (default: `"lemon"`)

### Adding an Engine

```elixir
defmodule LemonGateway.Engines.MyEngine do
  @behaviour LemonGateway.Engine

  alias LemonGateway.Engines.CliAdapter
  alias LemonGateway.Types.ResumeToken

  @impl true
  def id, do: "myengine"

  @impl true
  def format_resume(%ResumeToken{value: v}), do: "myengine --resume #{v}"

  @impl true
  def extract_resume(text) do
    case Regex.run(~r/myengine --resume (\S+)/, text) do
      [_, value] -> %ResumeToken{engine: id(), value: value}
      _ -> nil
    end
  end

  @impl true
  def is_resume_line(line), do: String.contains?(line, "myengine --resume")

  @impl true
  def start_run(job, opts, sink_pid) do
    CliAdapter.start_run(MyCliRunner, id(), job, opts, sink_pid)
  end

  @impl true
  def cancel(ctx), do: CliAdapter.cancel(ctx)

  @impl true
  def supports_steer?, do: false

  @impl true
  def steer(_ctx, _text), do: {:error, :not_supported}
end
```

Register in `LemonGateway.EngineRegistry` initialization.

### Engine Event Protocol

Engines send events to `sink_pid` (the `Run` process):

```elixir
# Run started
{:engine_event, run_ref, %Event.Started{engine: "lemon", resume: token}}

# Action event (tool use)
{:engine_event, run_ref, %Event.ActionEvent{action: action, phase: :start}}

# Streaming text delta
{:engine_delta, run_ref, "partial text"}

# Run completed
{:engine_event, run_ref, %Event.Completed{ok: true, answer: "...", resume: token}}
```

The `Run` process re-emits these to `LemonCore.Bus` as plain maps.

## Thread Worker and Scheduling

### Queue Modes

| Mode | Behavior |
|------|----------|
| `:collect` | Append to queue; consecutive collects are coalesced into one job |
| `:followup` | Append with debounce merging (500ms window); auto-promoted to `:steer_backlog` if run is active and `meta.task_auto_followup` is set |
| `:steer` | Inject into active run; fallback to `:followup` if rejected |
| `:steer_backlog` | Inject into active run; fallback to `:collect` if rejected |
| `:interrupt` | Cancel current run, insert at front of queue |

### Scheduling Flow

1. Transport calls `Runtime.submit(job)`
2. Scheduler applies auto-resume from `ChatState` (if enabled and engine matches)
3. Scheduler routes to `ThreadWorker` by `thread_key` (`session_key` takes priority over resume token)
4. `ThreadWorker` enqueues job based on `queue_mode`
5. Worker requests slot from Scheduler when ready to run
6. On slot grant, worker starts `Run` via `RunSupervisor`
7. Run acquires `EngineLock`, starts engine, emits bus events, notifies `notify_pid` on completion
8. Slot released; `ThreadWorker` exits when queue empty and no run active

### Configuration

```toml
# In .lemon/config.toml
[gateway]
max_concurrent_runs = 2    # Default: 2
auto_resume = true
followup_debounce_ms = 500
require_engine_lock = true
engine_lock_timeout_ms = 60000

[gateway.queue]
cap = 100        # Max jobs per queue (0 = unlimited)
drop = "oldest"  # "oldest" or "newest" when cap reached

[gateway.bindings]
# [[gateway.bindings]] entries map transport/chat to project/engine
```

## Binding System

Bindings map `transport + chat_id + topic_id` to a project, agent, and engine:

```toml
[[gateway.bindings]]
transport = "telegram"
chat_id = 123456789
project = "myproject"
agent_id = "coder"
default_engine = "claude"
queue_mode = "collect"
```

`BindingResolver` functions:
- `resolve_binding(scope)` - most specific matching binding
- `resolve_engine(scope, engine_hint, resume)` - engine with priority cascade
- `resolve_cwd(scope)` - project root from binding
- `resolve_agent_id(scope)` - agent id (default: `"default"`)
- `resolve_queue_mode(scope)` - queue_mode from binding

## Command System

Slash commands are handled before job submission. Register by adding a module to `:commands` in app config:

```elixir
defmodule LemonGateway.Commands.MyCmd do
  use LemonGateway.Command

  @impl true
  def name, do: "mycmd"

  @impl true
  def description, do: "Does something useful"

  @impl true
  def handle(scope, args, context) do
    {:reply, "Result: #{args}"}
  end
end
```

Return values: `:ok` (no reply), `{:reply, text}`, `{:error, reason}`.

Reserved names: `help`, `start`, `stop`.

## SMS Inbox Functionality

### Tools Available (injected into Lemon engine)

- `sms_get_inbox_number` - Get the Twilio phone number
- `sms_wait_for_code` - Wait for SMS containing a verification code
- `sms_list_messages` - List recent SMS messages
- `sms_claim_message` - Mark a message as claimed by a session

### How It Works

1. Twilio sends webhook to `Sms.WebhookServer` when SMS received
2. `Sms.Inbox` stores message with extracted codes (4-8 digit sequences)
3. AI tools can call `sms_wait_for_code` which blocks until matching SMS arrives
4. Messages can be "claimed" to prevent cross-session conflicts

### Configuration

```toml
[gateway.sms]
inbox_number = "+1234567890"
webhook_path = "/webhooks/sms"
webhook_port = 4045
# Twilio credentials from env: TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN
```

## Voice Call Flow

```
User Call → Twilio → Webhook → CallSession GenServer
                                    │
                                    ▼
Twilio ← mulaw 8kHz ────── WebSocket Handler
                                    │
                                    ▼
Deepgram ← raw audio ───── WebSocket (STT)
                                    │
                                    ▼
                              Transcript Text
                                    │
                                    ▼
                              LLM (generate response)
                                    │
                                    ▼
ElevenLabs API ← text ──── TTS Request
                                    │
                                    ▼
Twilio ← audio ─────────── Synthesized speech
```

### Configuration

```toml
[gateway.voice]
enabled = true
websocket_port = 4047
twilio_phone_number = "+1234567890"
elevenlabs_output_format = "ulaw_8000"
# API keys from env: DEEPGRAM_API_KEY, ELEVENLABS_API_KEY
```

### ElevenLabs response normalization

`CallSession.convert_pcm_to_mulaw/1` now normalizes the ElevenLabs response to a binary before running `AudioConversion.mp3_data?/1` or `pcm16_to_mulaw/1`. This prevents `FunctionClauseError` when `:httpc` streams come back as iodata (lists) and the incoming MP3 payload starts with an `ID3` tag. Detection was also extended to recognize the `ID3` header so the warning log triggers earlier when non-PCM audio is returned. Refer to `apps/lemon_gateway/lib/lemon_gateway/voice/call_session.ex:403-428` and `apps/lemon_gateway/lib/lemon_gateway/voice/audio_conversion.ex` for the implementation.

For production Twilio calls, keep `elevenlabs_output_format` set to `ulaw_8000` so audio is already G.711 mu-law and can be sent directly without PCM conversion.

### Twilio stream metadata and session lifecycle

`WebhookRouter` now includes `CallSid`, `From`, and `To` as query params on the `<Stream>` URL so `TwilioWebSocket.init/1` receives stable metadata instead of synthetic/unknown values. Inbound media frames are routed through `CallSession.handle_audio/2`, which updates `last_activity_at` and forwards audio to Deepgram via the registered WS process. `CallSession` is configured with `restart: :temporary` to avoid restart loops after normal call termination under `LemonGateway.Voice.CallSessionSupervisor`.

If stream metadata is missing on websocket connect, `WebhookRouter` now generates a unique temporary call SID (`temp_*`) instead of using `"unknown"` so registry keys do not collide across calls. `TwilioWebSocket.init/1` also handles `{:error, {:already_started, pid}}` for both CallSession and Deepgram children by reusing the existing process rather than crashing the connection.

`LemonGateway.AI` now resolves provider API keys from environment variables, app config, and Lemon secrets (both lowercase and uppercase key names such as `openai_api_key` and `OPENAI_API_KEY`) so voice LLM calls can succeed when credentials are stored in secrets.

## Common Tasks

### Submit a Job

```elixir
alias LemonGateway.Types.{ChatScope, Job}
alias LemonGateway.{BindingResolver, Runtime}

scope = %ChatScope{transport: :telegram, chat_id: 123456, topic_id: nil}

job = %Job{
  session_key: "telegram:123456:789",
  prompt: "Hello, world!",
  engine_id: BindingResolver.resolve_engine(scope, nil, nil),
  cwd: BindingResolver.resolve_cwd(scope),
  queue_mode: :collect,
  meta: %{
    origin: :telegram,
    agent_id: "coder",
    notify_pid: self()
  }
}

Runtime.submit(job)

# Then wait for:
receive do
  {:lemon_gateway_run_completed, ^job, completed} ->
    IO.puts("Answer: #{completed.answer}")
end
```

### Cancel a Run

```elixir
# By run ID (registered in LemonGateway.RunRegistry)
LemonGateway.Runtime.cancel_by_run_id("run-uuid", :user_requested)

# By progress message (for UI cancel buttons)
LemonGateway.Runtime.cancel_by_progress_msg(scope, progress_msg_id)
```

### Inspect Scheduler State

```elixir
# Attach to running node first
iex --sname debug --cookie lemon_cookie --remsh lemon_gateway@hostname

# Check scheduler (in_flight, waitq, max slots)
:sys.get_state(LemonGateway.Scheduler)

# Check engine locks
:sys.get_state(LemonGateway.EngineLock)

# List thread workers
DynamicSupervisor.which_children(LemonGateway.ThreadWorkerSupervisor)

# Get run history for session
LemonGateway.Store.get_run_history("session_key", limit: 10)

# Check if a run is active
Registry.lookup(LemonGateway.RunRegistry, "run_uuid")
```

### Add Gateway-Specific Tools

Gateway tools are injected into Lemon engine runs via `CliAdapter.gateway_extra_tools/3`. Only the Lemon engine receives extra tools; CLI engines do not.

```elixir
# In lib/lemon_gateway/tools/my_tool.ex
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
          "param" => %{"type" => "string", "description" => "Parameter"}
        },
        "required" => ["param"]
      },
      execute: fn _id, params, _signal, _on_update ->
        %AgentToolResult{
          content: [%TextContent{text: "result"}],
          details: %{param: params["param"]}
        }
      end
    }
  end
end

# Register in CliAdapter.gateway_extra_tools/3 (lemon engine only):
defp gateway_extra_tools("lemon", job, opts) do
  [LemonGateway.Tools.MyTool.tool(job.cwd) | existing_tools()]
end
```

## Testing and Debugging

### Unit Tests

```bash
# Run all gateway tests
mix test apps/lemon_gateway

# Run specific test file
mix test apps/lemon_gateway/test/scheduler_test.exs
```

### Debug with Telethon (Telegram)

See skill: `.claude/skills/telegram-gateway-debug-loop/SKILL.md`

Quick debug session:

```bash
# Terminal 1: Start gateway with debug logging
LOG_LEVEL=debug ./bin/lemon-gateway --debug --sname lemon_gateway_debug

# Terminal 2: Attach to BEAM
iex --sname lemon_attach --cookie lemon_gateway_dev_cookie \
  --remsh lemon_gateway_debug@$(hostname -s)

# In IEx: Inspect runtime state
:sys.get_state(LemonGateway.Scheduler)
:sys.get_state(LemonGateway.EngineLock)
DynamicSupervisor.which_children(LemonGateway.ThreadWorkerSupervisor)
```

### Common Issues

**Stuck runs**:
- Check `:sys.get_state(LemonGateway.Scheduler)` for `in_flight` vs `waitq` sizes
- Check `:sys.get_state(LemonGateway.EngineLock)` for stale locks
- Stale slot requests are automatically cleaned up after 30s

**Transport not starting**:
- Check `LemonGateway.TransportRegistry.enabled_transports()`
- Verify config flag: `LemonGateway.Config.get(:enable_discord)`
- Check logs for "disabled" or "failed to start" messages

**SMS webhook not receiving**:
- Verify `Sms.WebhookServer` is running: `Process.whereis(LemonGateway.Sms.WebhookServer)`
- Check Twilio webhook URL is configured correctly
- Validate webhook signature in `Sms.TwilioSignature`

**XMTP health check failing**:
- XMTP transport is handled by `lemon_channels`, not gateway
- Check health via `LemonGateway.Transports.Xmtp.status()`

**Context overflow**:
- Run automatically clears `ChatState` on context-length errors
- Next run will start fresh without a resume token

## Introspection Events

ThreadWorker and Scheduler emit introspection events via `LemonCore.Introspection.record/3` for lifecycle observability. All events use `engine: "lemon"` and pass `run_id:`, `session_key:` where available.

### ThreadWorker Events

| Event Type | When Emitted | Key Payload Fields |
|---|---|---|
| `:thread_started` | `init/1` | `thread_key` |
| `:thread_message_dispatched` | `handle_cast({:enqueue, job})` | `thread_key`, `queue_mode`, `queue_len` |
| `:thread_terminated` | `terminate/2` | `thread_key`, `queue_len` |

### Scheduler Events

| Event Type | When Emitted | Key Payload Fields |
|---|---|---|
| `:scheduled_job_triggered` | `handle_cast({:submit, job})` | `queue_mode`, `engine_id`, `thread_key` |
| `:scheduled_job_completed` | `handle_cast({:release_slot, slot_ref})` | `in_flight`, `max` |

## Dependencies

### Umbrella Apps
- `agent_core` - CLI runner infrastructure, tool types (`AgentTool`, `AgentToolResult`)
- `coding_agent` - Native Lemon AI engine (`CodingAgent.CliRunners.LemonRunner`)
- `lemon_channels` - Telegram transport (primary), XMTP adapter
- `lemon_core` - Shared primitives, storage (`LemonCore.Store`), bus (`LemonCore.Bus`), telemetry

### External Libraries
- `gen_smtp` / `mail` - Email handling
- `plug` / `bandit` - HTTP servers (SMS webhooks port 4045, Voice port 4047, Health port 4042)
- `earmark_parser` - Markdown parsing for Telegram entity rendering
- `websockex` / `websock_adapter` - WebSocket clients (Deepgram STT, Twilio Media Streams)
- `jason` - JSON encoding/decoding
- `toml` - Configuration parsing
- `uuid` - UUID generation for run IDs
