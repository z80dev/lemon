defmodule LemonGames.Bot.LobbySeederTest do
  use ExUnit.Case, async: false

  alias LemonGames.Bot.LobbySeeder
  alias LemonGames.Matches.Service

  @house_agent_id "lemon_house"

  setup do
    for table <- [:game_matches, :game_match_events, :game_agent_tokens, :game_rate_limits] do
      clear_table(table)
    end

    :ok
  end

  test "run_once seeds house matches and kicks off gameplay" do
    result =
      LobbySeeder.run_once(
        house_agent_id: @house_agent_id,
        max_active_matches: 1,
        game_types: ["connect4"]
      )

    assert result.created == 1

    match = fetch_house_match!()

    wait_until(fn ->
      {:ok, refreshed} = Service.get_match(match["id"], @house_agent_id)
      refreshed["turn_number"] >= 1
    end)
  end

  test "run_once advances existing house matches when it's p1 turn" do
    house_agent_id = "lemon_house_test_advance"

    {:ok, match} =
      Service.create_match(
        %{
          "game_type" => "connect4",
          "visibility" => "public",
          "opponent" => %{"type" => "lemon_bot", "bot_id" => "default"}
        },
        %{"agent_id" => house_agent_id, "display_name" => "Lemon House"}
      )

    before_turn_number = match["turn_number"]

    result =
      LobbySeeder.run_once(
        house_agent_id: house_agent_id,
        max_active_matches: 1,
        game_types: ["connect4"]
      )

    assert result.advanced >= 0

    wait_until(fn ->
      {:ok, refreshed} = Service.get_match(match["id"], house_agent_id)
      refreshed["turn_number"] >= before_turn_number + 1
    end)
  end

  defp fetch_house_match! do
    :game_matches
    |> LemonCore.Store.list()
    |> Enum.map(fn {_key, m} -> m end)
    |> Enum.find(fn m -> m["created_by"] == @house_agent_id end)
    |> case do
      nil -> flunk("expected a house-created match")
      match -> match
    end
  end

  defp wait_until(fun, attempts \\ 20)

  defp wait_until(_fun, 0), do: flunk("condition not met")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
  end

  defp clear_table(table) do
    LemonCore.Store.list(table)
    |> Enum.each(fn {key, _value} ->
      LemonCore.Store.delete(table, key)
    end)
  end
end
