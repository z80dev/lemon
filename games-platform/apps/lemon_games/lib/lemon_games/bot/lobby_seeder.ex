defmodule LemonGames.Bot.LobbySeeder do
  @moduledoc """
  Keeps the public lobby populated by creating and advancing house-run bot matches.

  When enabled, this worker periodically:

  1. Advances active house matches where it's house (`p1`) turn.
  2. Creates additional house-vs-bot matches if active match count is below target.

  This gives spectators a steady stream of games without requiring external agents.
  """

  use GenServer

  require Logger

  alias LemonGames.Bot.TurnWorker
  alias LemonGames.Matches.Service

  @default_interval_ms 10_000
  @default_max_active_matches 3
  @default_house_agent_id "lemon_house"
  @default_game_types ["rock_paper_scissors", "connect4"]

  @type run_opts :: [
          interval_ms: pos_integer(),
          max_active_matches: non_neg_integer(),
          house_agent_id: String.t(),
          game_types: [String.t()]
        ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)
    state = %{opts: opts, interval_ms: interval_ms}

    schedule_tick(interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, %{opts: opts, interval_ms: interval_ms} = state) do
    _ = run_once(opts)
    schedule_tick(interval_ms)
    {:noreply, state}
  end

  @spec run_once(keyword()) :: %{
          created: non_neg_integer(),
          advanced: non_neg_integer(),
          active_house: non_neg_integer()
        }
  def run_once(opts \\ []) do
    house_agent_id = Keyword.get(opts, :house_agent_id, @default_house_agent_id)
    max_active = Keyword.get(opts, :max_active_matches, @default_max_active_matches)
    game_types = normalize_game_types(Keyword.get(opts, :game_types, @default_game_types))

    matches = list_matches()

    active_house_matches =
      Enum.filter(matches, fn match ->
        match["status"] == "active" and match["created_by"] == house_agent_id
      end)

    advanced =
      active_house_matches
      |> Enum.filter(&house_turn?(&1, house_agent_id))
      |> Enum.reduce(0, fn match, acc ->
        case play_house_turn(match, house_agent_id) do
          :ok -> acc + 1
          :skip -> acc
        end
      end)

    refreshed_active_house_count =
      list_matches()
      |> Enum.count(fn match ->
        match["status"] == "active" and match["created_by"] == house_agent_id
      end)

    needed = max(max_active - refreshed_active_house_count, 0)

    created =
      if needed > 0 do
        Enum.reduce(0..(needed - 1), 0, fn idx, acc ->
          game_type = Enum.at(game_types, rem(idx, length(game_types)))

          case create_house_match(game_type, house_agent_id) do
            {:ok, match} ->
              _ = play_house_turn(match, house_agent_id)
              acc + 1

            {:error, reason} ->
              Logger.warning("[LobbySeeder] Failed to create house match: #{inspect(reason)}")
              acc
          end
        end)
      else
        0
      end

    %{created: created, advanced: advanced, active_house: refreshed_active_house_count}
  end

  defp schedule_tick(interval_ms) do
    Process.send_after(self(), :tick, interval_ms)
  end

  defp list_matches do
    :game_matches
    |> LemonCore.Store.list()
    |> Enum.map(fn {_key, match} -> match end)
  end

  defp house_turn?(match, house_agent_id) do
    match["next_player"] == "p1" and
      get_in(match, ["players", "p1", "agent_id"]) == house_agent_id
  end

  defp create_house_match(game_type, house_agent_id) do
    params = %{
      "game_type" => game_type,
      "visibility" => "public",
      "opponent" => %{"type" => "lemon_bot", "bot_id" => "default"}
    }

    actor = %{"agent_id" => house_agent_id, "display_name" => "Lemon House"}

    case Service.create_match(params, actor) do
      {:ok, match} -> {:ok, match}
      {:error, code, msg} -> {:error, {code, msg}}
    end
  end

  defp play_house_turn(match, house_agent_id) do
    move = TurnWorker.choose_move_for(match["game_type"], match["snapshot_state"], "p1")
    idempotency_key = "house_#{match["id"]}_#{match["turn_number"]}_p1"

    actor = %{"agent_id" => house_agent_id, "display_name" => "Lemon House"}

    case Service.submit_move(match["id"], actor, move, idempotency_key) do
      {:ok, _updated, _seq, _replayed?} -> :ok
      {:error, _code, _msg} -> :skip
    end
  end

  defp normalize_game_types(game_types) when is_list(game_types) do
    normalized = Enum.reject(game_types, &(&1 in [nil, ""]))
    if normalized == [], do: @default_game_types, else: normalized
  end

  defp normalize_game_types(_), do: @default_game_types
end
