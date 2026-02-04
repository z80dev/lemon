defmodule LemonChannels do
  @moduledoc """
  LemonChannels provides channel plugins and outbox for message delivery.

  This app is responsible for:

  - Channel plugin registration and discovery
  - Outbound message delivery with retry and rate limiting
  - Deduplication to prevent duplicate messages
  - Chunking for long messages
  - Telegram adapter (and future channel adapters)

  ## Architecture

  ```
  [Router] -> [Outbox] -> [Plugin] -> [External Channel]
                 |
                 v
            [Dedupe/RateLimit/Chunker]
  ```

  ## Plugin System

  Channels are implemented as plugins that implement the `LemonChannels.Plugin`
  behaviour. Each plugin provides:

  - `normalize_inbound/1` - Convert raw channel data to InboundMessage
  - `deliver/1` - Send outbound payloads to the channel
  - `gateway_methods/0` - Control plane methods for the channel
  """

  alias LemonChannels.{Outbox, Registry}

  @doc """
  Get a registered channel plugin by ID.
  """
  defdelegate get_plugin(id), to: Registry

  @doc """
  List all registered channel plugins.
  """
  defdelegate list_plugins(), to: Registry

  @doc """
  Enqueue an outbound payload for delivery.
  """
  defdelegate enqueue(payload), to: Outbox
end
