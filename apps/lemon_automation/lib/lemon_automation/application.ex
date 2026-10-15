defmodule LemonAutomation.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Task.Supervisor, name: LemonAutomation.TaskSupervisor},
        LemonAutomation.CronManager
      ] ++
        daily_brief_sync() ++
        [
          LemonAutomation.GoalContinuationManager,
          LemonAutomation.GoalLoopManager,
          LemonAutomation.KanbanDispatcher,
          LemonAutomation.SkillCuratorManager,
          LemonAutomation.SynthesisRunnerManager
        ]

    opts = [strategy: :one_for_one, name: LemonAutomation.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      LemonSkills.CuratorReferences.register(LemonAutomation.CuratorReferences, pid)
      register_tools()
      {:ok, pid}
    end
  end

  # The cron tool is contributed to the platform's runtime tool registry rather
  # than named by the gateway or coding agent, so builds without this app never
  # offer it. `LemonAgent.ToolRegistry` is a dependency of this app, so no
  # presence guard is needed.
  defp register_tools do
    LemonAgent.ToolRegistry.register(:cron, LemonAutomation.Tools.Cron)
  end

  # Reconcile the opt-in `[automation] daily_brief` job once CronManager is up.
  defp daily_brief_sync do
    if Application.get_env(:lemon_automation, :daily_brief_sync, true) do
      [
        Supervisor.child_spec(
          {Task, &LemonAutomation.Heartbeat.sync_daily_brief/0},
          id: :daily_brief_sync
        )
      ]
    else
      []
    end
  end
end
