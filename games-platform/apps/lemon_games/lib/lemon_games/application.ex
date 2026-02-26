defmodule LemonGames.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      LemonGames.Matches.DeadlineSweeper
    ]

    opts = [strategy: :one_for_one, name: LemonGames.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
