defmodule LemonAutomation.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      LemonAutomation.CronManager,
      LemonAutomation.HeartbeatManager
    ]

    opts = [strategy: :one_for_one, name: LemonAutomation.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
