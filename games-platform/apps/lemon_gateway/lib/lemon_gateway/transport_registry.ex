defmodule LemonGateway.TransportRegistry do
  @moduledoc """
  Registry of available transport modules.

  Maintains a mapping of transport ID strings to their implementing modules.
  Tracks which transports are enabled via configuration and warns about
  misconfigured transports at startup.
  """
  use GenServer
  require Logger

  @type transport_id :: String.t()
  @type transport_mod :: module()

  @reserved_ids ~w(default all)
  @id_regex ~r/^[a-z][a-z0-9_-]*$/

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "Returns a list of all registered transport IDs."
  @spec list_transports() :: [transport_id()]
  def list_transports, do: GenServer.call(__MODULE__, :list)

  @doc "Returns the transport module for the given ID, or raises if not found."
  @spec get_transport!(transport_id()) :: transport_mod()
  def get_transport!(id), do: GenServer.call(__MODULE__, {:get, id})

  @doc "Returns the transport module for the given ID, or `nil` if not registered."
  @spec get_transport(transport_id()) :: transport_mod() | nil
  def get_transport(id), do: GenServer.call(__MODULE__, {:get_or_nil, id})

  @spec enabled_transports() :: [{transport_id(), transport_mod()}]
  def enabled_transports, do: GenServer.call(__MODULE__, :enabled)

  @impl true
  def init(_opts) do
    transports =
      Application.get_env(:lemon_gateway, :transports, [
        # Intentionally empty by default: Telegram polling is owned by lemon_channels.
      ])

    map =
      transports
      |> Enum.reduce(%{}, fn mod, acc ->
        id = mod.id()
        validate_id!(id)
        Map.put(acc, id, mod)
      end)

    maybe_warn_dual_gate(map)

    {:ok, map}
  end

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, Map.keys(state), state}
  end

  def handle_call({:get, id}, _from, state) do
    case Map.fetch(state, id) do
      {:ok, mod} -> {:reply, mod, state}
      :error -> raise ArgumentError, "unknown transport id: #{inspect(id)}"
    end
  end

  def handle_call({:get_or_nil, id}, _from, state) do
    {:reply, Map.get(state, id), state}
  end

  def handle_call(:enabled, _from, state) do
    enabled =
      state
      |> Enum.filter(fn {id, _mod} -> transport_enabled?(id) end)
      |> Enum.into([])

    {:reply, enabled, state}
  end

  defp validate_id!(id) when id in @reserved_ids do
    raise ArgumentError, "transport id reserved: #{id}"
  end

  defp validate_id!(id) do
    if Regex.match?(@id_regex, id) do
      :ok
    else
      raise ArgumentError, "invalid transport id: #{inspect(id)}"
    end
  end

  defp maybe_warn_dual_gate(state) when is_map(state) do
    if transport_enabled?("farcaster") and not Map.has_key?(state, "farcaster") do
      Logger.warning(
        "enable_farcaster is true but Farcaster transport is not registered in :transports; add LemonGateway.Transports.Farcaster to :transports or disable enable_farcaster"
      )
    end

    if transport_enabled?("email") and not Map.has_key?(state, "email") do
      Logger.warning(
        "enable_email is true but Email transport is not registered in :transports; add LemonGateway.Transports.Email to :transports or disable enable_email"
      )
    end

    if transport_enabled?("webhook") and not Map.has_key?(state, "webhook") do
      Logger.warning(
        "enable_webhook is true but Webhook transport is not registered in :transports; add LemonGateway.Transports.Webhook to :transports or disable enable_webhook"
      )
    end
  end

  defp maybe_warn_dual_gate(_), do: :ok

  # Primary source of truth: LemonGateway.Config (TOML-backed GenServer).
  # Fallback: application env override (used in tests).
  defp get_config_boolean(key) do
    if is_pid(Process.whereis(LemonGateway.Config)) do
      LemonGateway.Config.get(key) == true
    else
      cfg = Application.get_env(:lemon_gateway, LemonGateway.Config, %{})

      if is_list(cfg) do
        Keyword.get(cfg, key, false)
      else
        Map.get(cfg, key, false)
      end
    end
  end

  defp transport_enabled?("telegram"), do: get_config_boolean(:enable_telegram)
  defp transport_enabled?("discord"), do: get_config_boolean(:enable_discord)
  defp transport_enabled?("farcaster"), do: get_config_boolean(:enable_farcaster)
  defp transport_enabled?("email"), do: get_config_boolean(:enable_email)
  defp transport_enabled?("xmtp"), do: get_config_boolean(:enable_xmtp)
  defp transport_enabled?("webhook"), do: get_config_boolean(:enable_webhook)
  defp transport_enabled?(_id), do: true
end
