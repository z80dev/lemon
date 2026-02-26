# LemonChannels AGENTS.md

Channel adapter application for external messaging platforms (Telegram, Discord, X/Twitter, XMTP).

## Purpose and Responsibilities

LemonChannels provides:

- **Channel Plugin System**: Pluggable adapters for messaging platforms
- **Outbox Queue**: Reliable outbound message delivery with retry and per-group ordering
- **Message Processing**: Chunking, deduplication, rate limiting
- **Inbound Normalization**: Converts raw channel data to `LemonCore.InboundMessage`

## Architecture Overview

```
[Router] → [Outbox] → [Plugin] → [External Channel]
              ↓
         [Chunker/Dedupe/RateLimiter]
```

The Outbox preserves delivery ordering per "delivery group" (channel + account + peer + thread),
while allowing concurrency across independent groups. Chunked messages from the same payload
share a group and are never delivered concurrently to prevent reordering.

## Adapter Architecture

### Plugin Behaviour

All channel adapters implement `LemonChannels.Plugin`:

```elixir
defmodule MyAdapter do
  @behaviour LemonChannels.Plugin

  @impl true
  def id, do: "my_adapter"

  @impl true
  def meta do
    %{
      label: "My Adapter",
      capabilities: %{
        chunk_limit: 4096,
        rate_limit: 30,
        edit_support: true,
        delete_support: false,
        voice_support: false,
        image_support: false,
        file_support: false,
        reaction_support: false,
        thread_support: false
      },
      docs: "https://example.com/docs"
    }
  end

  @impl true
  def child_spec(opts) do
    %{id: __MODULE__, start: {MyAdapter.Supervisor, :start_link, [opts]}, type: :supervisor}
  end

  @impl true
  def normalize_inbound(raw), do: {:ok, %LemonCore.InboundMessage{...}}

  @impl true
  def deliver(payload), do: {:ok, delivery_ref}

  @impl true
  def gateway_methods, do: []
end
```

### Capability fields (all boolean unless noted)

Defined in `LemonChannels.Capabilities`:
- `edit_support`, `delete_support`, `voice_support`, `image_support`, `file_support`, `reaction_support`, `thread_support`
- `chunk_limit` (integer, max chars per message)
- `rate_limit` (integer or nil)

### Adding a New Channel Adapter

1. Create adapter module in `lib/lemon_channels/adapters/`
2. Implement `LemonChannels.Plugin` behaviour
3. Register in `LemonChannels.Application.register_and_start_adapters/0`
4. Add configuration key to `LemonChannels.GatewayConfig`

## Outbox System

Central queue for reliable outbound delivery at `lib/lemon_channels/outbox.ex`.

### Key Features

| Feature | Module | Purpose |
|---------|--------|---------|
| Chunking | `Outbox.Chunker` | Split long messages at sentence/word boundaries |
| Deduplication | `Outbox.Dedupe` | Prevent duplicate deliveries via idempotency keys (1h TTL) |
| Rate Limiting | `Outbox.RateLimiter` | Token bucket per channel/account (check + consume) |
| Retry | `Outbox` | Exponential backoff (1s, 2s, 4s); 3 max attempts by default |
| Ordering | `Outbox` | Per delivery-group FIFO; concurrent across independent groups |

Non-retryable errors: `:unknown_channel`, 4xx HTTP errors (except 429), worker exits.
429 responses parse `retry_after` from JSON `parameters.retry_after` or body text.

### Enqueue a Message

```elixir
alias LemonChannels.{OutboundPayload, Outbox}

payload = OutboundPayload.text(
  "telegram",
  "default",
  %{kind: :dm, id: "123456", thread_id: nil},
  "Hello, world!",
  idempotency_key: "msg-123"
)

{:ok, ref} = Outbox.enqueue(payload)
```

`OutboundPayload` kinds: `:text`, `:edit`, `:delete`, `:reaction`, `:file`, `:voice`.

For edits, use `OutboundPayload.edit/6`:
```elixir
OutboundPayload.edit("telegram", "default", peer, message_id, new_text)
```

Delivery acknowledgment: set `notify_pid` + `notify_ref` on the payload to receive
`{tag, ref, result}` when delivery completes or fails.

### Outbox Stats

```elixir
Outbox.stats()
# %{queue_length: 0, processing_count: 0, queue_depth: 0, max_queue_size: 5000, enqueued_total: 42}
```

## Telegram Adapter

Primary adapter. Module root: `LemonChannels.Adapters.Telegram` (plugin id: `"telegram"`).

### Supervisor Structure

```
adapters/telegram/supervisor.ex  — Supervisor
adapters/telegram/transport.ex   — Long-polling GenServer (getUpdates), inbound routing
adapters/telegram/inbound.ex     — Normalize Telegram updates → InboundMessage
adapters/telegram/outbound.ex    — Deliver via Bot API
adapters/telegram/voice_transcriber.ex — OpenAI-compatible audio transcription
```

The Telegram supervisor also starts `LemonChannels.Adapters.Telegram.AsyncSupervisor`
(`Task.Supervisor`) so transport-side network and cleanup side effects can run off the
main polling GenServer loop.

### Support Modules (lib/lemon_channels/telegram/)

| Module | Purpose |
|--------|---------|
| `Telegram.API` | Raw Bot API calls (send_message, edit_message_text, get_updates, etc.) |
| `Telegram.Delivery` | High-level enqueue helpers (enqueue_send, enqueue_edit) |
| `Telegram.Formatter` | Converts markdown to plain text + Telegram entities (avoids MarkdownV2) |
| `Telegram.Markdown` | Markdown AST renderer for Telegram entity format |
| `Telegram.Truncate` | Truncates messages to 4096 chars preserving resume lines |
| `Telegram.TriggerMode` | Per-chat/topic `:all` vs `:mentions` trigger mode (stored in ETS) |
| `Telegram.OffsetStore` | Persists getUpdates offset via LemonCore.Store |
| `Telegram.PollerLock` | Prevents duplicate pollers for the same account/token |
| `Telegram.TransportShared` | Shared dedupe helpers across transport modules |

`adapters/telegram/transport.ex` also indexes `:telegram_known_targets` for routing discovery, but throttles writes (30s cadence per target unless metadata changes) to avoid overloading `LemonCore.Store` during high-traffic chats.

### Key Capabilities

- `chunk_limit`: 4096
- `rate_limit`: 30 msg/sec
- Supports: edit, delete, voice, images, files, reactions, threads
- Transport-level Telegram commands: `/new`, `/resume`, `/model`, `/thinking`, `/trigger`, `/cwd`, `/file`, `/topic`, `/cancel`

### `/new` and Reply Index Behavior

- `/new` acknowledges immediately with `"Started a new session."` (plus model/provider/cwd details).
- Session abort, chat-state cleanup, and optional memory reflection are performed asynchronously in background tasks.
- Memory reflection runs use a dedicated reflection session key suffix (`:new_reflection`) and `queue_mode: :collect` so the main chat session is not blocked.
- `send_system_message/5` prefers `LemonChannels.Telegram.Delivery.enqueue_send/3` (Outbox path), with direct Bot API fallback if Outbox is unavailable.
- Reply/session indices are generation-scoped:
  - `:telegram_msg_session` keys: `{account_id, chat_id, thread_id, generation, msg_id}`
  - `:telegram_msg_resume` keys: `{account_id, chat_id, thread_id, generation, msg_id}`
- `/new` increments `:telegram_thread_generation` for `{account_id, chat_id, thread_id}` to invalidate stale reply mappings immediately without synchronous full-table scans.

### `/model` Picker Behavior

- `/model` uses a reply keyboard (bottom keyboard) flow for per-user selection in a chat/topic: provider -> model -> scope (`This session` or `All future sessions`).
- Selection messages are intercepted by transport state and are not routed as normal inbound prompts.
- Provider/model lists are paginated in-keyboard with `<< Prev` / `Next >>`, plus `< Back` / `Close`.
- Provider visibility is auto-detected from runtime config + secrets/env credentials (and default provider hints), while still allowing explicit provider entries in `[providers.*]`.

### Enable

Set in gateway config: `enable_telegram: true`

### Delivery Helpers

```elixir
alias LemonChannels.Telegram.Delivery

# Send text
Delivery.enqueue_send(chat_id, "Hello", thread_id: topic_id)

# Edit message
Delivery.enqueue_edit(chat_id, message_id, "Updated text")

# With delivery notification
ref = make_ref()
Delivery.enqueue_send(chat_id, "Hello", notify: {self(), ref})
receive do
  {:outbox_delivered, ^ref, result} -> result
end
```

### Voice Transcription

Configured via transport config. Uses OpenAI-compatible API:

```elixir
LemonChannels.Adapters.Telegram.VoiceTranscriber.transcribe(%{
  audio_bytes: binary,
  api_key: key,
  base_url: "https://api.openai.com/v1",
  model: "gpt-4o-mini-transcribe",   # default
  mime_type: "audio/ogg"              # default
})
```

### Formatter

Avoids fragile MarkdownV2 escaping — renders markdown to plain text with Telegram entities:

```elixir
{text, opts} = LemonChannels.Telegram.Formatter.prepare_for_telegram(markdown_string)
# opts is nil or %{entities: [...]} suitable for passing to Telegram.API.send_message/4
```

### TriggerMode

Controls whether the bot responds to all messages or only mentions in a chat/topic:

```elixir
scope = %LemonChannels.Types.ChatScope{transport: :telegram, chat_id: 123, topic_id: 456}
LemonChannels.Telegram.TriggerMode.set(scope, account_id, :mentions)
# or :all

%{mode: :mentions, source: :topic} = LemonChannels.Telegram.TriggerMode.resolve(account_id, chat_id, topic_id)
```

## X API Integration

Twitter/X API v2 adapter at `lib/lemon_channels/adapters/x_api/`. Plugin id: `"x_api"`.

### Configuration

Via `config :lemon_channels, LemonChannels.Adapters.XAPI` or environment variables:

OAuth 2.0: `X_API_CLIENT_ID`, `X_API_CLIENT_SECRET`, `X_API_ACCESS_TOKEN`, `X_API_REFRESH_TOKEN`, `X_API_BEARER_TOKEN`

OAuth 1.0a: `X_API_CONSUMER_KEY`, `X_API_CONSUMER_SECRET`, `X_API_ACCESS_TOKEN`, `X_API_ACCESS_TOKEN_SECRET`

Common: `X_DEFAULT_ACCOUNT_ID`, `X_DEFAULT_ACCOUNT_USERNAME`

The adapter auto-detects which auth method to use. `XAPI.configured?/0` checks both.

### Capabilities

- `chunk_limit`: 280 (tweet limit)
- `rate_limit`: 2400/day
- Supports: edit, delete, images, threads (no voice, reactions, files)

### Gateway Methods

`gateway_methods/0` returns: `x_api.post_tweet`, `x_api.get_mentions`, `x_api.reply_to_tweet`
(all scoped to `:agent`).

### Token Management

Auto-refresh handled by `XAPI.TokenManager` GenServer. Starts as adapter's child process.

## XMTP Integration

Web3 messaging adapter. Plugin id: `"xmtp"`.

### Structure

| Module | Purpose |
|--------|---------|
| `adapters/xmtp.ex` | Plugin behaviour |
| `xmtp/transport.ex` | Message send/receive, `normalize_inbound_message/1`, `deliver/1` |
| `xmtp/bridge.ex` | Native bridge communication |
| `xmtp/port_server.ex` | Port process management |

### Capabilities

- `chunk_limit`: 2000
- Supports: threads only (no edit, delete, voice, images, files, reactions)

Enable via gateway config: `enable_xmtp: true`

## Discord Adapter

Discord adapter root: `LemonChannels.Adapters.Discord` (plugin id: `"discord"`).

### Structure

```
adapters/discord.ex             — Plugin behaviour
adapters/discord/supervisor.ex  — Supervisor
adapters/discord/transport.ex   — Nostrum consumer + inbound routing + slash command handling
adapters/discord/inbound.ex     — Normalize Discord events → InboundMessage
adapters/discord/outbound.ex    — Deliver OutboundPayload via Discord API
```

### Capabilities

- `chunk_limit`: 2000
- Supports: edit, delete, images/files (thread support enabled)
- Slash commands: `/lemon`, `/session new`, `/session info`

### Enable

Set in gateway config: `enable_discord: true`

## Binding Resolution

`BindingResolver` maps chat scopes to projects, engines, agents, and working directories.

```elixir
alias LemonChannels.{BindingResolver, Types.ChatScope}

scope = %ChatScope{transport: :telegram, chat_id: 123, topic_id: 456}

# Resolve full binding (project, agent_id, default_engine, queue_mode)
binding = BindingResolver.resolve_binding(scope)
# %Binding{project: "my_project", agent_id: "coder", default_engine: "claude", queue_mode: nil}

# Resolve engine (priority: resume token > engine_hint > binding > project > global default)
engine = BindingResolver.resolve_engine(scope, engine_hint, resume)

# Resolve agent id (falls back to "default")
agent_id = BindingResolver.resolve_agent_id(scope)

# Resolve working directory
cwd = BindingResolver.resolve_cwd(scope)

# Resolve queue mode (:collect | :followup | :steer | :steer_backlog | :interrupt | nil)
mode = BindingResolver.resolve_queue_mode(scope)
```

Bindings are read from `GatewayConfig.get(:bindings)`. Projects from `GatewayConfig.get(:projects)`.
Runtime project overrides and dynamic projects are stored in `LemonCore.Store`.

## Engine Registry

`LemonChannels.EngineRegistry` handles engine ID validation and resume token parsing.

```elixir
# Validate engine ID
LemonChannels.EngineRegistry.engine_known?("claude")  # true

# Extract resume token from user message
{:ok, %ResumeToken{engine: "claude", value: "abc123"}} =
  LemonChannels.EngineRegistry.extract_resume("claude --resume abc123")

# Format resume token for display
LemonChannels.EngineRegistry.format_resume(%ResumeToken{engine: "claude", value: "abc123"})
# "claude --resume abc123"
```

Default known engines: `lemon echo codex claude opencode pi kimi`. Override via `config :lemon_channels, :engines`.

## Runtime Bridge

`LemonChannels.Runtime` provides thin wrappers to cancel sessions/runs and check session state
without a hard dependency on `LemonRouter`:

```elixir
LemonChannels.Runtime.cancel_by_run_id(run_id)
LemonChannels.Runtime.cancel_by_progress_msg(session_key, progress_msg_id)
LemonChannels.Runtime.keep_run_alive(run_id, :continue | :cancel)
LemonChannels.Runtime.session_busy?(session_key)  # boolean
```

## Registry API

```elixir
# Register and unregister
LemonChannels.Registry.register(MyAdapter)
LemonChannels.Registry.unregister("my_adapter")
LemonChannels.Registry.logout("telegram")  # stop + unregister

# Lookup
LemonChannels.Registry.get_plugin("telegram")      # module | nil
LemonChannels.Registry.get_meta("telegram")        # meta map | nil
LemonChannels.Registry.get_capabilities("telegram") # capabilities map | nil

# Status
LemonChannels.Registry.list_plugins()  # [module()]
LemonChannels.Registry.list()          # [{channel_id, info_map}]
LemonChannels.Registry.status()        # %{configured: [...], connected: [...]}
```

Adapter runtime status (`running`/`stopped`, and `connected`) is derived from live
`LemonChannels.AdapterSupervisor` children by matching each plugin's child start module
(not DynamicSupervisor child IDs, which are `:undefined` for dynamic children).

## Application Lifecycle

```elixir
# Register and start an adapter (idempotent)
LemonChannels.Application.register_and_start_adapter(MyAdapter)
LemonChannels.Application.register_and_start_adapter(MyAdapter, opts)

# Start/stop without re-registering
LemonChannels.Application.start_adapter(MyAdapter)
LemonChannels.Application.stop_adapter(MyAdapter)
```

Adapters run under `LemonChannels.AdapterSupervisor` (DynamicSupervisor).

## GatewayConfig

`LemonChannels.GatewayConfig` merges config from three sources (in priority order):
1. `Application.get_env(:lemon_channels, :telegram | :xmtp)` (runtime per-adapter overrides)
2. `Application.get_env(:lemon_channels, :gateway)` (runtime gateway overrides)
3. `LemonCore.Config.cached().gateway` (TOML-backed base config)

Keys are accessed with atom/string normalization:

```elixir
LemonChannels.GatewayConfig.get(:enable_telegram)  # true | false
LemonChannels.GatewayConfig.get(:bindings, [])
LemonChannels.GatewayConfig.get(:default_engine)
LemonChannels.GatewayConfig.get(:projects, %{})
```

## Common Tasks

### Check Rate Limit Status

```elixir
LemonChannels.Outbox.RateLimiter.status("telegram", "default")
# %{tokens: 28.5, rate: 30, burst: 5}

# Check without consuming
LemonChannels.Outbox.RateLimiter.check("telegram", "default")
# :ok | {:rate_limited, wait_ms}

# Consume a token (used internally by Outbox)
LemonChannels.Outbox.RateLimiter.consume("telegram", "default")
```

### Manual Delivery (bypassing queue)

```elixir
# For testing only - delivers without queue, retry, or rate limiting
plugin = LemonChannels.Registry.get_plugin("telegram")
plugin.deliver(payload)
```

## Testing Guidance

### Run Tests

```bash
# All channel tests
mix test apps/lemon_channels

# Specific adapter tests
mix test apps/lemon_channels/test/lemon_channels/adapters/telegram
mix test apps/lemon_channels/test/lemon_channels/outbox_test.exs
```

### Key Test Files

| Test | Coverage |
|------|----------|
| `outbox_test.exs` | Queue, retry, delivery |
| `outbox_architecture_test.exs` | Per-group ordering, concurrency |
| `outbox_retry_behavior_test.exs` | Retry logic, non-retryable errors |
| `outbox_rate_limiting_test.exs` | Rate limiter |
| `outbox_chunking_test.exs` | Chunking via outbox |
| `chunker_test.exs` | Chunker unit tests |
| `dedupe_test.exs` | Idempotency |
| `telegram/inbound_test.exs` | Inbound normalization |
| `telegram/outbound_test.exs` | Outbound delivery |
| `telegram/voice_transcription_test.exs` | Voice transcription |
| `telegram/delivery_test.exs` | Delivery helper |
| `telegram/markdown_test.exs` | Markdown → entities |
| `telegram/transport_*_test.exs` | Transport behaviors (cancel, offset, auth, dedupe, parallel) |
| `telegram/transport_topic_test.exs` | `/topic` command behavior |
| `telegram/file_transfer_test.exs` | File handling |
| `x_api_test.exs` | X adapter |
| `x_api_client_test.exs` | X API client |
| `x_api_token_manager_test.exs` | Token refresh |

### Test Patterns

```elixir
# Mock adapter for testing
defmodule TestAdapter do
  @behaviour LemonChannels.Plugin
  def id, do: "test"
  def meta, do: %{label: "Test", capabilities: %{chunk_limit: 100}}
  def child_spec(_), do: %{id: __MODULE__, start: {Task, :start_link, [fn -> :ok end]}}
  def normalize_inbound(_), do: {:ok, %LemonCore.InboundMessage{}}
  def deliver(_), do: {:ok, :sent}
  def gateway_methods, do: []
end
```

## Dependencies

- `lemon_core` - Shared primitives (InboundMessage, Telemetry, Store, Dedupe.Ets, RouterBridge)
- `jason` - JSON encoding
- `earmark_parser` - Markdown parsing (used by Telegram.Markdown)
- `req` - HTTP client
