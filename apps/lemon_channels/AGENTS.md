# LemonChannels AGENTS.md

Channel adapter application for external messaging platforms (Telegram, X/Twitter, XMTP).

## Purpose and Responsibilities

LemonChannels provides:

- **Channel Plugin System**: Pluggable adapters for messaging platforms
- **Outbox Queue**: Reliable outbound message delivery with retry
- **Message Processing**: Chunking, deduplication, rate limiting
- **Inbound Normalization**: Converts raw channel data to `LemonCore.InboundMessage`

## Architecture Overview

```
[Router] → [Outbox] → [Plugin] → [External Channel]
              ↓
         [Chunker/Dedupe/RateLimiter]
```

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
        voice_support: false
      }
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
| Deduplication | `Outbox.Dedupe` | Prevent duplicate deliveries via idempotency keys |
| Rate Limiting | `Outbox.RateLimiter` | Token bucket per channel/account |
| Retry | `Outbox` | Exponential backoff with 3 max attempts |

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

### Outbox Stats

```elixir
Outbox.stats()
# %{queue_length: 0, processing_count: 0, queue_depth: 0, max_queue_size: 5000}
```

## Telegram Adapter

Primary adapter at `lib/lemon_channels/adapters/telegram/`.

### Structure

| Module | Purpose |
|--------|---------|
| `telegram.ex` | Plugin behaviour implementation |
| `telegram/inbound.ex` | Normalize Telegram updates to InboundMessage |
| `telegram/outbound.ex` | Deliver messages via Bot API |
| `telegram/transport.ex` | Long-polling update receiver |
| `telegram/voice_transcriber.ex` | OpenAI-compatible voice transcription |
| `telegram/supervisor.ex` | Adapter supervision tree |

### Key Capabilities

- chunk_limit: 4096
- rate_limit: 30 msg/sec
- Supports: edit, delete, voice, images, files, reactions, threads

### Delivery Helpers

```elixir
alias LemonChannels.Telegram.Delivery

# Send text
Delivery.enqueue_send(chat_id, "Hello", thread_id: topic_id)

# Edit message
Delivery.enqueue_edit(chat_id, message_id, "Updated text")
```

### Voice Transcription

Uses OpenAI-compatible API (default: `gpt-4o-mini-transcribe`):

```elixir
LemonChannels.Adapters.Telegram.VoiceTranscriber.transcribe(
  audio_bytes: binary,
  api_key: key,
  base_url: "https://api.openai.com/v1"
)
```

## X API Integration

Twitter/X API v2 adapter at `lib/lemon_channels/adapters/x_api/`.

### Configuration

Environment variables:
- `X_API_CLIENT_ID`, `X_API_CLIENT_SECRET` (OAuth 2.0)
- `X_API_ACCESS_TOKEN`, `X_API_REFRESH_TOKEN`
- `X_API_BEARER_TOKEN`
- `X_DEFAULT_ACCOUNT_ID`, `X_DEFAULT_ACCOUNT_USERNAME`

Or OAuth 1.0a:
- `X_API_CONSUMER_KEY`, `X_API_CONSUMER_SECRET`
- `X_API_ACCESS_TOKEN`, `X_API_ACCESS_TOKEN_SECRET`

### Capabilities

- chunk_limit: 280 (tweet limit)
- rate_limit: 2400/day
- Supports: edit, delete, images, threads

### Token Management

Auto-refresh handled by `XAPI.TokenManager` GenServer.

## XMTP Integration

Web3 messaging adapter at `lib/lemon_channels/adapters/xmtp/`.

### Structure

| Module | Purpose |
|--------|---------|
| `xmtp.ex` | Plugin behaviour |
| `xmtp/transport.ex` | Message send/receive |
| `xmtp/bridge.ex` | Native bridge communication |
| `xmtp/port_server.ex` | Port process management |

### Capabilities

- chunk_limit: 2000
- Supports: threads

Enable via config: `enable_xmtp: true`

## Binding Resolution

`BindingResolver` maps chat scopes to projects, engines, and agents.

```elixir
alias LemonChannels.{BindingResolver, Types.ChatScope}

scope = %ChatScope{transport: :telegram, chat_id: 123, topic_id: 456}

# Resolve binding
binding = BindingResolver.resolve_binding(scope)
# %Binding{project: "my_project", agent_id: "coder", default_engine: "claude"}

# Resolve engine
engine = BindingResolver.resolve_engine(scope, engine_hint, resume)

# Resolve agent
agent_id = BindingResolver.resolve_agent_id(scope)
```

## Common Tasks

### Register a Plugin at Runtime

```elixir
LemonChannels.Registry.register(MyAdapter)
LemonChannels.Application.start_adapter(MyAdapter)
```

### Get Plugin Info

```elixir
LemonChannels.Registry.get_plugin("telegram")
LemonChannels.Registry.get_capabilities("telegram")
LemonChannels.Registry.status()
```

### Manual Outbox Delivery

```elixir
# For testing - deliver without queue
plugin = LemonChannels.Registry.get_plugin("telegram")
plugin.deliver(payload)
```

### Check Rate Limit Status

```elixir
LemonChannels.Outbox.RateLimiter.status("telegram", "default")
# %{tokens: 28, rate: 30, burst: 5}
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
| `chunker_test.exs` | Message chunking |
| `dedupe_test.exs` | Idempotency |
| `outbox_rate_limiting_test.exs` | Rate limiter |
| `telegram/inbound_test.exs` | Inbound normalization |
| `telegram/outbound_test.exs` | Outbound delivery |
| `voice_transcription_test.exs` | Voice transcription |

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

- `lemon_core` - Shared primitives (InboundMessage, Telemetry, Store)
- `jason` - JSON encoding
- `earmark_parser` - Markdown parsing
- `req` - HTTP client
