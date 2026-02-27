defmodule LemonGames.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        LemonGames.Matches.DeadlineSweeper
      ] ++ maybe_autoplay_children()

    opts = [strategy: :one_for_one, name: LemonGames.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_autoplay_children do
    autoplay = Application.get_env(:lemon_games, :autoplay, [])

    if Keyword.get(autoplay, :enabled, false) do
      [
        {LemonGames.Bot.LobbySeeder,
         [
           interval_ms: Keyword.get(autoplay, :interval_ms, 15_000),
           target_active_matches: Keyword.get(autoplay, :target_active_matches, 3),
           games: Keyword.get(autoplay, :games, ["connect4", "rock_paper_scissors"]),
           house_agent_id: Keyword.get(autoplay, :house_agent_id, "house")
         ]}
      ]
    else
      []
    end
  end
end
