defmodule LemonChannels.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    # Build list of children, including Discord consumer early if enabled
    discord_children = 
      if discord_enabled?() do
        Logger.info("Discord adapter enabled, starting consumer")
        config = get_discord_config()
        [{LemonChannels.Adapters.Discord.Consumer, config}]
      else
        []
      end

    children = [
      # Plugin registry
      LemonChannels.Registry,
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
    ] ++ discord_children

    opts = [strategy: :one_for_one, name: LemonChannels.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # Register and start built-in adapters after startup (except Discord which started above)
        register_and_start_adapters()
        {:ok, pid}

      error ->
        error
    end
  end

  defp discord_enabled? do
    Application.get_env(:lemon_gateway, :enable_discord, false) == true
  end

  defp get_discord_config do
    base = Application.get_env(:lemon_gateway, :discord) || %{}
    if is_list(base), do: Enum.into(base, %{}), else: base
  end

  defp register_and_start_adapters do
    # Register Telegram adapter if configured
    if LemonChannels.GatewayConfig.get(:enable_telegram, false) == true do
      case register_and_start_adapter(LemonChannels.Adapters.Telegram) do
        :ok ->
          Logger.info("Telegram adapter registered and started")

        {:error, reason} ->
          Logger.warning("Failed to start Telegram adapter: #{inspect(reason)}")
      end
    end

    # Discord adapter is started directly in the supervision tree (above)
    # Just register it with the plugin registry if enabled
    if discord_enabled?() do
      Logger.debug("Discord enabled, registering adapter...")
      case LemonChannels.Registry.register(LemonChannels.Adapters.Discord) do
        :ok -> Logger.info("Discord adapter registered")
        {:error, :already_registered} -> Logger.info("Discord adapter already registered")
        error -> Logger.warning("Failed to register Discord adapter: #{inspect(error)}")
      end
    else
      Logger.debug("Discord not enabled, skipping registration")
    end

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

    enabled? =
      case adapter_id do
        "telegram" -> LemonChannels.GatewayConfig.get(:enable_telegram, false) == true
        "discord" -> LemonChannels.GatewayConfig.get(:enable_discord, false) == true
        _ -> true
      end

    if enabled? do
      merged_opts = opts

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
    case find_adapter_pid(adapter_module) do
      nil ->
        {:error, :not_running}

      pid ->
        DynamicSupervisor.terminate_child(LemonChannels.AdapterSupervisor, pid)
    end
  end

  defp find_adapter_pid(adapter_module) when is_atom(adapter_module) do
    # Search for the adapter in the supervisor children
    children = DynamicSupervisor.which_children(LemonChannels.AdapterSupervisor)

    Enum.find_value(children, fn
      {^adapter_module, pid, _type, _modules} when is_pid(pid) ->
        pid

      _ ->
        nil
    end)
  end
end
