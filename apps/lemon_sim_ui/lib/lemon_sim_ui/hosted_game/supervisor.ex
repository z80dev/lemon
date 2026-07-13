defmodule LemonSimUi.HostedGame.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(_opts), do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_opts) do
    ai_concurrency = Application.get_env(:lemon_sim_ui, :hosted_ai_concurrency, 4)

    children = [
      {Registry, keys: :unique, name: LemonSimUi.HostedGame.Registry},
      {DynamicSupervisor, name: LemonSimUi.HostedGame.RoomSupervisor, strategy: :one_for_one},
      {Task.Supervisor,
       name: LemonSimUi.HostedGame.AiTaskSupervisor, max_children: ai_concurrency},
      LemonSimUi.HostedGame
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
