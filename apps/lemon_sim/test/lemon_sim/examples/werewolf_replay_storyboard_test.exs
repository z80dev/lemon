defmodule LemonSim.Examples.WerewolfReplayStoryboardTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.Werewolf.ReplayStoryboard

  test "builds readable discussion beats with prior context and longer dwell time" do
    beats = ReplayStoryboard.build(sample_entries(), fps: 2)

    discussion_beats =
      Enum.filter(beats, fn beat ->
        get_in(beat, [:entry, :phase]) == "day_discussion" and
          is_binary(get_in(beat, [:entry, :detail, :statement]))
      end)

    assert length(discussion_beats) == 2

    second_discussion = Enum.at(discussion_beats, 1)

    assert second_discussion.hold_frames >= 10

    assert get_in(second_discussion, [:entry, :detail, :recent_statements]) == [
             %{
               speaker: "Alice",
               statement:
                 "Nobody died last night, so we probably saw a save. I want direct claims, not vague pressure."
             }
           ]
  end

  test "emits explicit night action beats so viewers can follow every move" do
    beats = ReplayStoryboard.build(sample_entries(), fps: 2)

    night_cards =
      Enum.filter(beats, fn beat ->
        get_in(beat, [:entry, :type]) == "turn_result" and
          get_in(beat, [:entry, :detail, :story_card, :title]) in ["Werewolf Move", "Seer Check"]
      end)

    assert length(night_cards) == 2

    assert Enum.any?(night_cards, fn beat ->
             get_in(beat, [:entry, :detail, :story_card, :summary]) == "Dane targets Alice."
           end)

    assert Enum.any?(night_cards, fn beat ->
             get_in(beat, [:entry, :detail, :story_card, :summary]) ==
               "Cora investigates Dane and sees WEREWOLF."
           end)
  end

  test "annotates vote swings with a watchable summary" do
    beats = ReplayStoryboard.build(sample_entries(), fps: 2)

    vote_beats =
      Enum.filter(beats, fn beat ->
        get_in(beat, [:entry, :phase]) == "day_voting" and
          is_binary(get_in(beat, [:entry, :detail, :vote_summary]))
      end)

    assert Enum.any?(vote_beats, fn beat ->
             get_in(beat, [:entry, :detail, :vote_summary]) == "Cora pushes Dane to majority."
           end)
  end

  test "reconstructs a final vote beat from latest_vote when the world has already cleared votes" do
    beats =
      ReplayStoryboard.build([
        %{
          type: "game_start",
          world: %{phase: "night", day_number: 1},
          players: %{
            "Alice" => %{role: "villager", model: "openai/gpt-5"},
            "Bram" => %{role: "villager", model: "openai/gpt-5"},
            "Cora" => %{role: "werewolf", model: "openai/gpt-5"},
            "Dane" => %{role: "doctor", model: "openai/gpt-5"}
          }
        },
        %{
          type: "turn_result",
          step: 7,
          day: 1,
          phase: "day_voting",
          detail: %{votes: %{"Alice" => "Cora"}},
          elimination_log: []
        },
        %{
          type: "turn_result",
          step: 8,
          day: 1,
          phase: "day_voting",
          detail: %{votes: %{}, latest_vote: %{voter: "Dane", target: "Cora"}},
          elimination_log: []
        }
      ])

    assert Enum.any?(beats, fn beat ->
             get_in(beat, [:entry, :detail, :vote_summary]) == "Dane votes Cora."
           end)
  end

  test "shows the decisive vote before the elimination reveal" do
    beats =
      ReplayStoryboard.build([
        %{
          type: "game_start",
          world: %{phase: "night", day_number: 1},
          players: %{
            "Alice" => %{role: "villager", model: "openai/gpt-5"},
            "Bram" => %{role: "villager", model: "openai/gpt-5"},
            "Cora" => %{role: "werewolf", model: "openai/gpt-5"},
            "Dane" => %{role: "doctor", model: "openai/gpt-5"}
          }
        },
        %{
          type: "turn_result",
          step: 7,
          day: 1,
          phase: "day_voting",
          detail: %{votes: %{"Alice" => "Cora"}},
          elimination_log: []
        },
        %{
          type: "turn_result",
          step: 8,
          day: 1,
          phase: "day_voting",
          detail: %{
            votes: %{"Alice" => "Cora", "Dane" => "Cora"},
            latest_vote: %{voter: "Dane", target: "Cora"}
          },
          elimination_log: [%{player: "Cora", role: "werewolf", reason: "voted", day: 1}]
        }
      ])

    vote_index =
      Enum.find_index(beats, fn beat ->
        get_in(beat, [:entry, :detail, :vote_summary]) == "Dane pushes Cora to majority."
      end)

    elimination_index =
      Enum.find_index(beats, fn beat ->
        get_in(beat, [:entry, :detail, :story_card, :title]) == "Cora Eliminated"
      end)

    assert is_integer(vote_index)
    assert is_integer(elimination_index)
    assert vote_index < elimination_index
  end

  test "dawn card reports overnight deaths from the last night step" do
    beats =
      ReplayStoryboard.build([
        %{
          type: "game_start",
          world: %{phase: "night", day_number: 1},
          players: %{
            "Alice" => %{role: "villager", model: "openai/gpt-5"},
            "Bram" => %{role: "doctor", model: "openai/gpt-5"},
            "Cora" => %{role: "werewolf", model: "openai/gpt-5"}
          }
        },
        %{
          type: "turn_result",
          step: 1,
          day: 1,
          phase: "night",
          detail: %{
            night_actions: %{"Cora" => %{action: "choose_victim", target: "Alice"}}
          },
          elimination_log: [%{player: "Alice", role: "villager", reason: "killed", day: 1}]
        },
        %{
          type: "turn_result",
          step: 2,
          day: 1,
          phase: "day_discussion",
          detail: %{},
          elimination_log: [%{player: "Alice", role: "villager", reason: "killed", day: 1}]
        }
      ])

    assert Enum.any?(beats, fn beat ->
             get_in(beat, [:entry, :detail, :story_card, :title]) == "Dawn 1" and
               get_in(beat, [:entry, :detail, :story_card, :summary]) == "Alice was found dead."
           end)
  end

  test "uses player names directly as keys" do
    beats =
      ReplayStoryboard.build([
        %{
          type: "game_start",
          world: %{phase: "night", day_number: 1},
          players: %{
            "Alice" => %{role: "villager", model: "openai/gpt-5"},
            "Bram" => %{role: "villager", model: "openai/gpt-5"},
            "Cora" => %{role: "werewolf", model: "openai/gpt-5"},
            "Dane" => %{role: "doctor", model: "openai/gpt-5"}
          }
        },
        %{
          type: "turn_result",
          step: 1,
          day: 1,
          phase: "day_voting",
          detail: %{votes: %{"Dane" => "Cora"}},
          elimination_log: []
        }
      ])

    assert Enum.any?(beats, fn beat ->
             get_in(beat, [:entry, :detail, :vote_summary]) == "Dane votes Cora."
           end)
  end

  defp sample_entries do
    [
      %{
        type: "game_start",
        world: %{phase: "night", day_number: 1},
        players: %{
          "Alice" => %{role: "villager", model: "openai/gpt-5"},
          "Bram" => %{role: "villager", model: "openai/gpt-5"},
          "Cora" => %{role: "seer", model: "openai/gpt-5"},
          "Dane" => %{role: "werewolf", model: "openai/gpt-5"}
        }
      },
      %{
        type: "turn_result",
        step: 1,
        day: 1,
        phase: "night",
        detail: %{night_actions: %{"Dane" => %{action: "choose_victim", target: "Alice"}}},
        elimination_log: []
      },
      %{
        type: "turn_result",
        step: 2,
        day: 1,
        phase: "night",
        detail: %{
          night_actions: %{
            "Cora" => %{action: "investigate", target: "Dane", result: "werewolf"},
            "Dane" => %{action: "choose_victim", target: "Alice"}
          }
        },
        elimination_log: []
      },
      %{
        type: "turn_result",
        step: 3,
        day: 1,
        phase: "day_discussion",
        detail: %{},
        elimination_log: []
      },
      %{
        type: "turn_result",
        step: 4,
        day: 1,
        phase: "day_discussion",
        detail: %{
          speaker: "Alice",
          statement:
            "Nobody died last night, so we probably saw a save. I want direct claims, not vague pressure."
        },
        elimination_log: []
      },
      %{
        type: "turn_result",
        step: 5,
        day: 1,
        phase: "day_discussion",
        detail: %{
          speaker: "Bram",
          statement:
            "Cora has a strong read on Dane, and that is the cleanest lead we have. If we are serious, we should move on Dane now instead of drifting."
        },
        elimination_log: []
      },
      %{
        type: "turn_result",
        step: 6,
        day: 1,
        phase: "day_voting",
        detail: %{votes: %{}},
        elimination_log: []
      },
      %{
        type: "turn_result",
        step: 7,
        day: 1,
        phase: "day_voting",
        detail: %{votes: %{"Alice" => "Dane"}},
        elimination_log: []
      },
      %{
        type: "turn_result",
        step: 8,
        day: 1,
        phase: "day_voting",
        detail: %{votes: %{"Alice" => "Dane", "Bram" => "Dane"}},
        elimination_log: []
      },
      %{
        type: "turn_result",
        step: 9,
        day: 1,
        phase: "day_voting",
        detail: %{
          votes: %{"Alice" => "Dane", "Bram" => "Dane", "Cora" => "Dane"}
        },
        elimination_log: []
      }
    ]
  end
end
