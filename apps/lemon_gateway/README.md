# LemonGateway

A multi-engine AI gateway for Elixir. Routes user requests through transports (Telegram, etc.) to AI engines (Lemon/Codex/Claude, etc.) with concurrency control, thread isolation, and session resumption.

## Architecture

```
                              +------------------+
                              |    Transport     |
                              | (Telegram, etc.) |
                              +--------+---------+
                                       |
                                       | Job
                                       v
                              +------------------+
                              |    Scheduler     |
                              |  (slot control)  |
                              +--------+---------+
                                       |
                                       | slot_granted
                                       v
                              +------------------+
                              |  ThreadWorker    |
                              | (per-thread Q)   |
                              +--------+---------+
                                       |
                                       | start_run
                                       v
                              +------------------+
                              |       Run        |
                              | (engine adapter) |
                              +--------+---------+
                                       |
                                       | Engine.start_run
                                       v
                              +------------------+
                              |      Engine      |
                              | (claude, codex)  |
                              +------------------+
```

**Flow:**
1. **Transport** receives user input (e.g., Telegram message), creates a `Job`, submits to Scheduler
2. **Scheduler** enforces concurrency limits via slot allocation
3. **ThreadWorker** manages per-thread job queue, one active run at a time per thread
4. **Run** selects the appropriate engine, starts the AI run, streams events back
5. **Engine** executes the actual AI request (CLI subprocess, API call, etc.)

## Configuration

LemonGateway loads configuration from `~/.lemon/config.toml` (the `[gateway]` section) by default (see `LemonGateway.ConfigLoader`).

### TOML (recommended)

Create `~/.lemon/config.toml`:

```toml
[gateway]
max_concurrent_runs = 2
default_engine = "lemon"
enable_telegram = false
require_engine_lock = true

[gateway.queue]
mode = "followup"
cap = 50
drop = "oldest"

[gateway.telegram]
bot_token = "your-telegram-bot-token"
allowed_chat_ids = [123456789, -100123456789]
poll_interval_ms = 1000
edit_throttle_ms = 1000

[gateway.projects.lemon]
root = "/path/to/lemon"
default_engine = "lemon"

[[gateway.bindings]]
transport = "telegram"
chat_id = 123456789
agent_id = "default"
project = "lemon"
default_engine = "claude"
queue_mode = "steer"

[gateway.engines.lemon]
enabled = true

[gateway.engines.codex]
enabled = true
cli_path = "/usr/local/bin/codex"

[gateway.engines.claude]
enabled = true
cli_path = "/usr/local/bin/claude"
```

### Configuration Options

| Key | Default | Description |
|-----|---------|-------------|
| `max_concurrent_runs` | `2` | Maximum concurrent AI runs across all threads |
| `default_engine` | `"lemon"` | Engine to use when no engine hint or resume token present |
| `enable_telegram` | `false` | Enable Telegram transport |

### Telegram Options

| Key | Default | Description |
|-----|---------|-------------|
| `bot_token` | required | Telegram Bot API token |
| `allowed_chat_ids` | `nil` | List of allowed chat IDs, `nil` allows all |
| `poll_interval_ms` | `1000` | Polling interval for updates |
| `edit_throttle_ms` | `1000` | Edit throttle window for Telegram updates |

## Available Engines

| Engine ID | Module | Description |
|-----------|--------|-------------|
| `lemon` | `LemonGateway.Engines.Lemon` | Native CodingAgent engine |
| `codex` | `LemonGateway.Engines.Codex` | OpenAI Codex via CLI adapter |
| `claude` | `LemonGateway.Engines.Claude` | Claude Code via CLI adapter |
| `echo` | `LemonGateway.Engines.Echo` | Echo engine for testing |

## Adding a New Engine

Implement the `LemonGateway.Engine` behaviour:

```elixir
defmodule MyApp.Engines.Custom do
  @behaviour LemonGateway.Engine

  alias LemonGateway.Types.{Job, ResumeToken}
  alias LemonGateway.Event

  @impl true
  def id, do: "custom"

  @impl true
  def format_resume(%ResumeToken{value: v}), do: "custom resume #{v}"

  @impl true
  def extract_resume(text) do
    case Regex.run(~r/custom\s+resume\s+([\w-]+)/i, text) do
      [_, value] -> %ResumeToken{engine: id(), value: value}
      _ -> nil
    end
  end

  @impl true
  def is_resume_line(line) do
    Regex.match?(~r/^\s*`?custom\s+resume\s+[\w-]+`?\s*$/i, line)
  end

  @impl true
  def supports_steer?, do: false

  @impl true
  def start_run(%Job{} = job, opts, sink_pid) do
    run_ref = make_ref()
    resume = job.resume || %ResumeToken{engine: id(), value: generate_id()}

    # Start async work, send events to sink_pid:
    # - {:engine_event, run_ref, %Event.Started{...}}
    # - {:engine_event, run_ref, %Event.ActionEvent{...}}  (optional)
    # - {:engine_event, run_ref, %Event.Completed{...}}

    {:ok, run_ref, cancel_ctx}
  end

  @impl true
  def cancel(cancel_ctx), do: :ok
end
```

Register in config:

```elixir
config :lemon_gateway, :engines, [
  LemonGateway.Engines.Echo,
  MyApp.Engines.Custom
]
```

## Adding a New Transport

Transports are GenServers that receive external input and submit jobs:

```elixir
defmodule MyApp.Transports.Webhook do
  use GenServer

  alias LemonGateway.Types.{ChatScope, Job}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def handle_webhook(payload) do
    job = %Job{
      scope: %ChatScope{transport: :webhook, chat_id: payload.channel_id},
      text: payload.text,
      user_msg_id: payload.id,
      resume: nil,
      engine_hint: nil,
      meta: %{notify_pid: self()}
    }

    LemonGateway.submit(job)
  end
end
```

Add to supervision tree in `LemonGateway.TransportSupervisor`.

## Event Flow

Engines emit events to the Run process via `{:engine_event, run_ref, event}`:

| Event | Description |
|-------|-------------|
| `Event.Started` | Run began, includes resume token |
| `Event.ActionEvent` | Tool/action progress (shell command, file edit, etc.) |
| `Event.Completed` | Run finished with `ok: true/false`, `answer`, optional `error` |

The Run process:
1. Stores events via `LemonGateway.Store`
2. Passes events through a Renderer for formatting
3. Sends rendered output back through the transport

## Session Resumption

Each engine defines resume token format. Users can continue a session by including the resume token in their message:

```
lemon resume 12345
claude resume abc-def-123
```

The gateway extracts the token, routes to the correct engine, and continues the conversation thread.
