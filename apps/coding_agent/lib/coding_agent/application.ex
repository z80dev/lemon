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
      # one_for_all Python REPL subsystem (session supervisor + registry).
      # Must start after TaskSupervisor: per-cell RPC servers started for
      # REPL workers depend on it.
      CodingAgent.PythonRepl.Supervisor,
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
      {CodingAgent.CompactionHooks, name: CodingAgent.CompactionHooks}
    ]

    opts = [strategy: :one_for_one, name: CodingAgent.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, _supervisor} = ok ->
        register_gateway_engine()
        register_subagent_runner()
        register_control_plane_provider()
        maybe_start_primary_session()
        ok

      other ->
        other
    end
  end

  # The gateway owns the engine registry but must not depend on this app, so we
  # contribute the "lemon" engine from here. A runtime without lemon_gateway
  # (or with the registry not yet started) simply has no such engine.
  #
  # register_default/1, not register/1: this is boot auto-registration by an
  # installed package, and an operator-configured :lemon_gateway, :engines list
  # is a ceiling that must hold for every boot registrant — the lemon engine
  # gets no special pass the vendor engines don't get. An operator who wants it
  # alongside a narrowed list adds CodingAgent.GatewayEngine to the list.
  defp register_gateway_engine do
    if Code.ensure_loaded?(LemonGateway.EngineRegistry) do
      case LemonGateway.EngineRegistry.register_default(CodingAgent.GatewayEngine) do
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

  # Same shape one layer down: lemon_core owns the subagent registry the task
  # tool reads, and this app contributes the in-process ("internal") runner.
  # Vendor CLIs contribute theirs from lemon_cli_runners, which is why nothing
  # here names one.
  defp register_subagent_runner do
    case LemonCore.SubagentRegistry.register(CodingAgent.CliRunners.LemonSubagent) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.debug("internal subagent runner not registered: #{inspect(reason)}")
        :ok
    end
  end

  # The control plane introspects this agent through a registered provider. The
  # call is indirect (module in a variable) so this app keeps no compile-time
  # reference to the reference runtime and stays extractable without it.
  defp register_control_plane_provider do
    runtime = Module.concat(["LemonControlPlane", "AgentRuntime"])

    if Code.ensure_loaded?(runtime) and function_exported?(runtime, :register, 1) do
      case apply(runtime, :register, [CodingAgent.ControlPlaneProvider]) do
        :ok ->
          :ok

        other ->
          Logger.debug("control plane provider not registered: #{inspect(other)}")
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
