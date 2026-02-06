defmodule LemonGateway.TransportRegistry do
  @moduledoc false
  use GenServer

  @type transport_id :: String.t()
  @type transport_mod :: module()

  @reserved_ids ~w(default all)
  @id_regex ~r/^[a-z][a-z0-9_-]*$/

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec list_transports() :: [transport_id()]
  def list_transports, do: GenServer.call(__MODULE__, :list)

  @spec get_transport!(transport_id()) :: transport_mod()
  def get_transport!(id), do: GenServer.call(__MODULE__, {:get, id})

  @spec get_transport(transport_id()) :: transport_mod() | nil
  def get_transport(id), do: GenServer.call(__MODULE__, {:get_or_nil, id})

  @spec enabled_transports() :: [{transport_id(), transport_mod()}]
  def enabled_transports, do: GenServer.call(__MODULE__, :enabled)

  @impl true
  def init(_opts) do
    transports =
      Application.get_env(:lemon_gateway, :transports, [
        LemonGateway.Telegram.Transport
      ])

    map =
      transports
      |> Enum.reduce(%{}, fn mod, acc ->
        id = mod.id()
        validate_id!(id)
        Map.put(acc, id, mod)
      end)

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

  defp transport_enabled?("telegram") do
    # Primary source of truth: LemonGateway.Config (TOML-backed GenServer).
    # Fallback: application env override (used in tests).
    if is_pid(Process.whereis(LemonGateway.Config)) do
      LemonGateway.Config.get(:enable_telegram) == true
    else
      cfg = Application.get_env(:lemon_gateway, LemonGateway.Config, %{})

      if is_list(cfg) do
        Keyword.get(cfg, :enable_telegram, false)
      else
        Map.get(cfg, :enable_telegram, false)
      end
    end
  end

  defp transport_enabled?(_id), do: true
end
