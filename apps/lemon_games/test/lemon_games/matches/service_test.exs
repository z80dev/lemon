defmodule LemonGames.Matches.ServiceTest do
  use ExUnit.Case, async: false

  alias LemonGames.Matches.Service

  @actor %{"agent_id" => "test_agent", "display_name" => "Test Agent"}
  @actor2 %{"agent_id" => "test_agent_2", "display_name" => "Agent 2"}

  setup do
    clear_table(:game_matches)
    clear_table(:game_match_events)
    clear_table(:game_agent_tokens)
    clear_table(:game_rate_limits)
    :ok
  end

  # --- create_match ---

  test "create_match with bot opponent creates active match" do
    params = %{
      "game_type" => "rock_paper_scissors",
      "opponent" => %{"type" => "lemon_bot", "bot_id" => "default"},
      "visibility" => "public"
    }

    assert {:ok, match} = Service.create_match(params, @actor)
    assert match["status"] == "active"
    assert match["game_type"] == "rock_paper_scissors"
    assert match["players"]["p1"]["agent_id"] == "test_agent"
    assert match["players"]["p2"]["agent_type"] == "lemon_bot"
    assert match["snapshot_state"] != %{}
  end

  test "create_match without opponent creates pending match" do
    params = %{"game_type" => "connect4", "visibility" => "public"}
    assert {:ok, match} = Service.create_match(params, @actor)
    assert match["status"] == "pending_accept"
  end

  test "create_match rejects unknown game type" do
    params = %{"game_type" => "chess"}
    assert {:error, :unknown_game_type, _} = Service.create_match(params, @actor)
  end

  # --- accept_match ---

  test "accept_match transitions pending to active" do
    params = %{"game_type" => "connect4", "visibility" => "public"}
    {:ok, match} = Service.create_match(params, @actor)
    assert {:ok, accepted} = Service.accept_match(match["id"], @actor2)
    assert accepted["status"] == "active"
    assert accepted["players"]["p2"]["agent_id"] == "test_agent_2"
  end

  test "accept_match rejects same player" do
    params = %{"game_type" => "connect4", "visibility" => "public"}
    {:ok, match} = Service.create_match(params, @actor)
    assert {:error, :already_joined, _} = Service.accept_match(match["id"], @actor)
  end

  test "accept_match rejects already active match" do
    params = %{
      "game_type" => "connect4",
      "opponent" => %{"type" => "lemon_bot"},
      "visibility" => "public"
    }

    {:ok, match} = Service.create_match(params, @actor)
    assert {:error, :invalid_state, _} = Service.accept_match(match["id"], @actor2)
  end

  # --- submit_move ---

  test "submit_move applies legal move for connect4" do
    {:ok, match} = create_bot_match("connect4")

    move = %{"kind" => "drop", "column" => 3}
    assert {:ok, updated, seq} = Service.submit_move(match["id"], @actor, move, "key-1")
    assert seq > 0
    assert updated["turn_number"] > match["turn_number"]
  end

  test "submit_move rejects illegal move" do
    {:ok, match} = create_bot_match("connect4")

    move = %{"kind" => "drop", "column" => 99}
    assert {:error, :illegal_move, _} = Service.submit_move(match["id"], @actor, move, "key-2")
  end

  test "submit_move rejects wrong turn" do
    {:ok, match} = create_bot_match("connect4")
    bot_actor = %{"agent_id" => "lemon_bot_default"}

    # Bot shouldn't be able to move on p1's turn in connect4
    move = %{"kind" => "drop", "column" => 0}
    assert {:error, :wrong_turn, _} = Service.submit_move(match["id"], bot_actor, move, "key-3")
  end

  test "submit_move is idempotent" do
    {:ok, match} = create_bot_match("connect4")
    move = %{"kind" => "drop", "column" => 3}

    assert {:ok, _m1, seq1} = Service.submit_move(match["id"], @actor, move, "idem-1")
    assert {:ok, _m2, seq2} = Service.submit_move(match["id"], @actor, move, "idem-1")
    assert seq1 == seq2
  end

  test "submit_move_with_meta marks idempotent replay" do
    {:ok, match} = create_bot_match("connect4")
    move = %{"kind" => "drop", "column" => 3}

    assert {:ok, _m1, seq1, false} =
             Service.submit_move_with_meta(match["id"], @actor, move, "idem-meta-1")

    assert {:ok, _m2, seq2, true} =
             Service.submit_move_with_meta(match["id"], @actor, move, "idem-meta-1")

    assert seq1 == seq2
  end

  test "submit_move idempotency keys are scoped per actor" do
    params = %{"game_type" => "connect4", "visibility" => "public"}
    {:ok, match} = Service.create_match(params, @actor)
    {:ok, _accepted} = Service.accept_match(match["id"], @actor2)

    move_p1 = %{"kind" => "drop", "column" => 0}
    move_p2 = %{"kind" => "drop", "column" => 1}

    assert {:ok, _first, seq1} = Service.submit_move(match["id"], @actor, move_p1, "same-key")
    assert {:ok, _second, seq2} = Service.submit_move(match["id"], @actor2, move_p2, "same-key")
    assert seq2 > seq1
  end

  # --- RPS full game ---

  test "rps full game reaches terminal state" do
    params = %{"game_type" => "rock_paper_scissors", "visibility" => "public"}
    {:ok, match} = Service.create_match(params, @actor)
    {:ok, _accepted} = Service.accept_match(match["id"], @actor2)

    assert {:ok, _m1, _} =
             Service.submit_move(
               match["id"],
               @actor,
               %{"kind" => "throw", "value" => "rock"},
               "rps-1"
             )

    assert {:ok, m2, _} =
             Service.submit_move(
               match["id"],
               @actor2,
               %{"kind" => "throw", "value" => "scissors"},
               "rps-2"
             )

    assert m2["status"] == "finished"
    assert m2["result"]["winner"] == "p1"
  end

  # --- get_match ---

  test "get_match returns public view" do
    {:ok, match} = create_bot_match("connect4")
    assert {:ok, view} = Service.get_match(match["id"], "spectator")
    assert view["id"] == match["id"]
    assert view["game_state"] != nil
  end

  test "get_match rejects private match for spectator" do
    params = %{"game_type" => "connect4", "visibility" => "private"}
    {:ok, match} = Service.create_match(params, @actor)
    assert {:error, :forbidden, _} = Service.get_match(match["id"], "spectator")
  end

  test "get_match returns error for unknown id" do
    assert {:error, :not_found, _} = Service.get_match("nonexistent", "spectator")
  end

  # --- list_lobby ---

  test "list_lobby returns public matches" do
    {:ok, _} = create_bot_match("connect4")
    lobby = Service.list_lobby()
    assert length(lobby) >= 1
  end

  # --- list_events ---

  test "list_events returns events after seq" do
    {:ok, match} = create_bot_match("connect4")
    assert {:ok, events, _next, _more} = Service.list_events(match["id"], 0, 50, "spectator")
    assert length(events) >= 1
  end

  test "list_events redacts unresolved rps throw for opponent and spectator" do
    params = %{"game_type" => "rock_paper_scissors", "visibility" => "public"}
    {:ok, match} = Service.create_match(params, @actor)
    {:ok, _accepted} = Service.accept_match(match["id"], @actor2)

    assert {:ok, _updated, _seq} =
             Service.submit_move(
               match["id"],
               @actor,
               %{"kind" => "throw", "value" => "rock"},
               "rps-hide"
             )

    assert {:ok, spectator_events, _next, _more} =
             Service.list_events(match["id"], 0, 50, "spectator")

    assert {:ok, opponent_events, _next2, _more2} =
             Service.list_events(match["id"], 0, 50, @actor2["agent_id"])

    assert {:ok, actor_events, _next3, _more3} =
             Service.list_events(match["id"], 0, 50, @actor["agent_id"])

    spectator_move = Enum.find(spectator_events, &(&1["event_type"] == "move_submitted"))
    opponent_move = Enum.find(opponent_events, &(&1["event_type"] == "move_submitted"))
    actor_move = Enum.find(actor_events, &(&1["event_type"] == "move_submitted"))

    assert get_in(spectator_move, ["payload", "move", "value"]) == "hidden"
    assert get_in(opponent_move, ["payload", "move", "value"]) == "hidden"
    assert get_in(actor_move, ["payload", "move", "value"]) == "rock"
  end

  test "list_events rejects private match for spectator" do
    params = %{"game_type" => "connect4", "visibility" => "private"}
    {:ok, match} = Service.create_match(params, @actor)
    assert {:error, :forbidden, _} = Service.list_events(match["id"], 0, 50, "spectator")
  end

  # --- forfeit ---

  test "forfeit_match finishes game with opponent as winner" do
    {:ok, match} = create_bot_match("connect4")
    assert {:ok, forfeited} = Service.forfeit_match(match["id"], @actor, "gave up")
    assert forfeited["status"] == "finished"
    assert forfeited["result"]["winner"] == "p2"
  end

  # --- expire ---

  test "expire_match transitions to expired" do
    params = %{"game_type" => "connect4", "visibility" => "public"}
    {:ok, match} = Service.create_match(params, @actor)
    assert {:ok, expired} = Service.expire_match(match["id"], "accept_timeout")
    assert expired["status"] == "expired"
  end

  # --- helpers ---

  defp create_bot_match(game_type) do
    Service.create_match(
      %{
        "game_type" => game_type,
        "opponent" => %{"type" => "lemon_bot", "bot_id" => "default"},
        "visibility" => "public"
      },
      @actor
    )
  end

  defp clear_table(table) do
    table
    |> LemonCore.Store.list()
    |> Enum.each(fn {key, _} -> LemonCore.Store.delete(table, key) end)
  end
end
