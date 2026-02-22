# LemonGateway AGENTS.md

Gateway and transport layer for the Lemon AI system. Handles all external messaging transports, AI engine management, and job scheduling.

## Purpose and Responsibilities

**LemonGateway** is the message gateway that:

1. **Transports**: Receives messages from Telegram, Discord, Email, SMS, Voice, Webhook, Farcaster, and XMTP
2. **Engines**: Manages AI execution via native Lemon, Claude, Codex, OpenCode, and Pi engines
3. **Scheduling**: Concurrent job execution with slot-based scheduling and per-session thread workers
4. **State Management**: Chat state persistence, auto-resume, and conversation locking
5. **SMS Utilities**: Inbox for receiving SMS codes (2FA, verification)
6. **Voice Calls**: Real-time phone calls via Twilio + Deepgram + ElevenLabs

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Transports                               │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐   │
│  │Telegram │ │Discord  │ │ Email   │ │  SMS    │ │  Voice  │   │
│  │(lemon_  │ │(nostrum)│ │(SMTP/  │ │(Twilio) │ │(Twilio/ │   │
│  │channels)│ │         │ │ webhook)│ │         │ │Deepgram)│   │
│  └────┬────┘ └────┬────┘ └────┬────┘ └────┬────┘ └────┬────┘   │
│       └─────────────┴─────────┴─────────┴─────────┘            │
│                              │                                  │
│                       Runtime.submit/1                          │
│                              │                                  │
├──────────────────────────────┼──────────────────────────────────┤
│                        Scheduler                              │
│  ┌───────────────────────────┼──────────────────────────────┐  │
│  │                    Slot Manager                          │  │
│  │              (max_concurrent_runs)                       │  │
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
│  │  Lemon  │ │  Codex  │ │ Claude  │ │OpenCode │ │   Pi    │  │
│  │ (native)│ │(CLI)    │ │(CLI)    │ │(CLI)    │ │(CLI)    │  │
│  └─────────┘ └─────────┘ └─────────┘ └─────────┘ └─────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

## Key Modules

### Core

| Module | Purpose |
|--------|---------|
| `LemonGateway.Application` | OTP supervision tree startup |
| `LemonGateway.Runtime` | Public API: `submit/1`, `cancel_by_run_id/2` |
| `LemonGateway.Config` | TOML-backed runtime configuration |
| `LemonGateway.Store` | Gateway storage API (delegates to LemonCore.Store) |
| `LemonGateway.ChatState` | Session state struct for auto-resume |

### Transport Layer

| Module | Purpose |
|--------|---------|
| `LemonGateway.Transport` | Behaviour for transport plugins |
| `LemonGateway.TransportRegistry` | Transport registration and lookup |
| `LemonGateway.TransportSupervisor` | Dynamic supervisor for transports |
| `LemonGateway.Transports.Discord` | Discord bot via Nostrum |
| `LemonGateway.Transports.Email` | Email inbound/outbound |
| `LemonGateway.Transports.Voice` | Voice call transport |
| `LemonGateway.Transports.Webhook` | Generic webhook receiver |
| `LemonGateway.Transports.Farcaster` | Farcaster integration |
| `LemonGateway.Transports.XMTP` | XMTP messaging protocol |

### Engine Layer

| Module | Purpose |
|--------|---------|
| `LemonGateway.Engine` | Behaviour for AI engines |
| `LemonGateway.EngineRegistry` | Engine registration |
| `LemonGateway.EngineLock` | Per-session mutex for engine runs |
| `LemonGateway.Engines.Lemon` | Native Elixir engine (CodingAgent) |
| `LemonGateway.Engines.Codex` | OpenAI Codex CLI wrapper |
| `LemonGateway.Engines.Claude` | Claude CLI wrapper |
| `LemonGateway.Engines.OpenCode` | OpenCode CLI wrapper |
| `LemonGateway.Engines.Pi` | Pi CLI wrapper |
| `LemonGateway.Engines.CliAdapter` | Shared CLI subprocess runner |

### Scheduling

| Module | Purpose |
|--------|---------|
| `LemonGateway.Scheduler` | Slot-based concurrency limiter |
| `LemonGateway.ThreadWorker` | Per-session job queue worker |
| `LemonGateway.ThreadRegistry` | Registry for thread workers |
| `LemonGateway.ThreadWorkerSupervisor` | Dynamic supervisor for workers |
| `LemonGateway.RunSupervisor` | Supervisor for individual runs |
| `LemonGateway.Run` | Individual run process |

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
| `LemonGateway.Types.ChatScope` | Transport-specific chat ID |
| `LemonGateway.Types.ResumeToken` | Session resume token |

## Transport Architecture

### Adding a New Transport

1. **Create transport module** at `lib/lemon_gateway/transports/my_transport.ex`:

```elixir
defmodule LemonGateway.Transports.MyTransport do
  use GenServer
  use LemonGateway.Transport
  
  require Logger
  alias LemonGateway.{BindingResolver, Runtime, Store}
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
    # Initialize connection to external service
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
      meta: %{origin: :mytransport, reply: build_reply_fn(data)}
    }
    
    Runtime.submit(job)
    {:noreply, state}
  end
  
  # Handle run completion and send response
  def handle_info({:lemon_gateway_run_completed, %Job{} = job, completed}, state) do
    reply_fun = get_in(job.meta || %{}, [:reply])
    if is_function(reply_fun, 1) do
      reply_fun.(completed)
    end
    {:noreply, state}
  end
  
  defp enabled? do
    LemonGateway.Config.get(:enable_mytransport) == true
  end
  
  defp build_session_key(data) do
    "mytransport:#{data.chat_id}:#{data.user_id}"
  end
  
  defp build_reply_fn(data) do
    fn completed ->
      text = if completed.ok, do: completed.answer, else: "Error: #{completed.error}"
      send_to_external_service(data.chat_id, text)
    end
  end
end
```

2. **Register in config** (if not auto-discovered):

```elixir
# In config/config.exs or runtime config
config :lemon_gateway, :transports, [
  LemonGateway.Transports.MyTransport
]
```

3. **Add enable flag** in `LemonGateway.TransportRegistry`:

```elixir
# In transport_enabled?/1 defp
defp transport_enabled?("mytransport") do
  LemonGateway.Config.get(:enable_mytransport) == true
end
```

### Transport Best Practices

- Use `LemonGateway.Runtime.submit/1` to enqueue jobs (never call Scheduler directly)
- Store reply functions in `job.meta[:reply]` for async response delivery
- Build unique `session_key` that includes transport, chat, user, and project
- Handle `{:lemon_gateway_run_completed, job, completed}` for responses
- Return `:ignore` from `start_link/1` if transport is disabled

## Engine System

### Engine Types

**Native Engine (Lemon)**:
- In-process Elixir execution via `CodingAgent`
- No subprocess spawning
- Full tool support with approval context
- Supports steering (mid-run message injection)

**CLI Engines (Codex, Claude, OpenCode, Pi)**:
- Wrap external CLI tools via subprocess
- Use `LemonGateway.Engines.CliAdapter` for common logic
- Resume tokens parsed from CLI output
- Limited steering support (engine-dependent)

### Adding an Engine

1. **Create engine module**:

```elixir
defmodule LemonGateway.Engines.MyEngine do
  @behaviour LemonGateway.Engine
  
  alias LemonGateway.Engines.CliAdapter
  alias LemonGateway.Types.ResumeToken
  
  @impl true
  def id, do: "myengine"
  
  @impl true
  def format_resume(%ResumeToken{} = token) do
    "myengine --resume #{token.value}"
  end
  
  @impl true
  def extract_resume(text) do
    # Parse resume token from text
    case Regex.run(~r/myengine --resume (\S+)/, text) do
      [_, value] -> %ResumeToken{engine: id(), value: value}
      _ -> nil
    end
  end
  
  @impl true
  def is_resume_line(line) do
    String.contains?(line, "myengine --resume")
  end
  
  @impl true
  def start_run(job, opts, sink_pid) do
    CliAdapter.start_run(
      MyCliRunner,  # AgentCore.CliRunners module
      id(),
      job,
      opts,
      sink_pid
    )
  end
  
  @impl true
  def cancel(ctx), do: CliAdapter.cancel(ctx)
  
  @impl true
  def supports_steer?, do: false
  
  @impl true
  def steer(_ctx, _text), do: {:error, :not_supported}
end
```

2. **Register in `LemonGateway.EngineRegistry`** initialization

### Engine Event Protocol

Engines send events to `sink_pid`:

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

## Thread Worker and Scheduling

### Queue Modes

| Mode | Behavior |
|------|----------|
| `:collect` | Append to queue, coalesce consecutive collects |
| `:followup` | Append with debounce merging (500ms window) |
| `:steer` | Inject into active run; fallback to `:followup` if rejected |
| `:steer_backlog` | Inject into active run; fallback to `:collect` if rejected |
| `:interrupt` | Cancel current run, insert at front of queue |

### Scheduling Flow

1. Transport calls `Runtime.submit(job)`
2. Scheduler applies auto-resume from `ChatState`
3. Scheduler routes to `ThreadWorker` by `thread_key` (session_key first, then resume token)
4. `ThreadWorker` enqueues job based on `queue_mode`
5. Worker requests slot from Scheduler when ready to run
6. On slot grant, worker starts `Run` process via `RunSupervisor`
7. Run completion triggers reply callback

### Configuration

```elixir
# In .lemon/config.toml
[gateway]
max_concurrent_runs = 10
auto_resume = true
followup_debounce_ms = 500

[gateway.queue]
cap = 100        # Max jobs per queue
drop = :oldest   # :oldest or :newest when cap reached
```

## SMS Inbox Functionality

The SMS inbox provides tools for receiving SMS messages (useful for 2FA codes):

### Tools Available

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

### Key Components

- `Voice.CallSession` - State machine for active call
- `Voice.TwilioWebSocket` - Handles Twilio Media Streams
- `Voice.DeepgramClient` - Real-time speech-to-text
- `Voice.WebhookRouter` - Routes Twilio webhooks

### Configuration

```toml
[gateway.voice]
enabled = true
websocket_port = 4047
twilio_phone_number = "+1234567890"
# API keys from env: DEEPGRAM_API_KEY, ELEVENLABS_API_KEY
```

## Common Tasks

### Submit a Job

```elixir
alias LemonGateway.Types.{ChatScope, Job}

scope = %ChatScope{transport: :telegram, chat_id: 123456, topic_id: nil}

job = %Job{
  session_key: "telegram:123456:789",
  prompt: "Hello, world!",
  engine_id: "lemon",
  cwd: "/path/to/project",
  queue_mode: :collect,
  meta: %{
    origin: :telegram,
    agent_id: "coder",
    reply: fn completed -> 
      IO.puts("Answer: #{completed.answer}")
    end
  }
}

LemonGateway.Runtime.submit(job)
```

### Cancel a Run

```elixir
# By run ID
LemonGateway.Runtime.cancel_by_run_id("run-uuid", :user_requested)

# By progress message (for UI cancel buttons)
LemonGateway.Runtime.cancel_by_progress_msg(scope, progress_msg_id)
```

### Inspect Scheduler State

```elixir
# Attach to running node first
iex --sname debug --cookie lemon_cookie --remsh lemon_gateway@hostname

# Check scheduler
:sys.get_state(LemonGateway.Scheduler)

# Check engine locks
:sys.get_state(LemonGateway.EngineLock)

# List thread workers
DynamicSupervisor.which_children(LemonGateway.ThreadWorkerSupervisor)

# Get run history for session
LemonGateway.Store.get_run_history("session_key", limit: 10)
```

### Add Gateway-Specific Tools

Gateway tools are injected into the Lemon engine via `CliAdapter.gateway_extra_tools/3`:

```elixir
# In lib/lemon_gateway/tools/my_tool.ex
defmodule LemonGateway.Tools.MyTool do
  def tool(cwd, opts \\ []) do
    %{
      name: "my_tool",
      description: "Does something useful",
      parameters: %{
        type: "object",
        properties: %{
          param: %{type: "string", description: "Parameter description"}
        },
        required: ["param"]
      },
      handler: fn args ->
        # Execute tool logic
        {:ok, %{result: "success"}}
      end
    }
  end
end

# Register in CliAdapter.gateway_extra_tools/3
defp gateway_extra_tools("lemon", job, opts) do
  cwd = job.cwd || Map.get(opts, :cwd) || File.cwd!()
  [
    LemonGateway.Tools.Cron.tool(cwd, ...),
    LemonGateway.Tools.MyTool.tool(cwd, ...)
    | sms_tools()
  ]
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
- Check `:sys.get_state(LemonGateway.Scheduler)` for in_flight vs waitq
- Check `:sys.get_state(LemonGateway.EngineLock)` for stale locks
- Verify `ThreadWorker` processes are alive

**Transport not starting**:
- Check `LemonGateway.TransportRegistry.enabled_transports()`
- Verify config flag: `LemonGateway.Config.get(:enable_discord)`
- Check logs for "disabled" or "failed to start" messages

**SMS webhook not receiving**:
- Verify `Sms.WebhookServer` is running: `Process.whereis(LemonGateway.Sms.WebhookServer)`
- Check Twilio webhook URL is configured correctly
- Validate webhook signature in `Sms.TwilioSignature`

## Dependencies

### Umbrella Apps
- `agent_core` - CLI runner infrastructure
- `coding_agent` - Native Lemon AI engine
- `lemon_channels` - Telegram transport (primary)
- `lemon_core` - Shared primitives and storage

### External Libraries
- `nostrum` - Discord bot framework
- `gen_smtp` / `mail` - Email handling
- `plug` / `bandit` - HTTP servers (SMS, Voice, Webhooks)
- `earmark_parser` - Markdown parsing
- `websockex` / `websock_adapter` - WebSocket clients
- `jason` - JSON encoding/decoding
- `toml` - Configuration parsing
- `uuid` - UUID generation
