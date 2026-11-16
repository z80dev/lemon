defmodule LemonGateway.TransportRegistry do
  @moduledoc """
  Registry of available transport modules.

  Publishes transport modules and their configured enablement at startup.
  Lookups read an immutable snapshot without calling this process or Config.
  Restart the registry after changing transport configuration.
  """
  use GenServer
  require Logger

  @type transport_id :: String.t()
  @type transport_mod :: module()

  @reserved_ids ~w(default all)
  @channels_owned_transport_ids ~w(discord email)
  @id_regex ~r/^[a-z][a-z0-9_-]*$/
  @snapshot_key {__MODULE__, :snapshot}

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "Returns a list of all registered transport IDs."
  @spec list_transports() :: [transport_id()]
  def list_transports, do: snapshot().transports |> Map.keys()

  @doc "Returns the transport module for the given ID, or raises if not found."
  @spec get_transport!(transport_id()) :: transport_mod()
  def get_transport!(id) do
    case get_transport(id) do
      nil -> raise ArgumentError, "unknown transport id: #{inspect(id)}"
      mod -> mod
    end
  end

  @doc "Returns the transport module for the given ID, or `nil` if not registered."
  @spec get_transport(transport_id()) :: transport_mod() | nil
  def get_transport(id), do: Map.get(snapshot().transports, id)

  @spec enabled_transports() :: [{transport_id(), transport_mod()}]
  def enabled_transports, do: snapshot().enabled

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

        if id in @channels_owned_transport_ids do
          Logger.warning(
            "transport #{inspect(id)} is owned by lemon_channels; remove #{inspect(mod)} from :transports"
          )

          acc
        else
          Map.put(acc, id, mod)
        end
      end)

    maybe_warn_dual_gate(map)

    enabled = Enum.filter(map, fn {id, _mod} -> transport_enabled?(id) end)
    :persistent_term.put(@snapshot_key, {self(), %{transports: map, enabled: enabled}})
    {:ok, nil}
  end

  defp snapshot do
    case :persistent_term.get(@snapshot_key, nil) do
      {owner, snapshot} ->
        if Process.whereis(__MODULE__) == owner,
          do: snapshot,
          else: %{transports: %{}, enabled: []}

      nil ->
        %{transports: %{}, enabled: []}
    end
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
    LemonGateway.Config.get_or_env(key, false) == true
  end

  defp transport_enabled?("telegram"), do: get_config_boolean(:enable_telegram)
  defp transport_enabled?("xmtp"), do: get_config_boolean(:enable_xmtp)
  defp transport_enabled?("webhook"), do: get_config_boolean(:enable_webhook)
  defp transport_enabled?(_id), do: true
end
