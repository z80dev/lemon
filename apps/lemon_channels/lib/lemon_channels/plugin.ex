defmodule LemonChannels.Plugin do
  @moduledoc """
  Behaviour for channel plugins.

  A channel plugin provides integration with an external messaging channel
  (e.g., Telegram, Discord, Slack). It is a module, not a process: it
  *describes* a process tree through `c:child_spec/1`, which `LemonChannels`
  starts under its own supervisor once the plugin is registered.

  Registration happens at boot from `config :lemon_channels, :adapters`, or at
  runtime from another application:

      LemonChannels.Application.register_and_start_adapter(MyApp.ChannelAdapter, [])

  The runtime path is how a package outside this repo plugs itself in without
  the platform having any compile-time knowledge of it.

  ## Contract

  Rules the callback signatures cannot express, all of which the platform
  relies on. `LemonPlatformTest.PluginCase` turns each into a test — run it
  against your adapter rather than re-deriving these from the built-ins.

    * **`c:id/0` and `c:meta/0` are pure.** Same value on every call, no
      configuration lookups, no I/O. `c:meta/0` is hit on every status query.
    * **`c:normalize_inbound/1` must not raise.** See its docs; this is the
      rule most worth internalising, because it is enforced by nothing but
      discipline and the cost of breaking it is a reconnect loop.
    * **`c:deliver/1` reports failure rather than raising**, including for
      payload kinds the channel does not support.

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

  A short, stable, lowercase slug matching `~r/^[a-z][a-z0-9_-]*$/` — the
  built-ins are `"telegram"`, `"discord"`, `"whatsapp"`, `"xmtp"`, `"email"`,
  `"x_api"`.

  This is an identity, not a label. It is the registry key, it travels in
  `LemonCore.InboundMessage.channel_id` and
  `LemonChannels.OutboundPayload.channel_id`, and it is persisted in routing
  state — so renaming it later strands existing bindings. Use `c:meta/0`'s
  `:label` for anything a human reads.

  Must be pure: the same binary on every call.
  """
  @callback id() :: binary()

  @doc """
  Returns metadata about this channel plugin.

  Should include:
  - `:label` - Human-readable name (non-empty)
  - `:capabilities` - Map of channel capabilities
  - `:docs` - Optional documentation URL, or `nil`

  `:capabilities` is interpreted by `LemonChannels.Capabilities.from_legacy/1`,
  which reads `:edit_support`, `:delete_support`, `:thread_support`,
  `:reaction_support`, `:voice_support`, `:image_support`, `:file_support`,
  `:rich_blocks`, `:chunk_limit` and `:rate_limit`. Anything absent is treated
  as unsupported, so omit a key rather than inventing a value for it — the
  renderer uses these to decide whether it may edit a message instead of
  resending, how long a chunk may be, and whether attachments are worth
  attempting.

  Must be pure: callers hit this on every status query, so it must not do I/O
  or read configuration.
  """
  @callback meta() :: %{
              label: binary(),
              capabilities: map(),
              docs: binary() | nil
            }

  @doc """
  Returns a child spec for starting the plugin's processes.

  The standard OTP child spec: a map with at least `:id` and
  `:start` (`{module, function, args}`). `LemonChannels` starts it under its
  adapter supervisor when the plugin is registered.

  A plugin with nothing to run should still return a valid spec whose start
  function returns `:ignore` — `LemonChannels.Adapters.Email` does exactly
  that, since all it needs is an HTTP route rather than a process.
  """
  @callback child_spec(opts :: keyword()) :: Supervisor.child_spec()

  @doc """
  Normalize raw inbound data to an InboundMessage.

  Returns `{:ok, message}` or `{:error, reason}` — those two, and nothing else.

  **This callback must not raise.** It receives whatever the transport handed
  you: a truncated webhook body, a message type you have never seen, a payload
  from a version of the upstream API that shipped this morning. Raising takes
  down the process reading from the network, which usually means a reconnect
  loop, and the offending message is still waiting when you come back. Return
  `{:error, reason}` for anything you do not understand; `reason` is logged.

  A returned message must carry this plugin's own `c:id/0` as its
  `channel_id` (the platform routes replies by it), a `peer` whose `:kind` is
  one of `:dm`, `:group` or `:channel` and whose `:id` is a binary, and a
  `message` map with a binary `:text`.

  ### Known looseness

  Nothing currently forbids returning `{:ok, message}` with an *empty*
  `peer.id`, and at least one built-in adapter does so when handed a truncated
  update. Such a message is unroutable and fails much later, in the router,
  with no reference to the payload that produced it. Prefer `{:error, reason}`
  when you cannot determine who the message is from — a tightening here is
  wanted, but the adapters have to be fixed before the rule can be enforced.
  """
  @callback normalize_inbound(raw :: term()) ::
              {:ok, LemonCore.InboundMessage.t()} | {:error, term()}

  @doc """
  Deliver an outbound payload to the channel.

  Returns `{:ok, delivery_ref}` or `{:error, reason}`.

  `delivery_ref` is opaque to the platform — a provider message id, a response
  map, whatever is useful to you. It is handed back to whoever requested the
  send and is not otherwise interpreted.

  A payload kind this channel does not support is an `{:error, reason}`, not a
  crash: the renderer will attempt `:edit` against any channel whose
  capabilities claim `edit_support`, and delivery is retried and reported on by
  the outbox. Terminate the whole adapter for a single bad payload and every
  other conversation on that channel goes with it, so end your `deliver/1`
  clauses with a catch-all:

      def deliver(%OutboundPayload{kind: kind}), do: {:error, {:unsupported_kind, kind}}

  An adapter that is not configured (no token, no credentials) should also
  answer `{:error, reason}` rather than raising.
  """
  @callback deliver(LemonChannels.OutboundPayload.t()) ::
              {:ok, delivery_ref :: term()} | {:error, term()}

  @doc """
  Returns control plane methods provided by this channel.

  Each method should have:
  - `:name` - Method name (binary)
  - `:scopes` - Required scopes (list of atoms)
  - `:handler` - Handler module

  Most channels have none and return `[]`.
  """
  @callback gateway_methods() :: [
              %{name: binary(), scopes: [atom()], handler: module()}
            ]
end
