defmodule LemonChannels.Plugin do
  @moduledoc """
  Behaviour for channel plugins.

  A channel plugin provides integration with an external messaging channel
  (e.g., Telegram, Discord, Slack).

  ## Implementing a Plugin

      defmodule MyChannel.Plugin do
        @behaviour LemonChannels.Plugin

        @impl true
        def id, do: "my-channel"

        @impl true
        def meta do
          %{
            label: "My Channel",
            capabilities: %{
              edit_support: true,
              chunk_limit: 4096,
              voice_support: false
            },
            docs: "https://example.com/docs"
          }
        end

        @impl true
        def child_spec(opts) do
          %{
            id: __MODULE__,
            start: {MyChannel.Supervisor, :start_link, [opts]}
          }
        end

        @impl true
        def normalize_inbound(raw) do
          # Convert raw channel data to InboundMessage
          {:ok, %LemonCore.InboundMessage{...}}
        end

        @impl true
        def deliver(payload) do
          # Send message to channel
          {:ok, delivery_ref}
        end

        @impl true
        def gateway_methods do
          []
        end
      end
  """

  @doc """
  Returns the unique identifier for this channel.
  """
  @callback id() :: binary()

  @doc """
  Returns metadata about this channel plugin.

  Should include:
  - `:label` - Human-readable name
  - `:capabilities` - Map of channel capabilities
  - `:docs` - Optional documentation URL
  """
  @callback meta() :: %{
              label: binary(),
              capabilities: map(),
              docs: binary() | nil
            }

  @doc """
  Returns a child spec for starting the plugin's processes.
  """
  @callback child_spec(opts :: keyword()) :: Supervisor.child_spec()

  @doc """
  Normalize raw inbound data to an InboundMessage.

  Returns `{:ok, message}` or `{:error, reason}`.
  """
  @callback normalize_inbound(raw :: term()) ::
              {:ok, LemonCore.InboundMessage.t()} | {:error, term()}

  @doc """
  Deliver an outbound payload to the channel.

  Returns `{:ok, delivery_ref}` or `{:error, reason}`.
  """
  @callback deliver(LemonChannels.OutboundPayload.t()) ::
              {:ok, delivery_ref :: term()} | {:error, term()}

  @doc """
  Returns control plane methods provided by this channel.

  Each method should have:
  - `:name` - Method name
  - `:scopes` - Required scopes
  - `:handler` - Handler module
  """
  @callback gateway_methods() :: [
              %{name: binary(), scopes: [atom()], handler: module()}
            ]
end
