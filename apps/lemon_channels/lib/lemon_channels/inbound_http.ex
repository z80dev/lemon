defmodule LemonChannels.InboundHttp do
  @moduledoc """
  Optional inbound HTTP listener for channel adapters.

  Every adapter shipped before this module was a *client* — a poller, a
  websocket client, or a bridge process. Adapters that instead need to *receive*
  HTTP (an email webhook, for instance) had nowhere to bind a port, which is why
  those surfaces stayed in `lemon_gateway`. This is the smallest thing that
  closes that gap: one Bandit listener, off unless configured, dispatching by
  the first path segment to a registered handler.

  ## Configuration

      config :lemon_channels, LemonChannels.InboundHttp,
        enabled: true,
        port: 4090,
        ip: {127, 0, 0, 1}

  Disabled by default. When disabled only the route-registration child starts:
  nothing binds a port, but adapters can still register handlers at boot.

  ## Registering a handler

  Adapters register a path segment at boot and implement
  `LemonChannels.InboundHttp.Handler`:

      LemonChannels.InboundHttp.register("email", MyAdapter.Webhook)

  A request to `/email/anything` is then routed to
  `MyAdapter.Webhook.handle_inbound/1`, which receives the `Plug.Conn` (already
  parsed) and returns it having sent a response.

  Registration is deliberately runtime rather than compile-time so satellite
  packages can add listeners without this app knowing they exist.

  Registrations are serialized config updates that publish a persistent-term
  snapshot. Request dispatch never calls the registration process. A restart
  clears the snapshot; adapters must register again before receiving requests.
  """

  use Supervisor

  alias LemonChannels.InboundHttp.Routes

  @default_max_body_bytes 2_000_000

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [Routes] ++ listener_children()

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp listener_children do
    if enabled?() do
      [
        {Bandit, plug: LemonChannels.InboundHttp.Router, scheme: :http, port: port(), ip: ip()}
      ]
    else
      []
    end
  end

  @doc "Whether the listener is configured to bind a port."
  @spec enabled?() :: boolean()
  def enabled?, do: config() |> Keyword.get(:enabled, false) == true

  @doc "Configured port. Only meaningful when `enabled?/0`."
  @spec port() :: non_neg_integer()
  def port, do: config() |> Keyword.get(:port, 4090)

  @doc "Configured bind address, loopback by default."
  @spec ip() :: :inet.ip_address()
  def ip, do: config() |> Keyword.get(:ip, {127, 0, 0, 1})

  @doc """
  Largest request body the listener will read, in bytes.

  2 MB by default — deliberately well under `Plug.Parsers`' 8 MB, since a
  webhook endpoint is reachable by anyone who learns the URL and this is what
  bounds the memory one request can cost. Over the limit the caller gets a 413.

  Raise it for an adapter that must accept large payloads, remembering that
  attachments are usually base64-encoded on the wire and so occupy about a
  third more than their decoded size:

      config :lemon_channels, LemonChannels.InboundHttp, max_body_bytes: 8_000_000

  `LemonChannels.Adapters.Email` derives its own attachment cap from this, so
  the two cannot contradict each other.
  """
  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes do
    case config() |> Keyword.get(:max_body_bytes, @default_max_body_bytes) do
      bytes when is_integer(bytes) and bytes > 0 -> bytes
      _ -> @default_max_body_bytes
    end
  end

  @doc """
  Registers `handler` for the first path segment `segment`.

  Returns `:ok`, or `{:error, :not_running}` when the listener supervisor is not
  started (which is the case in apps that never start `lemon_channels`).

  Last registration wins. Two packages claiming the same segment is a
  misconfiguration rather than a supported layout — the loser's webhooks would
  silently arrive at the winner — so a replacement is logged at warning level.
  Registration order between two applications is not something either of them
  controls, which is exactly why this must not be quiet.
  """
  @spec register(binary(), module()) :: :ok | {:error, :not_running}
  def register(segment, handler) when is_binary(segment) and is_atom(handler) do
    Routes.register(segment, handler)
  end

  @doc "Looks up the handler registered for a path segment."
  @spec handler_for(binary()) :: module() | nil
  def handler_for(segment) when is_binary(segment), do: Map.get(handlers(), segment)

  @doc "All registered `segment => handler` pairs."
  @spec handlers() :: %{optional(binary()) => module()}
  def handlers, do: Routes.handlers()

  defp config, do: Application.get_env(:lemon_channels, __MODULE__, [])
end
