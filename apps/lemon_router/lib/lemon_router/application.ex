defmodule LemonRouter.Application do
  @moduledoc false

  use Application
  require Logger

  @default_run_process_limit 500

  @impl true
  def start(_type, _args) do
    children =
      [
        # Agent profiles configuration
        LemonRouter.AgentProfiles,
        # Registries
        {Registry, keys: :unique, name: LemonRouter.RunRegistry},
        # Strict single-flight: at most one *active* run per session_key.
        {Registry, keys: :unique, name: LemonRouter.SessionRegistry},
        # Coalescer registry - required for StreamCoalescer to work
        {Registry, keys: :unique, name: LemonRouter.CoalescerRegistry},
        # Tool status coalescer registry
        {Registry, keys: :unique, name: LemonRouter.ToolStatusRegistry},
        # Run supervisor (DynamicSupervisor for run processes)
        {
          DynamicSupervisor,
          strategy: :one_for_one,
          name: LemonRouter.RunSupervisor,
          max_children: run_process_limit()
        },
        # Stream coalescer supervisor
        {DynamicSupervisor, strategy: :one_for_one, name: LemonRouter.CoalescerSupervisor},
        # Tool status coalescer supervisor
        {DynamicSupervisor, strategy: :one_for_one, name: LemonRouter.ToolStatusSupervisor},
        # Run orchestrator
        LemonRouter.RunOrchestrator
      ] ++ maybe_health_server_child()

    opts = [strategy: :one_for_one, name: LemonRouter.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        configure_router_bridge()
        {:ok, pid}

      other ->
        other
    end
  end

  defp maybe_health_server_child do
    if health_enabled?() do
      [health_server_child_spec()]
    else
      []
    end
  end

  defp health_server_child_spec do
    port = Application.get_env(:lemon_router, :health_port, default_health_port())
    ip = Application.get_env(:lemon_router, :health_ip, :loopback)

    %{
      id: LemonRouter.Health.Server,
      start:
        {Bandit, :start_link,
         [[plug: LemonRouter.Health.Router, ip: ip, port: port, scheme: :http]]},
      type: :supervisor
    }
  end

  defp health_enabled? do
    Application.get_env(:lemon_router, :health_enabled, true)
  end

  defp configure_router_bridge do
    # Configure only after router processes are started to avoid startup-order races.
    case LemonCore.RouterBridge.configure_guarded(
           run_orchestrator: LemonRouter.RunOrchestrator,
           router: LemonRouter.Router
         ) do
      :ok ->
        :ok

      {:error, {:already_configured, key, existing, incoming}} ->
        Logger.warning(
          "RouterBridge already configured for #{inspect(key)} with #{inspect(existing)}; keeping existing value and ignoring #{inspect(incoming)}"
        )

      {:error, reason} ->
        Logger.warning("RouterBridge guarded configure failed: #{inspect(reason)}")
    end
  end

  defp run_process_limit do
    case Application.get_env(:lemon_router, :run_process_limit, @default_run_process_limit) do
      :infinity ->
        :infinity

      value when is_integer(value) and value > 0 ->
        value

      _ ->
        @default_run_process_limit
    end
  end

  defp default_health_port do
    if Code.ensure_loaded?(Mix) and Mix.env() == :test do
      0
    else
      4043
    end
  end
end
