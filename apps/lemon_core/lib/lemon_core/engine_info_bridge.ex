defmodule LemonCore.EngineInfoBridge do
  @moduledoc """
  Optional bridge to the gateway runtime, without compile-time coupling.

  Channels and the control plane use the gateway runtime (`:lemon_gateway` in
  the reference runtime) for transport-registry ops introspection and any
  full-replacement gateway config it holds. The gateway registers itself here
  at boot and callers ask core:

      LemonCore.EngineInfoBridge.configure(
        transport_registry: LemonGateway.TransportRegistry,
        gateway_config: LemonGateway.Config
      )

  Each capability is a behaviour (`LemonCore.EngineInfoBridge.TransportRegistry`,
  `LemonCore.EngineInfoBridge.GatewayConfig`), and `configure/1` verifies the
  registered module against it with `LemonCore.Contract.validate/2`, so a
  configured capability is one the bridge can call directly.

  Every function answers `{:error, :unavailable}` (or the documented empty
  value) when its capability is unconfigured or its process is not running, so
  a runtime without a gateway still serves channel messages and ops queries.
  A configured capability that raises is a bug and is logged as such before
  the degraded answer is returned.
  """

  alias LemonCore.Contract

  require Logger

  @bridge_key :engine_info_bridge
  @capabilities [
    transport_registry: LemonCore.EngineInfoBridge.TransportRegistry,
    gateway_config: LemonCore.EngineInfoBridge.GatewayConfig
  ]
  @config_keys Keyword.keys(@capabilities)

  @type capability :: :transport_registry | :gateway_config
  @type config :: %{optional(capability()) => module()}

  @doc """
  Registers implementation modules. Unspecified capabilities are left alone.

  A module that does not implement its capability's behaviour is rejected as
  `{:error, {:invalid_implementation, capability, reason}}` and nothing changes.
  """
  @spec configure(keyword()) :: :ok | {:error, term()}
  def configure(opts) when is_list(opts) do
    incoming = opts |> Enum.into(%{}) |> Map.take(@config_keys)

    with :ok <- validate(incoming) do
      Application.put_env(:lemon_core, @bridge_key, Map.merge(current_config(), incoming))
      :ok
    end
  end

  @doc "Current bridge configuration."
  @spec config() :: config()
  def config, do: current_config()

  @doc "The module registered for `capability`, or `nil`."
  @spec impl(capability()) :: module() | nil
  def impl(capability) when capability in @config_keys do
    case Map.get(current_config(), capability) do
      module when is_atom(module) and not is_nil(module) -> module
      _ -> nil
    end
  end

  @doc "Whether a capability is configured (and therefore validated)."
  @spec available?(capability()) :: boolean()
  def available?(capability), do: impl(capability) != nil

  @doc "Whether the process behind `capability` is alive."
  @spec running?(capability()) :: boolean()
  def running?(capability) do
    case impl(capability) do
      nil -> false
      module -> is_pid(Process.whereis(module))
    end
  end

  @doc "Transport ids the gateway runtime has configured."
  @spec list_transports() :: {:ok, [term()]} | {:error, :unavailable}
  def list_transports, do: registry_call(:list_transports, [])

  @doc "Enabled transports as `{id, module}` pairs."
  @spec enabled_transports() :: {:ok, [{term(), module()}]} | {:error, :unavailable}
  def enabled_transports, do: registry_call(:enabled_transports, [])

  @doc "The module implementing a transport id."
  @spec get_transport(term()) :: {:ok, module()} | {:error, :unavailable}
  def get_transport(id), do: registry_call(:get_transport, [id])

  @doc """
  A full-replacement gateway config map, or `:none`.

  The gateway runtime may hold a config that replaces the canonical one
  wholesale (used by tests and by embedders that drive the gateway directly).
  """
  @spec gateway_config() :: {:ok, map()} | :none
  def gateway_config do
    case impl(:gateway_config) do
      nil -> :none
      module -> normalize_config(module.replacement_config())
    end
  rescue
    exception ->
      Logger.error(
        "EngineInfoBridge gateway_config raised: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      :none
  catch
    :exit, reason ->
      Logger.warning("EngineInfoBridge gateway_config unavailable: #{inspect(reason)}")
      :none
  end

  defp registry_call(function, args) do
    case impl(:transport_registry) do
      nil ->
        {:error, :unavailable}

      module ->
        if is_pid(Process.whereis(module)) do
          {:ok, apply(module, function, args)}
        else
          {:error, :unavailable}
        end
    end
  rescue
    exception ->
      Logger.error(
        "EngineInfoBridge #{function}/#{length(args)} raised: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      {:error, :unavailable}
  catch
    :exit, reason ->
      Logger.warning(
        "EngineInfoBridge #{function}/#{length(args)} unavailable: #{inspect(reason)}"
      )

      {:error, :unavailable}
  end

  defp normalize_config(config) when is_map(config), do: {:ok, config}

  defp normalize_config(config) when is_list(config) do
    if Keyword.keyword?(config) do
      {:ok, Enum.into(config, %{})}
    else
      {:ok, %{bindings: config}}
    end
  end

  defp normalize_config(_config), do: :none

  defp validate(incoming) do
    Enum.reduce_while(incoming, :ok, fn {capability, module}, :ok ->
      case Contract.validate(module, Keyword.fetch!(@capabilities, capability)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:invalid_implementation, capability, reason}}}
      end
    end)
  end

  defp current_config do
    case Application.get_env(:lemon_core, @bridge_key, %{}) do
      config when is_map(config) -> Map.take(config, @config_keys)
      _ -> %{}
    end
  end
end
