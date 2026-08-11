defmodule LemonSim.Examples.WerewolfVisibilityTest do
  use ExUnit.Case, async: true

  alias LemonAi.Types.UserMessage
  alias LemonSim.Examples.Werewolf
  alias LemonSim.Examples.Werewolf.Events
  alias LemonSim.Kernel.{DecisionFrame, State}

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

  test "public evidence carries reliability without leaking internal provenance" do
    builder = Werewolf.projector_opts()[:section_builders][:recent_events]

    frame = %{
      world: %{
        active_actor_id: "Alice",
        players: %{
          "Alice" => %{role: "villager", status: "alive"},
          "Bram" => %{role: "werewolf", status: "alive"}
        }
      },
      recent_events: [
        %{
          kind: "evidence_found",
          payload: %{
            "tokens" => [
              %{
                type: "muddy_footprints",
                clue: "A partial trail points toward Bram's side of the village.",
                related_to: "Bram",
                reliability: "medium",
                interpretation: "Noisy lead, not proof."
              }
            ]
          }
        }
      ]
    }

    assert [%{payload: %{"tokens" => [token]}}] = builder.(frame, [], []).content
    assert token["reliability"] == "medium"
    assert token["interpretation"] == "Noisy lead, not proof."
    refute Map.has_key?(token, "related_to")
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
    assert world_state["role_distribution"] == %{"villager" => 2, "werewolf" => 1}
    assert world_state["remaining_role_counts"] == %{"villager" => 1, "werewolf" => 1}

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

    assert discussion_log["public_timeline"] == [
             %{
               "day" => 1,
               "phase" => "day_elimination",
               "fact" =>
                 "On Day 1 during the elimination, Cora was publicly revealed as villager."
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

  test "private meetings are only shown to their participants" do
    discussion_log_builder = Werewolf.projector_opts()[:section_builders][:discussion_log]
    recent_events_builder = Werewolf.projector_opts()[:section_builders][:recent_events]

    world = %{
      phase: "private_meeting",
      day_number: 2,
      current_meeting_index: 0,
      meeting_pairs: [["Alice", "Bram"]],
      meeting_transcripts: [
        %{
          day: 2,
          pair: ["Alice", "Bram"],
          messages: [
            %{player: "Alice", message: "Let's compare reads."},
            %{player: "Bram", message: "I trust Cora least."}
          ]
        }
      ],
      players: %{
        "Alice" => %{role: "villager", status: "alive"},
        "Bram" => %{role: "villager", status: "alive"},
        "Cora" => %{role: "werewolf", status: "alive"}
      }
    }

    outsider_frame = %{
      world: Map.put(world, :active_actor_id, "Cora"),
      recent_events: [
        %{kind: "request_meeting", payload: %{"player_id" => "Alice", "target_id" => "Bram"}},
        %{
          kind: "meeting_message",
          payload: %{"player_id" => "Alice", "message" => "Let's compare reads."}
        }
      ]
    }

    participant_frame = %{
      world: Map.put(world, :active_actor_id, "Alice"),
      recent_events: outsider_frame.recent_events
    }

    assert discussion_log_builder.(outsider_frame, [], []).content["meeting_transcripts"] == []
    assert recent_events_builder.(outsider_frame, [], []).content == []

    assert discussion_log_builder.(participant_frame, [], []).content["meeting_transcripts"] == [
             %{
               "pair" => ["Alice", "Bram"],
               "messages" => [
                 %{"player" => "Alice", "message" => "Let's compare reads."},
                 %{"player" => "Bram", "message" => "I trust Cora least."}
               ]
             }
           ]

    assert Enum.map(recent_events_builder.(participant_frame, [], []).content, & &1.kind) == [
             "request_meeting"
           ]

    assert discussion_log_builder.(participant_frame, [], []).content["current_meeting"] == %{
             "pair" => ["Alice", "Bram"],
             "messages" => []
           }
  end

  test "night resolution hides who survived an attack" do
    recent_events_builder = Werewolf.projector_opts()[:section_builders][:recent_events]

    frame = %{
      world: %{
        active_actor_id: "Alice",
        players: %{
          "Alice" => %{role: "villager", status: "alive"},
          "Bram" => %{role: "villager", status: "alive"}
        }
      },
      recent_events: [Events.night_resolved("Bram", "Bram", true)]
    }

    [event] = recent_events_builder.(frame, [], []).content

    assert event.payload["saved?"] == true
    assert event.payload["summary"] == "An attack was prevented. No one died overnight."
    refute Map.has_key?(event.payload, "victim")
  end

  test "pack history is visible only in werewolf role context" do
    builder = Werewolf.projector_opts()[:section_builders][:role_info]

    world = %{
      active_actor_id: "Cora",
      players: %{
        "Alice" => %{role: "villager", status: "alive"},
        "Cora" => %{role: "werewolf", status: "alive"}
      },
      wolf_chat_transcript: [],
      wolf_chat_history: [
        %{day: 1, player: "Cora", message: "Pressure Alice tomorrow."}
      ]
    }

    wolf_context = builder.(%{world: world, recent_events: []}, [], []).content

    assert wolf_context["wolf_chat_history"] == [
             %{"day" => 1, "player" => "Cora", "message" => "Pressure Alice tomorrow."}
           ]

    villager_context =
      builder.(%{world: Map.put(world, :active_actor_id, "Alice"), recent_events: []}, [], []).content

    refute Map.has_key?(villager_context, "wolf_chat_history")
    refute inspect(villager_context) =~ "Pressure Alice tomorrow."
  end

  test "player prompts never include omniscient decision traces" do
    frame = %DecisionFrame{
      sim_id: "werewolf-hidden-plan-history",
      world: %{
        active_actor_id: "Bram",
        phase: "night",
        day_number: 2,
        players: %{
          "Alice" => %{role: "werewolf", status: "alive"},
          "Bram" => %{role: "doctor", status: "alive"},
          "Cora" => %{role: "villager", status: "alive"}
        }
      },
      plan_history: [
        %{
          summary: "Alice used choose_victim",
          rationale: "victim_id=Bram",
          meta: %{actor: "Alice", tool: "choose_victim"}
        }
      ]
    }

    assert {:ok, context} =
             Werewolf.modules().projector.project(frame, [], Werewolf.projector_opts())

    assert [%UserMessage{content: prompt}] = context.messages
    refute prompt =~ "Plan History"
    refute prompt =~ "choose_victim"
    refute prompt =~ "victim_id=Bram"
  end

  test "hosted dead-player and public projections fail closed on private information" do
    state =
      State.new(
        sim_id: "werewolf-hosted-privacy",
        world: %{
          status: "in_progress",
          phase: "night",
          day_number: 3,
          active_actor_id: "Cora",
          players: %{
            "Alice" => %{role: "werewolf", status: "dead", traits: ["cunning"]},
            "Bram" => %{role: "villager", status: "alive"},
            "Cora" => %{role: "werewolf", status: "alive"}
          },
          discussion_transcript: [],
          elimination_log: [%{player: "Alice", role: "werewolf", reason: "voted", day: 2}],
          last_words: [],
          journals: %{"Alice" => [%{day: 1, thought: "Cora is my partner"}]},
          wolf_chat_transcript: [%{player: "Cora", message: "Kill Bram tonight"}],
          wolf_chat_history: [%{day: 3, player: "Cora", message: "Kill Bram tonight"}],
          meeting_pairs: [["Bram", "Cora"]],
          current_meeting_index: 0,
          meeting_transcripts: [
            %{day: 3, pair: ["Bram", "Cora"], messages: [%{player: "Cora", message: "Secret"}]}
          ],
          backstory_connections: [],
          character_profiles: %{},
          player_items: %{},
          seer_history: [],
          wanderer_results: []
        },
        recent_events: [
          Events.wolf_chat("Cora", "Kill Bram tonight"),
          Events.choose_victim("Cora", "Bram"),
          %{kind: "future_private_event", payload: %{"secret" => "FUTURE_SECRET_SENTINEL"}},
          Events.make_statement("Bram", "Alice was a wolf.")
        ]
      )

    assert {:ok, dead_view} = Werewolf.player_projection(state, "Alice")
    assert dead_view["role_info"]["your_role"] == "werewolf"
    refute Map.has_key?(dead_view["role_info"], "wolf_chat_history")
    refute Map.has_key?(dead_view["role_info"], "your_journal")
    assert dead_view["discussion"]["meeting_transcripts"] == []
    refute inspect(dead_view) =~ "Kill Bram tonight"
    refute inspect(dead_view) =~ "Cora is my partner"
    refute inspect(dead_view) =~ "FUTURE_SECRET_SENTINEL"

    assert {:ok, public_view} = Werewolf.public_projection(state)
    assert public_view["final_roles"] == %{}
    refute inspect(public_view) =~ "Kill Bram tonight"
    refute inspect(public_view) =~ "choose_victim"
    refute inspect(public_view) =~ "FUTURE_SECRET_SENTINEL"

    completed = put_in(state.world.status, "game_over")
    assert {:ok, completed_player_view} = Werewolf.player_projection(completed, "Bram")
    assert completed_player_view["final_roles"]["Cora"] == "werewolf"

    assert Enum.find(completed_player_view["world"]["players"], &(&1["name"] == "Cora"))["role"] ==
             "werewolf"

    assert {:ok, completed_view} = Werewolf.public_projection(completed)
    assert completed_view["final_roles"]["Alice"] == "werewolf"
  end
end
