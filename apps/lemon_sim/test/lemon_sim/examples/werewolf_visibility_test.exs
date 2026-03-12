defmodule LemonSim.Examples.WerewolfVisibilityTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.Werewolf

  test "recent_events hides live cast_vote events from players" do
    builder = Werewolf.projector_opts()[:section_builders][:recent_events]

    frame = %{
      world: %{
        active_actor_id: "Alice",
        players: %{
          "Alice" => %{role: "villager", status: "alive"},
          "Bram" => %{role: "villager", status: "alive"}
        }
      },
      recent_events: [
        %{
          kind: "make_statement",
          payload: %{"player_id" => "Bram", "statement" => "Vote Alice."}
        },
        %{kind: "cast_vote", payload: %{"player_id" => "Bram", "target_id" => "Alice"}},
        %{
          kind: "vote_result",
          payload: %{"eliminated_id" => "Alice", "vote_tally" => %{"Alice" => 1}}
        }
      ]
    }

    section = builder.(frame, [], [])
    visible_kinds = Enum.map(section.content, &Map.get(&1, :kind, Map.get(&1, "kind")))

    assert visible_kinds == ["make_statement", "vote_result"]
  end

  test "player-facing sections use names directly as keys" do
    world_state_builder = Werewolf.projector_opts()[:section_builders][:world_state]
    role_info_builder = Werewolf.projector_opts()[:section_builders][:role_info]
    discussion_log_builder = Werewolf.projector_opts()[:section_builders][:discussion_log]
    recent_events_builder = Werewolf.projector_opts()[:section_builders][:recent_events]

    frame = %{
      world: %{
        active_actor_id: "Alice",
        phase: "day_discussion",
        day_number: 2,
        players: %{
          "Alice" => %{role: "werewolf", status: "alive"},
          "Bram" => %{role: "villager", status: "alive"},
          "Cora" => %{role: "villager", status: "dead"}
        },
        seer_history: [%{target: "Bram", role: "villager"}],
        discussion_transcript: [
          %{player: "Bram", statement: "I think Alice is suspicious."}
        ],
        elimination_log: [
          %{player: "Cora", role: "villager", reason: "voted", day: 1}
        ]
      },
      recent_events: [
        %{
          kind: "make_statement",
          payload: %{"player_id" => "Bram", "statement" => "Vote Alice next."}
        }
      ]
    }

    world_state = world_state_builder.(frame, [], []).content
    role_info = role_info_builder.(frame, [], []).content
    discussion_log = discussion_log_builder.(frame, [], []).content
    recent_events = recent_events_builder.(frame, [], []).content

    assert world_state["you"] == "Alice"
    assert world_state["active_player"] == "Alice"

    assert Enum.at(world_state["players"], 0) == %{
             "name" => "Alice",
             "status" => "alive"
           }

    assert role_info["your_name"] == "Alice"

    assert role_info["werewolf_partners"] == []

    assert discussion_log["discussion_transcript"] == [
             %{
               "player" => "Bram",
               "statement" => "I think Alice is suspicious."
             }
           ]

    assert discussion_log["elimination_log"] == [
             %{
               "player" => "Cora",
               "role" => "villager",
               "reason" => "voted",
               "day" => 1
             }
           ]

    assert recent_events == [
             %{
               kind: "make_statement",
               payload: %{
                 "speaker" => "Bram",
                 "statement" => "Vote Alice next."
               }
             }
           ]
  end
end
