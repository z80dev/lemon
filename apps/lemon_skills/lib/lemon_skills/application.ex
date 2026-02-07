defmodule LemonSkills.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Ensure ~/.lemon/agent/skill exists before the registry loads from disk.
    LemonSkills.Config.ensure_dirs!()

    children = [
      LemonSkills.Registry
    ]

    opts = [strategy: :one_for_one, name: LemonSkills.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
