defmodule LemonLsp.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      LemonLsp.ServerManager
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: LemonLsp.Supervisor)
  end
end
