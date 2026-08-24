defmodule LemonCore.EngineInfoBridge do
  @moduledoc """
  Optional bridge to the gateway runtime, without compile-time coupling.

  Channels and the control plane use the gateway runtime
  (`:lemon_gateway` in the reference runtime) for transport-registry ops
  introspection and any full-replacement gateway config it holds. Before this
  bridge each caller reached back with a hardcoded `:"Elixir.LemonGateway.*"`
  atom; now the gateway configures itself here at boot and callers ask core.

  This is `LemonCore.RouterBridge`'s pattern pointed the other way: a
  configured implementation module per capability, runtime dispatch, and a
  documented degraded answer when nothing is configured.

      LemonCore.EngineInfoBridge.configure(
        transport_registry: LemonGateway.TransportRegistry,
        gateway_config: LemonGateway.Config
      )

  Every function answers `{:error, :unavailable}` (or the documented empty
  value) when its capability is unconfigured, unloadable, or not running, so a
  runtime without a gateway still serves channel messages and ops queries.
  """

  @bridge_key :engine_info_bridge
  @config_keys [:transport_registry, :gateway_config]

  @type capability :: :transport_registry | :gateway_config
  @type config :: %{optional(capability()) => module()}

  @doc """
  Registers implementation modules. Unspecified capabilities are left alone.
  """
  @spec configure(keyword()) :: :ok | {:error, term()}
  def configure(opts) when is_list(opts) do
    incoming = opts |> Enum.into(%{}) |> Map.take(@config_keys)

    if Enum.all?(incoming, fn {_key, module} -> is_atom(module) end) do
      Application.put_env(:lemon_core, @bridge_key, Map.merge(current_config(), incoming))
      :ok
    else
      {:error, :invalid_config}
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

  @doc "Whether a capability is configured and loadable."
  @spec available?(capability()) :: boolean()
  def available?(capability) do
    case impl(capability) do
      nil -> false
      module -> Code.ensure_loaded?(module)
    end
  end

  @doc "Whether the process behind `capability` is alive."
  @spec running?(capability()) :: boolean()
  def running?(capability) do
    case impl(capability) do
      nil -> false
      module -> Code.ensure_loaded?(module) and is_pid(Process.whereis(module))
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
      nil ->
        :none

      module ->
        if Code.ensure_loaded?(module) and function_exported?(module, :replacement_config, 0) do
          normalize_config(apply(module, :replacement_config, []))
        else
          :none
        end
    end
  rescue
    _ -> :none
  catch
    :exit, _ -> :none
  end

  defp registry_call(function, args) do
    if running?(:transport_registry) do
      case call(:transport_registry, function, args, :unavailable) do
        :unavailable -> {:error, :unavailable}
        value -> {:ok, value}
      end
    else
      {:error, :unavailable}
    end
  end

  defp call(capability, function, args, fallback) do
    module = impl(capability)

    if is_atom(module) and Code.ensure_loaded?(module) and
         function_exported?(module, function, length(args)) do
      apply(module, function, args)
    else
      fallback
    end
  rescue
    _ -> fallback
  catch
    :exit, _ -> fallback
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

  defp current_config do
    case Application.get_env(:lemon_core, @bridge_key, %{}) do
      config when is_map(config) -> Map.take(config, @config_keys)
      _ -> %{}
    end
  end
end
