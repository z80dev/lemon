defmodule LemonAi.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(children) do
    Supervisor.start_link(__MODULE__, children, name: __MODULE__)
  end

  @impl true
  def init(children) do
    LemonAi.CallDispatcher.Slots.init_table()
    Supervisor.init(children, strategy: :one_for_one)
  end
end
