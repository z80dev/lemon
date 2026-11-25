defmodule LemonCore.EngineInfoBridge do
  @moduledoc """
  Optional bridge to the gateway runtime, without compile-time coupling.

  Channels and the control plane use the gateway runtime
  (`:lemon_gateway` in the reference runtime) for transport-registry ops
  introspection and SMS inbox operations. Before this
  bridge each caller reached back with a hardcoded `:"Elixir.LemonGateway.*"`
  atom; now the gateway configures itself here at boot and callers ask core.

  This is `LemonCore.RouterBridge`'s pattern pointed the other way: a
  configured implementation module per capability, runtime dispatch, and a
  documented degraded answer when nothing is configured.

      LemonCore.EngineInfoBridge.configure(
        transport_registry: LemonGateway.TransportRegistry,
        sms_inbox: LemonGateway.Sms.Inbox
      )

  Every function answers `{:error, :unavailable}` (or the documented empty
  value) when its capability is unconfigured, unloadable, or not running, so a
  runtime without a gateway still serves channel messages and ops queries.
  """

  @bridge_key :engine_info_bridge
  @config_keys [:transport_registry, :sms_inbox]

  @type capability :: :transport_registry | :sms_inbox
  @type config :: %{optional(capability()) => module()}

  @doc """
  Registers implementation modules. Unspecified capabilities are left alone.
  """
  @spec configure(keyword()) :: :ok | {:error, term()}
  def configure(opts) when is_list(opts) do
    roles = Enum.map(@config_keys, &{&1, :module})

    case LemonCore.RuntimeSeam.configure(@bridge_key, opts, roles, :merge) do
      :ok -> :ok
      {:error, _} -> {:error, :invalid_config}
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
    LemonCore.RuntimeSeam.available?(impl(capability))
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
  Operator preview of a forced SMS inbox clear: the current holder and a
  single-use confirm token bound to it (see `LemonGateway.Sms.Inbox.preview_clear/0`).
  """
  @spec sms_inbox_preview_clear() :: {:ok, map()} | {:error, term()}
  def sms_inbox_preview_clear, do: sms_inbox_call(:preview_clear, [])

  @doc """
  Confirms a previewed SMS inbox clear for the exact holder. A raise, exit or
  throw after the call was reached is `{:error, :outcome_unknown}`: the clear
  may have happened.
  """
  @spec sms_inbox_confirm_clear(binary(), binary()) :: :ok | {:error, term()}
  def sms_inbox_confirm_clear(holder, token),
    do:
      sms_inbox_call(:confirm_clear, [holder, token],
        exception: {:error, :outcome_unknown},
        exit: {:error, :outcome_unknown},
        throw: {:error, :outcome_unknown}
      )

  defp sms_inbox_call(function, args, opts \\ []) do
    if running?(:sms_inbox) do
      LemonCore.RuntimeSeam.invoke(
        impl(:sms_inbox),
        function,
        args,
        Keyword.merge([unavailable: {:error, :unavailable}], opts)
      )
    else
      {:error, :unavailable}
    end
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
    LemonCore.RuntimeSeam.invoke(impl(capability), function, args, unavailable: fallback)
  end

  defp current_config, do: LemonCore.RuntimeSeam.config(@bridge_key, @config_keys)
end
