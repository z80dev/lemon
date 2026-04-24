defmodule LemonChannels.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      # Plugin registry
      LemonChannels.Registry,
      # Channels-owned delivery presentation state (message ids / send-vs-edit)
      LemonChannels.PresentationState,
      # Rate limiter
      LemonChannels.Outbox.RateLimiter,
      # Dedupe
      LemonChannels.Outbox.Dedupe,
      # Outbox worker supervisor (tasks)
      {Task.Supervisor, name: LemonChannels.Outbox.WorkerSupervisor},
      # Outbox
      LemonChannels.Outbox,
      # Adapter supervisor for channel adapters
      {DynamicSupervisor, strategy: :one_for_one, name: LemonChannels.AdapterSupervisor}
    ]

    opts = [strategy: :one_for_one, name: LemonChannels.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # Register and start built-in adapters after startup
        register_and_start_adapters()
        {:ok, pid}

      error ->
        error
    end
  end

  defp configured_adapters do
    Application.get_env(:lemon_channels, :adapters, [])
  end

  defp register_and_start_adapters do
    Enum.each(configured_adapters(), &register_and_start_configured_adapter/1)

    :ok
  end

  defp register_and_start_configured_adapter({adapter_module, opts})
       when is_atom(adapter_module) and is_list(opts) do
    log_adapter_start(adapter_module, register_and_start_adapter(adapter_module, opts))
  end

  defp register_and_start_configured_adapter(adapter_module) when is_atom(adapter_module) do
    log_adapter_start(adapter_module, register_and_start_adapter(adapter_module))
  end

  defp register_and_start_configured_adapter(other) do
    Logger.warning("Ignoring invalid lemon_channels adapter config: #{inspect(other)}")
  end

  defp log_adapter_start(adapter_module, :ok) do
    Logger.info("#{inspect(adapter_module)} adapter registered and started")
  end

  defp log_adapter_start(adapter_module, {:error, reason}) do
    Logger.warning("Failed to start #{inspect(adapter_module)} adapter: #{inspect(reason)}")
  end

  @doc """
  Register and start a channel adapter.

  This function:
  1. Registers the adapter plugin with the Registry
  2. Starts the adapter's child_spec under the AdapterSupervisor
  """
  @spec register_and_start_adapter(module(), keyword()) :: :ok | {:error, term()}
  def register_and_start_adapter(adapter_module, opts \\ []) do
    # Register the plugin
    case LemonChannels.Registry.register(adapter_module) do
      :ok ->
        start_adapter(adapter_module, opts)

      {:error, :already_registered} ->
        # Already registered, just try to start
        start_adapter(adapter_module, opts)

      error ->
        error
    end
  end

  @doc """
  Start an adapter under the AdapterSupervisor.
  """
  @spec start_adapter(module(), keyword()) :: :ok | {:error, term()}
  def start_adapter(adapter_module, opts \\ []) do
    child_spec = adapter_module.child_spec(opts)

    case DynamicSupervisor.start_child(LemonChannels.AdapterSupervisor, child_spec) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      :ignore -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Stop an adapter.
  """
  @spec stop_adapter(module()) :: :ok | {:error, term()}
  def stop_adapter(adapter_module) do
    case find_adapter_pid(adapter_module) do
      nil ->
        {:error, :not_running}

      pid ->
        DynamicSupervisor.terminate_child(LemonChannels.AdapterSupervisor, pid)
    end
  end

  defp find_adapter_pid(adapter_module) when is_atom(adapter_module) do
    expected_child_module =
      case adapter_module.child_spec([]) do
        %{start: {module, _func, _args}} when is_atom(module) -> module
        _ -> nil
      end

    # Search for the adapter in the supervisor children
    children = DynamicSupervisor.which_children(LemonChannels.AdapterSupervisor)

    Enum.find_value(children, fn
      {_id, pid, _type, modules} when is_pid(pid) and is_list(modules) ->
        if Enum.member?(modules, adapter_module) or
             (is_atom(expected_child_module) and Enum.member?(modules, expected_child_module)) do
          pid
        else
          nil
        end

      _ ->
        nil
    end)
  end
end
