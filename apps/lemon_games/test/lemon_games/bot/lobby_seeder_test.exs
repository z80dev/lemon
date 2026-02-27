defmodule LemonGames.Bot.LobbySeederTest do
  use ExUnit.Case, async: false

  alias LemonGames.Bot.LobbySeeder
  alias LemonGames.Matches.Service

  setup do
    clear_table(:game_matches)
    clear_table(:game_match_events)
    :ok
  end

  test "creates public house-vs-bot matches up to target" do
    {:ok, pid} =
      start_supervised(
        {LobbySeeder,
         [
           interval_ms: 60_000,
           target_active_matches: 2,
           games: ["connect4"],
           house_agent_id: "house_seed"
         ]}
      )

    send(pid, :seed)

    assert_eventually(fn ->
      matches = house_matches("house_seed")
      active = Enum.count(matches, &(&1["status"] == "active"))
      active >= 2
    end)
  end

  test "advances house turns for active seeded match" do
    {:ok, match} =
      Service.create_match(
        %{
          "game_type" => "connect4",
          "opponent" => %{"type" => "lemon_bot", "bot_id" => "default"},
          "visibility" => "public"
        },
        %{"agent_id" => "house_player", "display_name" => "House"}
      )

    assert match["status"] == "active"
    assert match["next_player"] == "p1"

    {:ok, pid} =
      start_supervised(
        {LobbySeeder,
         [
           interval_ms: 60_000,
           target_active_matches: 1,
           games: ["connect4"],
           house_agent_id: "house_player"
         ]}
      )

    send(pid, :seed)

    assert_eventually(fn ->
      updated = LemonCore.Store.get(:game_matches, match["id"])
      updated["turn_number"] > 1
    end)
  end

  defp house_matches(house_agent_id) do
    :game_matches
    |> LemonCore.Store.list()
    |> Enum.map(fn {_id, match} -> match end)
    |> Enum.filter(fn match ->
      get_in(match, ["players", "p1", "agent_id"]) == house_agent_id and
        get_in(match, ["players", "p2", "agent_type"]) == "lemon_bot"
    end)
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      assert true
    else
      Process.sleep(50)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met within timeout")

  defp clear_table(table) do
    table
    |> LemonCore.Store.list()
    |> Enum.each(fn {key, _value} -> LemonCore.Store.delete(table, key) end)
  end
end
