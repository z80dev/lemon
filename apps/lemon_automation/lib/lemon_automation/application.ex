defmodule LemonAutomation.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Task.Supervisor, name: LemonAutomation.TaskSupervisor},
        LemonAutomation.CronManager,
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
    LemonAgent.ToolRegistry.register(:cron, LemonAutomation.Tools.Cron,
      native_process_ownership: :managed
    )
  end
end
