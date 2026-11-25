defmodule CodingAgent.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    CodingAgent.StatePaths.prepare_default_layout()

    lane_caps =
      Application.get_env(:coding_agent, :lane_caps, %{
        background_exec: 2
      })

    task_max_concurrency =
      Application.get_env(
        :coding_agent,
        :task_max_concurrency,
        8
      )

    background_max_concurrency =
      Application.get_env(:coding_agent, :background_run_max_concurrency, 8)

    children = [
      CodingAgent.RuntimeTables,
      LemonCore.Supervision.subtree(CodingAgent.ToolResourceSupervisor, [
        {Registry, keys: :unique, name: CodingAgent.Eval.Registry},
        {Registry, keys: :unique, name: CodingAgent.Tools.Lsp.Registry},
        {Registry, keys: :unique, name: CodingAgent.Debug.Registry},
        CodingAgent.Eval.KernelSupervisor,
        {DynamicSupervisor, name: CodingAgent.Tools.Lsp.Supervisor, strategy: :one_for_one},
        # Bounds debug servers (roots plus adapter-requested descendants).
        {DynamicSupervisor,
         name: CodingAgent.Debug.Supervisor, strategy: :one_for_one, max_children: 256},
        CodingAgent.ToolResources
      ]),
      LemonCore.Supervision.subtree(CodingAgent.Search.Supervisor, [
        {LemonCore.TaskSupervisor, name: CodingAgent.Search.TaskSupervisor},
        CodingAgent.Search.SingleFlight
      ]),
      CodingAgent.Tools.Bash.ShellState,
      CodingAgent.Session.UserPrompt,
      CodingAgent.MutationLock,
      CodingAgent.FileReadTracker,
      CodingAgent.WorkspaceReads,
      CodingAgent.ConflictStore,
      CodingAgent.ExecutionNode.FileService,
      CodingAgent.ExecutionNode.ProcessService,
      LemonCore.Supervision.subtree(CodingAgent.ExecutionNode.ToolSession.Tree, [
        {Registry, keys: :unique, name: CodingAgent.ExecutionNode.ToolSession.Registry},
        {DynamicSupervisor,
         name: CodingAgent.ExecutionNode.ToolSession.Supervisor, strategy: :one_for_one}
      ]),
      {LemonCore.TaskSupervisor, name: CodingAgent.TaskSupervisor},
      {CodingAgent.TaskStoreServer, name: CodingAgent.TaskStoreServer},
      CodingAgent.AsyncFollowups,
      CodingAgent.TaskRuntime,
      CodingAgent.Tools.Task.Speculation,
      {CodingAgent.TaskProgressBindingServer, name: CodingAgent.TaskProgressBindingServer},
      {CodingAgent.ParentQuestionStoreServer, name: CodingAgent.ParentQuestionStoreServer},
      {CodingAgent.RunGraphServer, name: CodingAgent.RunGraphServer},
      # rest_for_one: ProcessManager (and its sessions) precede the store, so
      # a store restart never stops a running command's process group.
      LemonCore.Supervision.subtree(CodingAgent.ProcessSupervisor, [
        {Registry, keys: :unique, name: CodingAgent.ProcessRegistry},
        {CodingAgent.ProcessManager, name: CodingAgent.ProcessManager},
        {CodingAgent.ProcessStoreServer, name: CodingAgent.ProcessStoreServer},
        {CodingAgent.LaneQueue,
         name: CodingAgent.LaneQueue, caps: lane_caps, task_supervisor: CodingAgent.TaskSupervisor}
      ]),
      LemonCore.Supervision.subtree(CodingAgent.SessionTree, [
        {Registry, keys: :unique, name: CodingAgent.SessionRegistry},
        CodingAgent.SessionSupervisor
      ]),
      LemonCore.Supervision.subtree(CodingAgent.BackgroundRun.Tree, [
        {Registry, keys: :unique, name: CodingAgent.BackgroundRun.Registry},
        CodingAgent.BackgroundRun.Supervisor
      ]),
      {CodingAgent.Parallel.Semaphore,
       max: task_max_concurrency, name: CodingAgent.TaskSemaphore},
      %{
        id: CodingAgent.BackgroundRunSemaphore,
        start:
          {CodingAgent.Parallel.Semaphore, :start_link,
           [[max: background_max_concurrency, name: CodingAgent.BackgroundRunSemaphore]]}
      }
    ]

    opts = [strategy: :one_for_one, name: CodingAgent.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, _supervisor} = ok ->
        CodingAgent.Search.Registry.init()
        register_control_plane_provider()
        maybe_start_primary_session()
        ok

      other ->
        other
    end
  end

  # Runtime consumers reach this agent through the shared core registry.
  defp register_control_plane_provider do
    case LemonCore.AgentRuntime.register(CodingAgent.ControlPlaneProvider) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("agent runtime provider not registered: #{reason}")
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
