defmodule LemonGames.Bot.LobbySeeder do
  @moduledoc """
  Keeps the public lobby active by maintaining a baseline of house-vs-bot matches.

  The seeder performs two actions on each tick:
  1. Advance in-progress house turns (p1) for active house matches.
  2. Create new public house-vs-bot matches when active count is below target.
  """

  use GenServer

  alias LemonGames.Bot.TurnWorker
  alias LemonGames.Matches.Service

  @default_interval_ms 15_000
  @default_target_active_matches 3
  @default_games ["connect4", "rock_paper_scissors"]
  @default_house_agent_id "house"

  @type option ::
          {:interval_ms, pos_integer()}
          | {:target_active_matches, non_neg_integer()}
          | {:games, [String.t()]}
          | {:house_agent_id, String.t()}

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      target_active_matches:
        Keyword.get(opts, :target_active_matches, @default_target_active_matches),
      games: normalize_games(Keyword.get(opts, :games, @default_games)),
      house_agent_id: Keyword.get(opts, :house_agent_id, @default_house_agent_id)
    }

    schedule_seed(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:seed, state) do
    run_seed(state)
    schedule_seed(state.interval_ms)
    {:noreply, state}
  end

  defp run_seed(state) do
    house_matches = list_house_matches(state.house_agent_id)

    house_matches
    |> Enum.filter(&(&1["status"] == "active" and &1["next_player"] == "p1"))
    |> Enum.each(&play_house_turn(&1, state.house_agent_id))

    active_count = Enum.count(house_matches, &(&1["status"] == "active"))

    missing = max(state.target_active_matches - active_count, 0)

    if missing > 0 do
      Enum.each(1..missing, fn _ ->
        create_house_match(state.house_agent_id, state.games)
      end)
    end

    :ok
  end

  defp create_house_match(house_agent_id, games) do
    game_type = Enum.random(games)

    _ =
      Service.create_match(
        %{
          "game_type" => game_type,
          "opponent" => %{"type" => "lemon_bot", "bot_id" => "default"},
          "visibility" => "public"
        },
        %{"agent_id" => house_agent_id, "display_name" => "House"}
      )

    :ok
  end

  defp play_house_turn(match, house_agent_id) do
    game_type = match["game_type"]
    state = match["snapshot_state"]
    move = TurnWorker.choose_move_for(game_type, state, "p1")
    idempotency_key = "house_#{match["id"]}_#{match["turn_number"]}_p1"

    _ = Service.submit_move(match["id"], %{"agent_id" => house_agent_id}, move, idempotency_key)
    :ok
  end

  defp list_house_matches(house_agent_id) do
    :game_matches
    |> LemonCore.Store.list()
    |> Enum.map(fn {_id, match} -> match end)
    |> Enum.filter(fn match ->
      match["visibility"] == "public" and
        get_in(match, ["players", "p1", "agent_id"]) == house_agent_id and
        get_in(match, ["players", "p2", "agent_type"]) == "lemon_bot"
    end)
  end

  defp normalize_games([]), do: @default_games

  defp normalize_games(games) do
    case Enum.filter(games, &is_binary/1) do
      [] -> @default_games
      valid -> valid
    end
  end

  defp schedule_seed(interval_ms) do
    Process.send_after(self(), :seed, interval_ms)
  end
end
