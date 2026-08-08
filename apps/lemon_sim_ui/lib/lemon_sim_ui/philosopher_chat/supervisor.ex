defmodule LemonSimUi.PhilosopherChat.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(_opts), do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_opts) do
    ai_concurrency = Application.get_env(:lemon_sim_ui, :philosopher_chat_ai_concurrency, 4)

    children = [
      {Registry, keys: :unique, name: LemonSimUi.PhilosopherChat.Registry},
      {DynamicSupervisor,
       name: LemonSimUi.PhilosopherChat.ThreadSupervisor, strategy: :one_for_one},
      {Task.Supervisor,
       name: LemonSimUi.PhilosopherChat.AiTaskSupervisor, max_children: ai_concurrency},
      LemonSimUi.PhilosopherChat
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
