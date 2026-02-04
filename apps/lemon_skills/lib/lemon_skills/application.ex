defmodule LemonSkills.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      LemonSkills.Registry
    ]

    opts = [strategy: :one_for_one, name: LemonSkills.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
