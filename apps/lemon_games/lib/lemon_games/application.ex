defmodule LemonGames.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if enabled?() do
        [LemonGames.Matches.DeadlineSweeper | maybe_autoplay_children()]
      else
        []
      end

    opts = [strategy: :one_for_one, name: LemonGames.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp enabled? do
    Application.get_env(:lemon_games, :enabled, false)
  end

  defp maybe_autoplay_children do
    autoplay = Application.get_env(:lemon_games, :autoplay, [])

    if Keyword.get(autoplay, :enabled, false) do
      [{LemonGames.Bot.LobbySeeder, autoplay}]
    else
      []
    end
  end
end
