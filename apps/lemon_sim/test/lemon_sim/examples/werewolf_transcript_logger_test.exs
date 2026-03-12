defmodule LemonSim.Examples.WerewolfTranscriptLoggerTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.Werewolf.TranscriptLogger

  test "turn_result_entry preserves the last discussion statement before voting starts" do
    result = %{
      decision: %{
        "tool_name" => "make_statement",
        "arguments" => %{"statement" => "I think the vote on Felix needs a clear explanation."},
        "result_details" => %{
          "event" => %{"payload" => %{"player_id" => "Hugo"}}
        }
      },
      state: %{
        world: %{
          phase: "day_voting",
          day_number: 1,
          active_actor_id: "Alice",
          status: "in_progress",
          votes: %{},
          elimination_log: []
        }
      }
    }

    entry =
      TranscriptLogger.turn_result_entry(
        16,
        %{phase: "day_discussion", day: 1, active_player: "Hugo"},
        result
      )

    assert entry.phase == "day_discussion"
    assert entry.day == 1
    assert entry.phase_after == "day_voting"
    assert entry.active_player_after == "Alice"

    assert entry.detail == %{
             statement: "I think the vote on Felix needs a clear explanation.",
             speaker: "Hugo"
           }
  end

  test "turn_result_entry preserves the last vote before night begins" do
    result = %{
      decision: %{
        "tool_name" => "cast_vote",
        "arguments" => %{"target_id" => "Esme"},
        "result_details" => %{
          "event" => %{"payload" => %{"player_id" => "Hugo"}}
        }
      },
      state: %{
        world: %{
          phase: "night",
          day_number: 2,
          active_actor_id: "Esme",
          status: "in_progress",
          votes: %{
            "Alice" => "Esme",
            "Bram" => "Esme",
            "Cora" => "Esme",
            "Dane" => "Esme",
            "Esme" => "Hugo"
          },
          elimination_log: []
        }
      }
    }

    entry =
      TranscriptLogger.turn_result_entry(
        67,
        %{phase: "day_voting", day: 1, active_player: "Hugo"},
        result
      )

    assert entry.phase == "day_voting"
    assert entry.day == 1
    assert entry.day_after == 2
    assert entry.phase_after == "night"
    assert entry.detail.votes["Esme"] == "Hugo"
  end

  test "turn_result_entry preserves the final vote before game over clears votes" do
    result = %{
      decision: %{
        "tool_name" => "cast_vote",
        "arguments" => %{"target_id" => "Felix"},
        "result_details" => %{
          "event" => %{"payload" => %{"player_id" => "Hugo"}}
        }
      },
      state: %{
        world: %{
          phase: "game_over",
          day_number: 2,
          active_actor_id: nil,
          status: "game_over",
          votes: %{},
          elimination_log: [],
          winner: "villagers"
        }
      }
    }

    entry =
      TranscriptLogger.turn_result_entry(
        88,
        %{
          phase: "day_voting",
          day: 2,
          active_player: "Hugo",
          votes: %{
            "Alice" => "Felix",
            "Bram" => "Felix",
            "Cora" => "Felix",
            "Dane" => "Esme"
          }
        },
        result
      )

    assert entry.phase == "day_voting"
    assert entry.phase_after == "game_over"
    assert entry.detail.latest_vote == %{voter: "Hugo", target: "Felix"}
    assert entry.detail.votes["Hugo"] == "Felix"
  end

  test "turn_result_entry preserves the last night action before dawn clears night_actions" do
    result = %{
      decision: %{
        "tool_name" => "protect_player",
        "arguments" => %{"target_id" => "Bram"},
        "result_details" => %{
          "event" => %{"payload" => %{"player_id" => "Hugo"}}
        }
      },
      state: %{
        world: %{
          phase: "day_discussion",
          day_number: 2,
          active_actor_id: "Alice",
          status: "in_progress",
          night_actions: %{},
          elimination_log: []
        }
      }
    }

    entry =
      TranscriptLogger.turn_result_entry(
        41,
        %{
          phase: "night",
          day: 2,
          active_player: "Hugo",
          night_actions: %{
            "Gia" => %{action: "choose_victim", target: "Bram"},
            "Esme" => %{action: "investigate", target: "Gia", result: "werewolf"}
          }
        },
        result
      )

    assert entry.phase == "night"
    assert entry.phase_after == "day_discussion"

    assert entry.detail.latest_night_action == %{
             player: "Hugo",
             action: "protect",
             target: "Bram"
           }

    assert entry.detail.night_actions["Hugo"] == %{action: "protect", target: "Bram"}
  end

  test "print_step_summary uses decision payload for final discussion speaker" do
    summary =
      TranscriptLogger.print_step_summary(%{
        decision: %{
          "tool_name" => "make_statement",
          "arguments" => %{"statement" => "I was quiet, but my read is that Felix is bad."},
          "result_details" => %{
            "event" => %{"payload" => %{"player_id" => "Hugo"}}
          }
        },
        state: %{world: %{phase: "day_voting", winner: nil}}
      })

    assert summary == ~s{  [Hugo]: "I was quiet, but my read is that Felix is bad."}
  end
end
