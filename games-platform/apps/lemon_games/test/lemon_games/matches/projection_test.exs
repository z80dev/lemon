defmodule LemonGames.Matches.ProjectionTest do
  use ExUnit.Case, async: true

  alias LemonGames.Matches.Projection

  test "replay rps events to terminal" do
    events = [
      %{
        "event_type" => "move_submitted",
        "actor" => %{"slot" => "p1"},
        "payload" => %{"move" => %{"kind" => "throw", "value" => "rock"}}
      },
      %{
        "event_type" => "move_submitted",
        "actor" => %{"slot" => "p2"},
        "payload" => %{"move" => %{"kind" => "throw", "value" => "scissors"}}
      }
    ]

    {state, terminal} = Projection.replay("rock_paper_scissors", events)
    assert state["winner"] == "p1"
    assert terminal == "winner"
  end

  test "replay rps draw" do
    events = [
      %{
        "event_type" => "move_submitted",
        "actor" => %{"slot" => "p1"},
        "payload" => %{"move" => %{"kind" => "throw", "value" => "rock"}}
      },
      %{
        "event_type" => "move_submitted",
        "actor" => %{"slot" => "p2"},
        "payload" => %{"move" => %{"kind" => "throw", "value" => "rock"}}
      }
    ]

    {state, terminal} = Projection.replay("rock_paper_scissors", events)
    assert state["winner"] == "draw"
    assert terminal == "draw"
  end

  test "replay skips non-move events" do
    events = [
      %{"event_type" => "match_created", "actor" => %{}, "payload" => %{}},
      %{
        "event_type" => "move_submitted",
        "actor" => %{"slot" => "p1"},
        "payload" => %{"move" => %{"kind" => "throw", "value" => "paper"}}
      }
    ]

    {state, terminal} = Projection.replay("rock_paper_scissors", events)
    assert state["throws"]["p1"] == "paper"
    assert terminal == nil
  end

  test "replay connect4 vertical win" do
    # p1 drops column 0 four times, p2 drops column 1 three times
    events =
      [
        {"p1", 0},
        {"p2", 1},
        {"p1", 0},
        {"p2", 1},
        {"p1", 0},
        {"p2", 1},
        {"p1", 0}
      ]
      |> Enum.map(fn {slot, col} ->
        %{
          "event_type" => "move_submitted",
          "actor" => %{"slot" => slot},
          "payload" => %{"move" => %{"kind" => "drop", "column" => col}}
        }
      end)

    {state, terminal} = Projection.replay("connect4", events)
    assert state["winner"] == "p1"
    assert terminal == "winner"
  end

  test "project_public_view includes expected fields" do
    match = %{
      "id" => "match_test",
      "game_type" => "connect4",
      "status" => "active",
      "visibility" => "public",
      "players" => %{
        "p1" => %{"agent_id" => "a1", "agent_type" => "external_agent", "display_name" => "A1"},
        "p2" => %{"agent_id" => "a2", "agent_type" => "lemon_bot", "display_name" => "Bot"}
      },
      "turn_number" => 1,
      "next_player" => "p1",
      "result" => nil,
      "snapshot_state" => LemonGames.Games.Connect4.init(%{}),
      "deadline_at_ms" => 0,
      "inserted_at_ms" => 0,
      "updated_at_ms" => 0
    }

    view = Projection.project_public_view(match, "spectator")
    assert view["id"] == "match_test"
    assert view["game_state"]["board"] != nil
    assert view["players"]["p1"]["agent_id"] == "a1"
  end
end
