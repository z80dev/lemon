defmodule LemonAutomation.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # The tables this app owns get their retention from the store's sweep.
    LemonCore.Store.Table.register(LemonAutomation.CronStore)

    children = [
      {Task.Supervisor, name: LemonAutomation.TaskSupervisor},
      LemonAutomation.CronManager,
      LemonAutomation.HeartbeatManager,
      LemonAutomation.GoalContinuationManager,
      LemonAutomation.GoalLoopManager,
      LemonAutomation.KanbanDispatcher,
      LemonAutomation.SkillCuratorManager,
      LemonAutomation.SynthesisRunnerManager
    ]

    opts = [strategy: :one_for_one, name: LemonAutomation.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
