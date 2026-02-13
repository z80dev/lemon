# Discord Adapter Implementation Plan

> **Goal:** Add Discord as a channel adapter to Lemon, following the established Telegram adapter pattern.

## Overview

The Discord adapter will integrate with the existing `lemon_channels` plugin architecture, providing:
- Inbound message handling (gateway events → normalized `InboundMessage`)
- Outbound delivery (text, edit, delete, reactions, files)
- Voice channel support (optional, phase 2)

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        lemon_channels                           │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────────┐    ┌─────────────────┐                    │
│  │ Telegram Adapter│    │ Discord Adapter │  ← NEW             │
│  └────────┬────────┘    └────────┬────────┘                    │
│           │                      │                              │
│           ▼                      ▼                              │
│  ┌─────────────────────────────────────────────────────────────┤
│  │              LemonChannels.Registry                         │
│  │              LemonChannels.Outbox                           │
│  └─────────────────────────────────────────────────────────────┤
│                              │                                  │
│                              ▼                                  │
│                   LemonCore.RouterBridge                        │
│                              │                                  │
│                              ▼                                  │
│                      LemonRouter.Router                         │
└─────────────────────────────────────────────────────────────────┘
```

## Dependencies

Add to `apps/lemon_channels/mix.exs`:

```elixir
{:nostrum, "~> 0.10"},  # Discord library
{:gun, "~> 2.0"},       # HTTP/2 client (Nostrum dep)
```

## File Structure

```
apps/lemon_channels/lib/lemon_channels/adapters/
├── discord.ex                    # Plugin behaviour implementation
└── discord/
    ├── supervisor.ex             # Supervisor for Discord processes
    ├── consumer.ex               # Nostrum consumer (gateway events)
    ├── inbound.ex                # Normalize Discord → InboundMessage
    ├── outbound.ex               # Deliver OutboundPayload → Discord
    └── voice_handler.ex          # (Phase 2) Voice channel support
```

## Implementation Phases

### Phase 1: Core Messaging (MVP)

#### 1.1 Plugin Module (`discord.ex`)

```elixir
defmodule LemonChannels.Adapters.Discord do
  @behaviour LemonChannels.Plugin

  @impl true
  def id, do: "discord"

  @impl true
  def meta do
    %{
      label: "Discord",
      capabilities: %{
        edit_support: true,
        delete_support: true,
        chunk_limit: 2000,           # Discord message limit
        rate_limit: 5,               # Per channel per 5s
        voice_support: false,        # Phase 2
        image_support: true,
        file_support: true,
        reaction_support: true,
        thread_support: true
      },
      docs: "https://discord.com/developers/docs"
    }
  end

  @impl true
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {LemonChannels.Adapters.Discord.Supervisor, :start_link, [opts]},
      type: :supervisor
    }
  end

  @impl true
  def normalize_inbound(raw) do
    LemonChannels.Adapters.Discord.Inbound.normalize(raw)
  end

  @impl true
  def deliver(payload) do
    LemonChannels.Adapters.Discord.Outbound.deliver(payload)
  end

  @impl true
  def gateway_methods do
    []  # Discord-specific control plane methods (optional)
  end
end
```

#### 1.2 Supervisor (`discord/supervisor.ex`)

```elixir
defmodule LemonChannels.Adapters.Discord.Supervisor do
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    config = build_config(opts)
    token = config[:bot_token]

    children =
      if is_binary(token) and token != "" do
        [
          # Nostrum's supervisor handles the gateway connection
          {Nostrum.Application, []},
          # Our consumer handles events
          {LemonChannels.Adapters.Discord.Consumer, config}
        ]
      else
        []
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp build_config(opts) do
    base = LemonChannels.GatewayConfig.get(:discord, %{}) || %{}
    
    base
    |> Map.merge(Application.get_env(:lemon_gateway, :discord, %{}))
    |> Map.merge(Keyword.get(opts, :config, %{}))
  end
end
```

#### 1.3 Consumer (`discord/consumer.ex`)

```elixir
defmodule LemonChannels.Adapters.Discord.Consumer do
  use Nostrum.Consumer

  alias LemonChannels.Adapters.Discord.Inbound
  alias LemonCore.RouterBridge

  require Logger

  def start_link(config) do
    # Store config in process dictionary or ETS for access
    :persistent_term.put({__MODULE__, :config}, config)
    Nostrum.Consumer.start_link(__MODULE__)
  end

  # Handle new messages
  @impl true
  def handle_event({:MESSAGE_CREATE, msg, _ws_state}) do
    # Skip bot's own messages
    if msg.author.bot do
      :noop
    else
      config = :persistent_term.get({__MODULE__, :config}, %{})
      
      case Inbound.normalize(msg, config) do
        {:ok, inbound} ->
          # Check allowlist/authorization
          if authorized?(inbound, config) do
            RouterBridge.handle_inbound(inbound)
          end
          
        {:error, reason} ->
          Logger.debug("Skipping message: #{inspect(reason)}")
      end
    end
  end

  # Handle message edits (optional)
  @impl true
  def handle_event({:MESSAGE_UPDATE, msg, _ws_state}) do
    # Similar to MESSAGE_CREATE but mark as edit
    :noop
  end

  # Handle reactions (for approval flows)
  @impl true
  def handle_event({:MESSAGE_REACTION_ADD, reaction, _ws_state}) do
    handle_reaction(reaction)
  end

  # Catch-all for other events
  @impl true
  def handle_event(_event), do: :noop

  defp authorized?(inbound, config) do
    allowed_guilds = config[:allowed_guild_ids] || []
    allowed_channels = config[:allowed_channel_ids] || []
    
    cond do
      allowed_guilds != [] and inbound.meta[:guild_id] not in allowed_guilds ->
        false
      allowed_channels != [] and inbound.peer.id not in allowed_channels ->
        false
      true ->
        true
    end
  end

  defp handle_reaction(reaction) do
    # For approval flows: check if reaction is on a pending approval message
    # and resolve it accordingly
    :ok
  end
end
```

#### 1.4 Inbound Normalization (`discord/inbound.ex`)

```elixir
defmodule LemonChannels.Adapters.Discord.Inbound do
  @moduledoc """
  Normalize Discord messages to InboundMessage format.
  """

  alias LemonCore.InboundMessage

  @spec normalize(Nostrum.Struct.Message.t(), map()) :: 
    {:ok, InboundMessage.t()} | {:error, term()}
  def normalize(msg, config \\ %{}) do
    account_id = config[:account_id] || "default"
    
    peer_kind = 
      cond do
        is_nil(msg.guild_id) -> :dm
        msg.thread != nil -> :group  # Thread
        true -> :group               # Guild channel
      end

    sender = %{
      id: to_string(msg.author.id),
      username: msg.author.username,
      display_name: msg.author.global_name || msg.author.username
    }

    # Handle thread_id for forum/thread channels
    thread_id = 
      cond do
        msg.thread != nil -> to_string(msg.thread.id)
        # If message is in a thread, the channel_id IS the thread
        msg.type == 19 -> to_string(msg.channel_id)  # REPLY type
        true -> nil
      end

    # Extract reply reference
    reply_to_id = 
      case msg.message_reference do
        %{message_id: id} when not is_nil(id) -> to_string(id)
        _ -> nil
      end

    # Build text content (handle embeds, attachments, etc.)
    text = build_text_content(msg)

    inbound = %InboundMessage{
      channel_id: "discord",
      account_id: account_id,
      peer: %{
        kind: peer_kind,
        id: to_string(msg.channel_id),
        thread_id: thread_id
      },
      sender: sender,
      message: %{
        id: to_string(msg.id),
        text: text,
        timestamp: DateTime.to_unix(msg.timestamp),
        reply_to_id: reply_to_id
      },
      raw: msg,
      meta: %{
        guild_id: msg.guild_id && to_string(msg.guild_id),
        channel_id: msg.channel_id,
        message_id: msg.id,
        attachments: normalize_attachments(msg.attachments),
        mentions: Enum.map(msg.mentions, &to_string(&1.id)),
        referenced_message: msg.referenced_message
      }
    }

    {:ok, inbound}
  end

  defp build_text_content(msg) do
    base = msg.content || ""
    
    # Append attachment URLs for context
    attachment_text = 
      msg.attachments
      |> Enum.map(& &1.url)
      |> Enum.join("\n")

    if attachment_text != "" do
      base <> "\n\n[Attachments]\n" <> attachment_text
    else
      base
    end
  end

  defp normalize_attachments(attachments) do
    Enum.map(attachments, fn att ->
      %{
        id: to_string(att.id),
        filename: att.filename,
        url: att.url,
        content_type: att.content_type,
        size: att.size
      }
    end)
  end
end
```

#### 1.5 Outbound Delivery (`discord/outbound.ex`)

```elixir
defmodule LemonChannels.Adapters.Discord.Outbound do
  @moduledoc """
  Deliver outbound payloads to Discord.
  """

  alias LemonChannels.OutboundPayload
  alias Nostrum.Api

  require Logger

  @spec deliver(OutboundPayload.t()) :: {:ok, term()} | {:error, term()}
  def deliver(%OutboundPayload{kind: :text} = payload) do
    channel_id = String.to_integer(payload.peer.id)
    
    opts = []
    opts = if payload.reply_to do
      message_reference = %{message_id: String.to_integer(payload.reply_to)}
      [{:message_reference, message_reference} | opts]
    else
      opts
    end

    case Api.create_message(channel_id, content: payload.content, opts: opts) do
      {:ok, msg} -> {:ok, msg}
      {:error, reason} -> {:error, reason}
    end
  end

  def deliver(%OutboundPayload{kind: :edit, content: %{message_id: msg_id, text: text}} = payload) do
    channel_id = String.to_integer(payload.peer.id)
    message_id = parse_id(msg_id)

    case Api.edit_message(channel_id, message_id, content: text) do
      {:ok, msg} -> {:ok, msg}
      {:error, reason} -> {:error, reason}
    end
  end

  def deliver(%OutboundPayload{kind: :delete, content: %{message_id: msg_id}} = payload) do
    channel_id = String.to_integer(payload.peer.id)
    message_id = parse_id(msg_id)

    case Api.delete_message(channel_id, message_id) do
      {:ok} -> {:ok, :deleted}
      {:error, reason} -> {:error, reason}
    end
  end

  def deliver(%OutboundPayload{kind: :reaction, content: %{message_id: msg_id, emoji: emoji}} = payload) do
    channel_id = String.to_integer(payload.peer.id)
    message_id = parse_id(msg_id)

    case Api.create_reaction(channel_id, message_id, emoji) do
      {:ok} -> {:ok, :reacted}
      {:error, reason} -> {:error, reason}
    end
  end

  def deliver(%OutboundPayload{kind: :file, content: %{path: path}} = payload) do
    channel_id = String.to_integer(payload.peer.id)
    
    opts = []
    opts = if payload.content[:caption] do
      [{:content, payload.content[:caption]} | opts]
    else
      opts
    end

    case Api.create_message(channel_id, [{:files, [path]} | opts]) do
      {:ok, msg} -> {:ok, msg}
      {:error, reason} -> {:error, reason}
    end
  end

  def deliver(%OutboundPayload{kind: kind}) do
    {:error, {:unsupported_kind, kind}}
  end

  defp parse_id(id) when is_binary(id), do: String.to_integer(id)
  defp parse_id(id) when is_integer(id), do: id
end
```

### Phase 2: Enhanced Features

#### 2.1 Voice Support (`discord/voice_handler.ex`)

- Join/leave voice channels
- Text-to-speech playback via Nostrum.Voice
- Speech-to-text (requires external service like Whisper)

#### 2.2 Slash Commands

- Register bot commands with Discord
- Handle interactions via `INTERACTION_CREATE` events

#### 2.3 Threads & Forums

- Create threads from messages
- Handle forum post creation

#### 2.4 Rich Embeds

- Format agent responses as Discord embeds
- Include metadata (model, tokens, timing)

### Phase 3: Advanced Features

#### 3.1 Approval Buttons

- Use Discord's button components for tool approvals
- Handle `INTERACTION_CREATE` for button clicks

#### 3.2 Progress Indicators

- Edit message with progress updates
- Use Discord's typing indicator

#### 3.3 Multi-Guild Support

- Per-guild configuration
- Guild-specific project bindings

## Configuration

Add to `config/config.exs` or TOML config:

```elixir
config :lemon_gateway, :discord,
  bot_token: System.get_env("DISCORD_BOT_TOKEN"),
  account_id: "default",
  allowed_guild_ids: [],      # Empty = all guilds
  allowed_channel_ids: [],    # Empty = all channels
  # Trigger modes (like Telegram)
  trigger_mode: :always,      # :always | :mention | :reply | :command
  # Bot mention detection
  bot_id: nil,                # Auto-detected from token
  # Debouncing
  debounce_ms: 1000,
  # File handling
  files: %{
    enabled: true,
    auto_put: true,
    uploads_dir: "incoming",
    max_upload_bytes: 25 * 1024 * 1024,  # Discord limit
    max_download_bytes: 25 * 1024 * 1024
  }
```

Or TOML:

```toml
[gateway.discord]
bot_token = "${DISCORD_BOT_TOKEN}"
account_id = "default"
allowed_guild_ids = []
allowed_channel_ids = []
trigger_mode = "always"
debounce_ms = 1000

[gateway.discord.files]
enabled = true
auto_put = true
uploads_dir = "incoming"
```

## Nostrum Configuration

Add to `config/config.exs`:

```elixir
config :nostrum,
  token: System.get_env("DISCORD_BOT_TOKEN"),
  gateway_intents: [
    :guilds,
    :guild_messages,
    :guild_message_reactions,
    :direct_messages,
    :direct_message_reactions,
    :message_content  # Required for reading message content
  ]
```

## Testing Strategy

### Unit Tests

```elixir
# test/lemon_channels/adapters/discord/inbound_test.exs
defmodule LemonChannels.Adapters.Discord.InboundTest do
  use ExUnit.Case
  alias LemonChannels.Adapters.Discord.Inbound

  test "normalizes basic message" do
    msg = %Nostrum.Struct.Message{
      id: 123456789,
      channel_id: 987654321,
      author: %{id: 111, username: "testuser", bot: false},
      content: "Hello world",
      timestamp: ~U[2025-01-01 12:00:00Z]
    }

    assert {:ok, inbound} = Inbound.normalize(msg)
    assert inbound.channel_id == "discord"
    assert inbound.message.text == "Hello world"
    assert inbound.peer.id == "987654321"
  end

  test "handles DM vs guild messages" do
    dm_msg = %{...guild_id: nil...}
    guild_msg = %{...guild_id: 123...}

    assert {:ok, dm} = Inbound.normalize(dm_msg)
    assert dm.peer.kind == :dm

    assert {:ok, guild} = Inbound.normalize(guild_msg)
    assert guild.peer.kind == :group
  end
end
```

### Integration Tests

- Mock Nostrum API for outbound tests
- Use Discord test server for E2E tests

## Migration Checklist

- [ ] Add Nostrum dependency
- [ ] Configure Nostrum gateway intents
- [ ] Create adapter module structure
- [ ] Implement Plugin behaviour
- [ ] Implement Consumer for gateway events
- [ ] Implement Inbound normalization
- [ ] Implement Outbound delivery
- [ ] Add Discord to registry
- [ ] Add configuration handling
- [ ] Write tests
- [ ] Documentation
- [ ] (Phase 2) Voice support
- [ ] (Phase 2) Slash commands

## Open Questions

1. **Trigger modes:** Should we support `@mention` requirement like some Discord bots?
2. **Rate limiting:** Nostrum handles this, but should we add channel-level rate limiting in outbox?
3. **Sharding:** For large bots (>2500 guilds), Nostrum supports sharding. Do we need it?
4. **Voice priority:** Is voice support needed for MVP or can it wait?

## Timeline Estimate

| Phase | Scope | Effort |
|-------|-------|--------|
| Phase 1 | Core messaging (send/receive/edit/delete) | 2-3 days |
| Phase 2 | Voice, slash commands, threads | 3-5 days |
| Phase 3 | Buttons, progress, multi-guild | 2-3 days |

**Total MVP (Phase 1): ~3 days**

---

*Created: 2025-02-08*
*Author: Guna*
