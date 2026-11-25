defmodule LemonAutomation.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        LemonCore.TaskSupervisor.child_spec(name: LemonAutomation.TaskSupervisor),
        LemonAutomation.CronManager,
        LemonAutomation.GoalLoopManager,
        LemonAutomation.KanbanDispatcher,
        LemonAutomation.SkillCuratorManager,
        LemonAutomation.SynthesisRunnerManager
      ]

    opts = [strategy: :one_for_one, name: LemonAutomation.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      LemonSkills.CuratorReferences.register(LemonAutomation.CuratorReferences, pid)
      register_tools()
      :ok = LemonCore.AutomationCommands.register(LemonAutomation.ChatCommands)

      :ok =
        LemonCore.SessionLifecycle.Participant.register(
          :goals,
          LemonAutomation.GoalSessionParticipant
        )

      {:ok, pid}
    end
  end

  # The cron, kanban and goal tools are contributed to the platform's runtime
  # tool registry rather than named by the gateway or coding agent, so builds
  # without this app never offer them. `LemonAgent.ToolRegistry` is a
  # dependency of this app, so no presence guard is needed. Their native work
  # goes through the managed launch seams.
  @tools [
    cron: LemonAutomation.Tools.Cron,
    kanban: LemonAutomation.Tools.Kanban,
    goal: LemonAutomation.Tools.Goal
  ]

  defp register_tools do
    Enum.each(@tools, fn {name, module} ->
      LemonAgent.ToolRegistry.register(name, module, native_process_ownership: :managed)
    end)
  end
end
