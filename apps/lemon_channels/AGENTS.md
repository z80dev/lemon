# LemonChannels AGENTS.md

Channel adapter application for external messaging platforms (Telegram, Discord, X/Twitter, XMTP).

## Quick Orientation

LemonChannels sits between external messaging platforms and the Lemon session engine. It has two jobs:

1. **Inbound**: Receive messages from platforms, normalize them to `LemonCore.InboundMessage`, and route to `LemonRouter` via `LemonCore.RouterBridge`.
2. **Outbound**: Accept `OutboundPayload` structs, chunk/dedupe/rate-limit them, and deliver to the target platform with retry.

The app lives at `apps/lemon_channels/` in the umbrella. It depends on `lemon_core` for shared types and delegates config to `LemonCore.GatewayConfig`. It bridges to `lemon_router` at runtime without a compile-time dependency (via `LemonChannels.Runtime` and `LemonCore.RouterBridge`).

### Key Entry Points

- **Top-level API**: `LemonChannels.enqueue/1`, `LemonChannels.get_plugin/1`, `LemonChannels.list_plugins/0`
- **Outbox**: `LemonChannels.Outbox.enqueue/1` -- the primary way to send outbound messages
- **Registry**: `LemonChannels.Registry` -- register, lookup, and manage adapter lifecycle
- **Application**: `LemonChannels.Application` -- supervision tree, `register_and_start_adapter/2`, `stop_adapter/1`

## Purpose and Responsibilities

LemonChannels provides:

- **Channel Plugin System**: Pluggable adapters for messaging platforms via `LemonChannels.Plugin` behaviour
- **Outbox Queue**: Reliable outbound message delivery with per-group FIFO ordering, retry, and concurrency
- **Message Processing**: Chunking (sentence/word boundary splitting), deduplication (ETS, 1h TTL), rate limiting (token bucket)
- **Inbound Normalization**: Converts raw channel data to `LemonCore.InboundMessage`

## Architecture Overview

```
                    Inbound
[Platform] → Transport → normalize_inbound() → RouterBridge → [LemonRouter]

                    Outbound
[Caller] → Outbox → Chunker → Dedupe → RateLimiter → deliver() → [Platform]
```

The Outbox preserves delivery ordering per "delivery group" (channel + account + peer + thread),
while allowing concurrency across independent groups. Chunked messages from the same payload
share a group and are never delivered concurrently to prevent reordering.

## Key Files and Purposes

### Core Infrastructure

| File | Module | What It Does |
|------|--------|-------------|
| `lib/lemon_channels.ex` | `LemonChannels` | Public API facade, delegates to Registry and Outbox |
| `lib/lemon_channels/application.ex` | `LemonChannels.Application` | Supervision tree, adapter lifecycle (`register_and_start_adapter/2`, `start_adapter/2`, `stop_adapter/1`) |
| `lib/lemon_channels/plugin.ex` | `LemonChannels.Plugin` | Behaviour definition: `id/0`, `meta/0`, `child_spec/1`, `normalize_inbound/1`, `deliver/1`, `gateway_methods/0` |
| `lib/lemon_channels/registry.ex` | `LemonChannels.Registry` | GenServer plugin registry, status tracking (running/stopped/connected) from DynamicSupervisor children |
| `lib/lemon_channels/capabilities.ex` | `LemonChannels.Capabilities` | Type definition for per-channel capability flags |
| `lib/lemon_channels/outbound_payload.ex` | `LemonChannels.OutboundPayload` | Core delivery struct. Kinds: `:text`, `:edit`, `:delete`, `:reaction`, `:file`, `:voice`. Has `notify_pid`/`notify_ref` for ack. |
| `lib/lemon_channels/binding_resolver.ex` | `LemonChannels.BindingResolver` | Maps ChatScope to project/engine/agent/cwd/queue_mode. Delegates to `LemonCore.BindingResolver`. |
| `lib/lemon_channels/engine_registry.ex` | `LemonChannels.EngineRegistry` | Validates engine IDs, parses resume tokens. Default engines: lemon echo codex claude opencode pi kimi. |
| `lib/lemon_channels/gateway_config.ex` | `LemonChannels.GatewayConfig` | Thin delegation to `LemonCore.GatewayConfig` |
| `lib/lemon_channels/runtime.ex` | `LemonChannels.Runtime` | Bridge to LemonRouter: `cancel_by_progress_msg`, `cancel_by_run_id`, `keep_run_alive`, `session_busy?` |

### Outbox Pipeline

| File | Module | What It Does |
|------|--------|-------------|
| `lib/lemon_channels/outbox.ex` | `LemonChannels.Outbox` | GenServer delivery queue. Per-group FIFO, cross-group concurrency. Exponential backoff (1s, 2s, 4s), 3 max attempts, max queue 5000. |
| `lib/lemon_channels/outbox/chunker.ex` | `Outbox.Chunker` | Splits at sentence/word boundaries. Respects per-channel `chunk_limit`. |
| `lib/lemon_channels/outbox/dedupe.ex` | `Outbox.Dedupe` | ETS-based deduplication. 1-hour TTL, periodic cleanup. |
| `lib/lemon_channels/outbox/rate_limiter.ex` | `Outbox.RateLimiter` | Token bucket (GenServer). Per channel/account, 30 msg/sec default, burst of 5. Exports `check/2`, `consume/2`, `status/2`. |

### Telegram Adapter (most complex)

**Adapter modules** (`lib/lemon_channels/adapters/telegram/`):

| File | What It Does |
|------|-------------|
| `adapters/telegram.ex` | Plugin impl. id: `"telegram"`, chunk_limit: 4096, rate_limit: 30, full capability set. |
| `adapters/telegram/supervisor.ex` | Starts AsyncSupervisor (Task.Supervisor) + Transport. |
| `adapters/telegram/transport.ex` | **Largest file (~1200 lines)**. Long-polling GenServer via getUpdates. Command handling, inbound routing, session management. State includes message indices, active runs, picker state. |
| `adapters/telegram/transport/commands.ex` | Pure command detection functions. `scope_key/3`, `join_messages/1`. No side effects. |
| `adapters/telegram/transport/file_operations.ex` | `/file put`/`get`, auto-put for document uploads, media group file handling. |
| `adapters/telegram/transport/media_groups.ex` | Coalescence of media group messages with debounce timer. |
| `adapters/telegram/transport/message_buffer.ex` | Debounce buffering for rapid-fire user messages before routing. |
| `adapters/telegram/transport/update_processor.ex` | Authorization, dedup, routing pipeline, known-target indexing (`LemonCore.Store` with 30s throttle), engine directive parsing. |
| `adapters/telegram/inbound.ex` | Normalizes Telegram updates to InboundMessage. |
| `adapters/telegram/outbound.ex` | Delivers via Bot API with retry for 429s and transient errors. |
| `adapters/telegram/voice_transcriber.ex` | OpenAI-compatible audio transcription (configurable base_url, model, mime_type). |

**Support modules** (`lib/lemon_channels/telegram/`):

| File | What It Does |
|------|-------------|
| `telegram/api.ex` | Raw Bot API calls: send_message, edit_message_text, get_updates, send_document, send_photo, send_media_group, etc. |
| `telegram/delivery.ex` | High-level enqueue helpers (`enqueue_send/3`, `enqueue_edit/3`) backed by Outbox. |
| `telegram/formatter.ex` | Markdown to plain text + Telegram entities. Avoids MarkdownV2 escaping entirely. |
| `telegram/markdown.ex` | EarmarkParser AST renderer. Produces `{text, [entity]}` with correct UTF-16 offsets. |
| `telegram/truncate.ex` | Truncates to 4096 chars preserving resume lines at the end. |
| `telegram/trigger_mode.ex` | Per-chat/topic `:all` vs `:mentions` trigger mode stored in ETS. |
| `telegram/offset_store.ex` | Persists getUpdates offset via `LemonCore.Store`. |
| `telegram/poller_lock.ex` | Global + file-based lock preventing duplicate pollers for the same account/token. |
| `telegram/transport_shared.ex` | Shared dedupe helpers across transport modules. |

### Discord Adapter

| File | What It Does |
|------|-------------|
| `adapters/discord.ex` | Plugin impl. id: `"discord"`, chunk_limit: 2000, rate_limit: 5. |
| `adapters/discord/supervisor.ex` | Starts Transport if bot_token configured. |
| `adapters/discord/transport.ex` | Nostrum consumer. Slash commands (`/lemon`, `/session new`, `/session info`). Inbound routing via RouterBridge. |
| `adapters/discord/inbound.ex` | Normalizes Discord message events to InboundMessage. Handles attachments. |
| `adapters/discord/outbound.ex` | Delivers via `Nostrum.Api.Message` (create, edit, delete). |

### X API Adapter

| File | What It Does |
|------|-------------|
| `adapters/x_api.ex` | Plugin impl. id: `"x_api"`, chunk_limit: 280, rate_limit: 2400/day. Auto-detects OAuth 1.0a vs 2.0. Config from env vars or `LemonCore.Secrets`. |
| `adapters/x_api/client.ex` | HTTP client for X API v2. Tweet post/delete, chunked media upload, rate limit handling. |
| `adapters/x_api/oauth1_client.ex` | OAuth 1.0a with HMAC-SHA1 signatures. |
| `adapters/x_api/oauth.ex` | OAuth 2.0 flow helpers (authorization URL, code exchange, PKCE). |
| `adapters/x_api/token_manager.ex` | GenServer for OAuth 2.0 auto-refresh. Persists to app config + env + secrets store. |
| `adapters/x_api/oauth_callback_handler.ex` | HTTP handler for OAuth 2.0 callbacks. |
| `adapters/x_api/gateway_methods.ex` | Control plane methods: `x_api.post_tweet`, `x_api.get_mentions`, `x_api.reply_to_tweet` (scoped `:agent`). |

### XMTP Adapter

| File | What It Does |
|------|-------------|
| `adapters/xmtp.ex` | Plugin impl. id: `"xmtp"`, chunk_limit: 2000, thread support only. |
| `adapters/xmtp/transport.ex` | GenServer. Message send/receive, `normalize_inbound_message/1`, `deliver/1`. |
| `adapters/xmtp/bridge.ex` | Communication with Node.js bridge (connect, poll, send_message). |
| `adapters/xmtp/port_server.ex` | Port process management for the Node.js bridge subprocess. |

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

1. Create adapter module in `lib/lemon_channels/adapters/` implementing `LemonChannels.Plugin`
2. Optionally create a supervisor and transport for inbound message handling
3. Register in `LemonChannels.Application.register_and_start_adapters/0` with a config gate
4. Add tests in `test/lemon_channels/adapters/`

## Common Modification Patterns

### Adding a new bot command (Telegram)

1. Add command detection in `adapters/telegram/transport/commands.ex` (pure function, pattern match on message text)
2. Add command handling in `adapters/telegram/transport.ex` (`handle_info` or the command dispatch section)
3. If the command needs async work, spawn via `Telegram.AsyncSupervisor`
4. For system messages, use `Telegram.Delivery.enqueue_send/3` (preferred Outbox path) with direct `Telegram.API` fallback

### Modifying message formatting (Telegram)

- Plain text + entities: `telegram/formatter.ex` -- converts markdown to `{text, opts}` where opts may contain `%{entities: [...]}`
- Markdown AST rendering: `telegram/markdown.ex` -- EarmarkParser-based, produces UTF-16 offset entities
- Truncation: `telegram/truncate.ex` -- preserves resume lines at end

### Adding a new outbound payload kind

1. Add the kind atom to `OutboundPayload` (in `outbound_payload.ex`)
2. Add a constructor function
3. Handle the new kind in each adapter's `deliver/1` or outbound module

### Changing delivery behavior

- Retry logic: `outbox.ex` -- look for `attempt_delivery`, `handle_delivery_result`, `schedule_retry`
- Chunking: `outbox/chunker.ex` -- `chunk/2` splits at sentence/word boundaries
- Rate limiting: `outbox/rate_limiter.ex` -- token bucket params
- Deduplication: `outbox/dedupe.ex` -- TTL and cleanup interval

### Adding a gateway method to an adapter

1. Define the method in the adapter's `gateway_methods/0` return list
2. Create or update the handler module (e.g., `XAPI.GatewayMethods`)
3. Methods have a name, scope list (e.g., `[:agent]`), and handler module

### Changing binding/engine resolution

- `binding_resolver.ex` delegates to `LemonCore.BindingResolver` -- most logic lives in `lemon_core`
- `engine_registry.ex` for adding/removing known engines or changing resume token format
- Resolution priority: resume token > engine hint > binding default > project default > global default

### Modifying the `/model` picker (Telegram)

- The picker state machine lives in `transport.ex` state
- Provider/model lists auto-detect from runtime config + secrets/env credentials
- Pagination handled inline with `<< Prev` / `Next >>` keyboard buttons
- Selection messages are intercepted and not routed as normal inbound prompts

### Modifying the `/new` command behavior (Telegram)

- `/new` acknowledges immediately with `"Started a new session."` plus model/provider/cwd details
- Session abort, cleanup, and optional memory reflection run in background tasks
- Generation counter (`telegram_thread_generation`) is incremented to invalidate stale reply mappings
- Memory reflection uses dedicated session key suffix (`:new_reflection`) with `queue_mode: :collect`

## Outbox System Details

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

### Delivery Group Key

`{channel_id, account_id, peer.kind, peer.id, peer.thread_id}` -- FIFO within group, concurrent across groups.

### Retry Details

- Exponential backoff: 1s, 2s, 4s (3 max attempts)
- 429 responses: parses `retry_after` from JSON `parameters.retry_after` or body text
- Non-retryable: `:unknown_channel`, 4xx (except 429), worker exits
- Max queue size: 5000

### Stats

```elixir
Outbox.stats()
# %{queue_length: 0, processing_count: 0, queue_depth: 0, max_queue_size: 5000, enqueued_total: 42}
```

## Telegram Adapter Details

### Transport Commands

| Command | Description |
|---------|-------------|
| `/new` | Start new session (immediate ack, async cleanup, generation increment) |
| `/resume` | Resume previous session |
| `/model` | Interactive provider/model picker via reply keyboard |
| `/thinking` | Toggle extended thinking |
| `/trigger` | Switch `:all` / `:mentions` mode |
| `/cwd` | Set working directory |
| `/file` | File put/get operations |
| `/topic` | Topic management |
| `/cancel` | Cancel current run |

### Generation-Scoped Indexing

Session/resume indices use generation-scoped keys:
- `:telegram_msg_session` keys: `{account_id, chat_id, thread_id, generation, msg_id}`
- `:telegram_msg_resume` keys: `{account_id, chat_id, thread_id, generation, msg_id}`

`/new` increments `:telegram_thread_generation` for `{account_id, chat_id, thread_id}` to invalidate stale mappings without full-table scans.

### Known-Target Indexing

`update_processor.ex` writes to `:telegram_known_targets` in `LemonCore.Store` but throttles writes to a 30-second cadence per target (unless metadata changes) to avoid overloading the store during high-traffic chats.

### Delivery Helpers

```elixir
alias LemonChannels.Telegram.Delivery

Delivery.enqueue_send(chat_id, "Hello", thread_id: topic_id)
Delivery.enqueue_edit(chat_id, message_id, "Updated text")

# With delivery notification
ref = make_ref()
Delivery.enqueue_send(chat_id, "Hello", notify: {self(), ref})
receive do
  {:outbox_delivered, ^ref, result} -> result
end
```

### Voice Transcription

```elixir
LemonChannels.Adapters.Telegram.VoiceTranscriber.transcribe(%{
  audio_bytes: binary,
  api_key: key,
  base_url: "https://api.openai.com/v1",
  model: "gpt-4o-mini-transcribe",
  mime_type: "audio/ogg"
})
```

### Formatter

Renders markdown to plain text + Telegram entities (avoids MarkdownV2 escaping):

```elixir
{text, opts} = LemonChannels.Telegram.Formatter.prepare_for_telegram(markdown_string)
# opts is nil or %{entities: [...]}
```

### TriggerMode

```elixir
scope = %LemonCore.ChatScope{transport: :telegram, chat_id: 123, topic_id: 456}
LemonChannels.Telegram.TriggerMode.set(scope, account_id, :mentions)

%{mode: :mentions, source: :topic} = LemonChannels.Telegram.TriggerMode.resolve(account_id, chat_id, topic_id)
```

## X API Integration

### Configuration

OAuth 2.0: `X_API_CLIENT_ID`, `X_API_CLIENT_SECRET`, `X_API_ACCESS_TOKEN`, `X_API_REFRESH_TOKEN`, `X_API_BEARER_TOKEN`

OAuth 1.0a: `X_API_CONSUMER_KEY`, `X_API_CONSUMER_SECRET`, `X_API_ACCESS_TOKEN`, `X_API_ACCESS_TOKEN_SECRET`

Common: `X_DEFAULT_ACCOUNT_ID`, `X_DEFAULT_ACCOUNT_USERNAME`

Auto-detects auth method. `XAPI.configured?/0` checks both. Secrets resolved via `LemonCore.Secrets` by default (configurable via `:x_api_secrets_module` and `:x_api_use_secrets`).

### Gateway Methods

`x_api.post_tweet`, `x_api.get_mentions`, `x_api.reply_to_tweet` (all scoped `:agent`).

### Token Management

Auto-refresh by `XAPI.TokenManager` GenServer. Starts as adapter child process.

## XMTP Integration

- Uses Node.js bridge process managed via Erlang Port
- Bridge handles XMTP protocol; Elixir side manages lifecycle and normalization
- Enable: `enable_xmtp: true` in gateway config

## Discord Adapter

- Uses `nostrum` library (declared `runtime: false`)
- Slash commands: `/lemon`, `/session new`, `/session info`
- Enable: `enable_discord: true` in gateway config

## Binding Resolution

```elixir
scope = %LemonCore.ChatScope{transport: :telegram, chat_id: 123, topic_id: 456}

binding = LemonChannels.BindingResolver.resolve_binding(scope)
engine  = LemonChannels.BindingResolver.resolve_engine(scope, engine_hint, resume)
agent   = LemonChannels.BindingResolver.resolve_agent_id(scope)
cwd     = LemonChannels.BindingResolver.resolve_cwd(scope)
mode    = LemonChannels.BindingResolver.resolve_queue_mode(scope)
```

Bindings from `GatewayConfig.get(:bindings)`. Projects from `GatewayConfig.get(:projects)`.

## Engine Registry

```elixir
LemonChannels.EngineRegistry.engine_known?("claude")  # true

{:ok, %ResumeToken{engine: "claude", value: "abc123"}} =
  LemonChannels.EngineRegistry.extract_resume("claude --resume abc123")
```

Default engines: `lemon echo codex claude opencode pi kimi`. Override via `config :lemon_channels, :engines`.

## Runtime Bridge

Thin wrappers to interact with `LemonRouter` without compile-time dependency:

```elixir
LemonChannels.Runtime.cancel_by_run_id(run_id)
LemonChannels.Runtime.cancel_by_progress_msg(session_key, progress_msg_id)
LemonChannels.Runtime.keep_run_alive(run_id, :continue | :cancel)
LemonChannels.Runtime.session_busy?(session_key)
```

## Registry API

```elixir
LemonChannels.Registry.register(MyAdapter)
LemonChannels.Registry.unregister("my_adapter")
LemonChannels.Registry.logout("telegram")  # stop + unregister

LemonChannels.Registry.get_plugin("telegram")       # module | nil
LemonChannels.Registry.get_meta("telegram")          # meta map | nil
LemonChannels.Registry.get_capabilities("telegram")  # capabilities map | nil

LemonChannels.Registry.list_plugins()  # [module()]
LemonChannels.Registry.list()          # [{channel_id, info_map}]
LemonChannels.Registry.status()        # %{configured: [...], connected: [...]}
```

## Application Lifecycle

```elixir
LemonChannels.Application.register_and_start_adapter(MyAdapter)
LemonChannels.Application.register_and_start_adapter(MyAdapter, opts)
LemonChannels.Application.start_adapter(MyAdapter)
LemonChannels.Application.stop_adapter(MyAdapter)
```

Adapters run under `LemonChannels.AdapterSupervisor` (DynamicSupervisor).

## GatewayConfig

Merges config from three sources (highest priority first):
1. `Application.get_env(:lemon_channels, :telegram | :xmtp)` -- runtime per-adapter overrides
2. `Application.get_env(:lemon_channels, :gateway)` -- runtime gateway overrides
3. `LemonCore.Config.cached().gateway` -- TOML-backed base config

```elixir
LemonChannels.GatewayConfig.get(:enable_telegram)
LemonChannels.GatewayConfig.get(:bindings, [])
LemonChannels.GatewayConfig.get(:default_engine)
LemonChannels.GatewayConfig.get(:projects, %{})
```

## Common Tasks

### Check Rate Limit Status

```elixir
LemonChannels.Outbox.RateLimiter.status("telegram", "default")
# %{tokens: 28.5, rate: 30, burst: 5}

LemonChannels.Outbox.RateLimiter.check("telegram", "default")
# :ok | {:rate_limited, wait_ms}
```

### Manual Delivery (bypass queue, testing only)

```elixir
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

# Run a single test file
mix test apps/lemon_channels/test/lemon_channels/adapters/telegram/inbound_test.exs
```

### Key Test Files

| Test File | Coverage |
|-----------|----------|
| `outbox_test.exs` | Queue, retry, delivery |
| `outbox_architecture_test.exs` | Per-group ordering, concurrency |
| `outbox_retry_behavior_test.exs` | Retry logic, non-retryable errors |
| `outbox_rate_limiting_test.exs` | Rate limiter integration |
| `outbox_chunking_test.exs` | Chunking via outbox |
| `chunker_test.exs` | Chunker unit tests |
| `dedupe_test.exs` | Idempotency |
| `telegram/inbound_test.exs` | Inbound normalization |
| `telegram/outbound_test.exs` | Outbound delivery |
| `telegram/voice_transcription_test.exs` | Voice transcription |
| `telegram/delivery_test.exs` | Delivery helpers |
| `telegram/markdown_test.exs` | Markdown to entities |
| `telegram/transport_*_test.exs` | Transport behaviors (cancel, offset, auth, dedupe, parallel) |
| `telegram/transport_topic_test.exs` | `/topic` command |
| `telegram/file_transfer_test.exs` | File handling |
| `discord/inbound_test.exs` | Discord inbound normalization |
| `x_api_test.exs` | X adapter |
| `x_api_client_test.exs` | X API HTTP client |
| `x_api_token_manager_test.exs` | OAuth token refresh |
| `xmtp/transport_test.exs` | XMTP transport |
| `gateway_config_test.exs` | Config merging |
| `application_test.exs` | App startup |

### Test Patterns

Mock adapter for testing:

```elixir
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

### What to Test When Modifying

- **New adapter**: Plugin behaviour compliance, deliver/normalize round-trip, child_spec starts cleanly
- **Outbox changes**: Group ordering (`outbox_architecture_test`), retry behavior, chunking boundaries
- **Telegram transport**: Use `transport_*_test.exs` files as patterns; most mock the Bot API via process state
- **Formatter/Markdown**: `markdown_test.exs` has extensive entity offset verification
- **Rate limiter**: Token consumption, burst allowance, reset timing

## Connections to Other Apps

| App | Relationship |
|-----|-------------|
| `lemon_core` | Shared types (`InboundMessage`, `ChatScope`, `Binding`), `Store`, `Secrets`, `RouterBridge`, `Dedupe.Ets`, `Telemetry`, `GatewayConfig`, `BindingResolver` |
| `lemon_router` | Inbound messages are routed via `LemonCore.RouterBridge`. `LemonChannels.Runtime` bridges cancel/busy operations at runtime (no compile dep). |
| `agent_core` | Consumes `InboundMessage` for session processing. Sends results back through `OutboundPayload` → Outbox. |
| `coding_agent` | Session engine that interacts through the router; channels deliver its output. |
| `lemon_control_plane` | Gateway methods from adapters (e.g., `x_api.post_tweet`) are exposed through the control plane. |

## Dependencies

- `lemon_core` -- Shared primitives (InboundMessage, Telemetry, Store, Dedupe.Ets, RouterBridge, Secrets)
- `jason` -- JSON encoding
- `earmark_parser` -- Markdown parsing (used by Telegram.Markdown)
- `req` -- HTTP client
- `nostrum` -- Discord library (runtime: false)
