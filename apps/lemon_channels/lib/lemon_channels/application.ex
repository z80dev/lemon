defmodule LemonChannels.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      # Plugin registry
      LemonChannels.Registry,
      # Outbox worker supervisor
      {DynamicSupervisor, strategy: :one_for_one, name: LemonChannels.Outbox.WorkerSupervisor},
      # Outbox
      LemonChannels.Outbox,
      # Rate limiter
      LemonChannels.Outbox.RateLimiter,
      # Dedupe
      LemonChannels.Outbox.Dedupe,
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

  defp register_and_start_adapters do
    # Register Telegram adapter if configured
    if Application.get_env(:lemon_channels, :telegram_enabled, true) do
      case register_and_start_adapter(LemonChannels.Adapters.Telegram) do
        :ok ->
          Logger.info("Telegram adapter registered and started")

        {:error, reason} ->
          Logger.warning("Failed to start Telegram adapter: #{inspect(reason)}")
      end
    end

    # Future: register other adapters here (Discord, Slack, etc.)
    :ok
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
    # Check if adapter is enabled
    adapter_id = adapter_module.id()
    enabled_key = String.to_atom("#{adapter_id}_enabled")

    if Application.get_env(:lemon_channels, enabled_key, true) do
      # Get adapter-specific options from config
      adapter_opts = Application.get_env(:lemon_channels, adapter_module, [])
      merged_opts = Keyword.merge(adapter_opts, opts)

      # Get the child spec from the adapter
      child_spec = adapter_module.child_spec(merged_opts)

      # Start under the adapter supervisor
      case DynamicSupervisor.start_child(LemonChannels.AdapterSupervisor, child_spec) do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      Logger.debug("Adapter #{adapter_id} is disabled, not starting")
      :ok
    end
  end

  @doc """
  Stop an adapter.
  """
  @spec stop_adapter(module()) :: :ok | {:error, term()}
  def stop_adapter(adapter_module) do
    # Find the adapter process
    adapter_id = adapter_module.id()

    case find_adapter_pid(adapter_id) do
      nil ->
        {:error, :not_running}

      pid ->
        DynamicSupervisor.terminate_child(LemonChannels.AdapterSupervisor, pid)
    end
  end

  defp find_adapter_pid(adapter_id) do
    # Search for the adapter in the supervisor children
    children = DynamicSupervisor.which_children(LemonChannels.AdapterSupervisor)

    Enum.find_value(children, fn
      {^adapter_id, pid, _type, _modules} when is_pid(pid) -> pid
      {_id, pid, _type, [module]} when is_pid(pid) ->
        if function_exported?(module, :id, 0) and module.id() == adapter_id do
          pid
        end
      _ -> nil
    end)
  end
end
