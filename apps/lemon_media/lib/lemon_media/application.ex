defmodule LemonMedia.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      LemonMedia.MediaJobSupervisor
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: LemonMedia.Supervisor)
  end
end
