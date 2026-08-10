defmodule CodingAgent.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    lane_caps =
      Application.get_env(:coding_agent, :lane_caps, %{
        main: 4,
        subagent: 8,
        background_exec: 2
      })

    task_max_concurrency =
      Application.get_env(
        :coding_agent,
        :task_max_concurrency,
        CodingAgent.Parallel.default_max_concurrency()
      )

    children = [
      {Registry, keys: :unique, name: CodingAgent.SessionRegistry},
      {Registry, keys: :unique, name: CodingAgent.ProcessRegistry},
      {Registry, keys: :unique, name: CodingAgent.RateLimitHealerRegistry},
      CodingAgent.Tools.TodoStoreOwner,
      CodingAgent.SessionSupervisor,
      CodingAgent.Wasm.SidecarSupervisor,
      CodingAgent.Tools.Task.LiveBridgeSupervisor,
      {Task.Supervisor, name: CodingAgent.TaskSupervisor},
      {CodingAgent.TaskStoreServer, name: CodingAgent.TaskStoreServer},
      {CodingAgent.TaskProgressBindingServer, name: CodingAgent.TaskProgressBindingServer},
      {CodingAgent.ParentQuestionStoreServer, name: CodingAgent.ParentQuestionStoreServer},
      {CodingAgent.RunGraphServer, name: CodingAgent.RunGraphServer},
      {CodingAgent.ProcessStoreServer, name: CodingAgent.ProcessStoreServer},
      {CodingAgent.ProcessManager, name: CodingAgent.ProcessManager},
      {CodingAgent.LaneQueue,
       name: CodingAgent.LaneQueue, caps: lane_caps, task_supervisor: CodingAgent.TaskSupervisor},
      {CodingAgent.Parallel.Semaphore,
       max: task_max_concurrency, name: CodingAgent.TaskSemaphore},
      {CodingAgent.CompactionHooks, name: CodingAgent.CompactionHooks},
      CodingAgent.ProviderPoolRotator
    ]

    opts = [strategy: :one_for_one, name: CodingAgent.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, _supervisor} = ok ->
        register_gateway_engine()
        maybe_start_primary_session()
        ok

      other ->
        other
    end
  end

  # The gateway owns the engine registry but must not depend on this app, so we
  # contribute the "lemon" engine from here. A runtime without lemon_gateway
  # (or with the registry not yet started) simply has no such engine.
  defp register_gateway_engine do
    if Code.ensure_loaded?(LemonGateway.EngineRegistry) do
      case LemonGateway.EngineRegistry.register(CodingAgent.GatewayEngine) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.debug("lemon gateway engine not registered: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  defp maybe_start_primary_session do
    case Application.get_env(:coding_agent, :primary_session) do
      nil ->
        :ok

      opts when is_list(opts) ->
        case CodingAgent.SessionSupervisor.start_session(opts) do
          {:ok, _pid} ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to start primary session: #{inspect(reason)}")
        end

      other ->
        Logger.warning("Invalid :primary_session config: #{inspect(other)}")
    end
  end
end
