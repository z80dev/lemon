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

  Disabled by default. When disabled the supervisor starts with no children, so
  nothing binds a port and adapters that need inbound HTTP simply never receive
  anything — the same failure mode as an unconfigured poller.

  ## Registering a handler

  Adapters register a path segment at boot and implement
  `LemonChannels.InboundHttp.Handler`:

      LemonChannels.InboundHttp.register("email", MyAdapter.Webhook)

  A request to `/email/anything` is then routed to
  `MyAdapter.Webhook.handle_inbound/1`, which receives the `Plug.Conn` (already
  parsed) and returns it having sent a response.

  Registration is deliberately runtime rather than compile-time so satellite
  packages can add listeners without this app knowing they exist.
  """

  use Supervisor

  require Logger

  @registry_name __MODULE__.Routes

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [{Agent, fn -> %{} end} |> agent_spec()] ++ listener_children()

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp agent_spec({Agent, fun}) do
    %{id: @registry_name, start: {Agent, :start_link, [fun, [name: @registry_name]]}}
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
  Registers `handler` for the first path segment `segment`.

  Returns `:ok`, or `{:error, :not_running}` when the listener supervisor is not
  started (which is the case in apps that never start `lemon_channels`).
  """
  @spec register(binary(), module()) :: :ok | {:error, :not_running}
  def register(segment, handler) when is_binary(segment) and is_atom(handler) do
    if Process.whereis(@registry_name) do
      Agent.update(@registry_name, &Map.put(&1, segment, handler))
    else
      {:error, :not_running}
    end
  end

  @doc "Looks up the handler registered for a path segment."
  @spec handler_for(binary()) :: module() | nil
  def handler_for(segment) when is_binary(segment) do
    if Process.whereis(@registry_name) do
      Agent.get(@registry_name, &Map.get(&1, segment))
    end
  end

  @doc "All registered `segment => handler` pairs."
  @spec handlers() :: %{optional(binary()) => module()}
  def handlers do
    if Process.whereis(@registry_name), do: Agent.get(@registry_name, & &1), else: %{}
  end

  defp config, do: Application.get_env(:lemon_channels, __MODULE__, [])
end
