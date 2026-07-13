defmodule LemonSim.Examples.WerewolfUpdaterTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.Werewolf.{Events, Roles, Updater}
  alias LemonSim.Examples.Werewolf.Updaters.{Meetings, NightResolution, Voting}
  alias LemonSim.Kernel.State

  test "day discussion advances to a second round before voting when enough players are alive" do
    players = sample_players()
    first_round = Roles.discussion_turn_order(players, 1, 1)
    second_round = Roles.discussion_turn_order(players, 1, 2)
    last_speaker = List.last(first_round)

    state =
      State.new(
        sim_id: "werewolf-test",
        world: %{
          players: players,
          phase: "day_discussion",
          day_number: 1,
          active_actor_id: last_speaker,
          turn_order: first_round,
          discussion_round: 1,
          discussion_round_limit: 2,
          night_actions: %{},
          night_history: [],
          discussion_transcript: [],
          votes: %{},
          vote_history: [],
          elimination_log: [],
          seer_history: [],
          status: "in_progress",
          winner: nil
        }
      )

    expected_prompt = "#{hd(second_round)} discussion round 2"

    assert {:ok, next_state, {:decide, ^expected_prompt}} =
             Updater.apply_event(
               state,
               Events.make_statement(last_speaker, "Round one wrap-up."),
               []
             )

    assert next_state.world.phase == "day_discussion"
    assert next_state.world.discussion_round == 2
    assert next_state.world.turn_order == second_round
    assert next_state.world.active_actor_id == hd(second_round)
    assert List.last(next_state.world.discussion_transcript).statement == "Round one wrap-up."
  end

  test "day discussion transitions to voting after the final discussion round" do
    players = sample_players()
    second_round = Roles.discussion_turn_order(players, 1, 2)
    last_speaker = List.last(second_round)
    voting_order = Roles.voting_turn_order(players, 1)

    state =
      State.new(
        sim_id: "werewolf-test",
        world: %{
          players: players,
          phase: "day_discussion",
          day_number: 1,
          active_actor_id: last_speaker,
          turn_order: second_round,
          discussion_round: 2,
          discussion_round_limit: 2,
          night_actions: %{},
          night_history: [],
          discussion_transcript: [],
          votes: %{},
          vote_history: [],
          elimination_log: [],
          seer_history: [],
          status: "in_progress",
          winner: nil
        }
      )

    expected_prompt = "#{hd(voting_order)} vote"

    assert {:ok, next_state, {:decide, ^expected_prompt}} =
             Updater.apply_event(state, Events.make_statement(last_speaker, "Time to vote."), [])

    assert next_state.world.phase == "day_voting"
    assert next_state.world.discussion_round == 0
    assert next_state.world.discussion_round_limit == 0
    assert next_state.world.turn_order == voting_order
    assert next_state.world.active_actor_id == hd(voting_order)
  end

  test "discussion hard cap forces voting even if an accusation extends turn order" do
    players = sample_players()
    discussion_order = Roles.discussion_turn_order(players, 1, 1)
    voting_order = Roles.voting_turn_order(players, 1)

    state =
      State.new(
        sim_id: "werewolf-hard-cap",
        world: %{
          players: players,
          phase: "day_discussion",
          day_number: 1,
          active_actor_id: hd(discussion_order),
          turn_order: discussion_order,
          discussion_round: 1,
          discussion_round_limit: 2,
          discussion_turn_count: 0,
          discussion_turn_limit: 1,
          night_actions: %{},
          night_history: [],
          discussion_transcript: [],
          votes: %{},
          vote_history: [],
          elimination_log: [],
          seer_history: [],
          status: "in_progress",
          winner: nil
        }
      )

    expected_prompt = "#{hd(voting_order)} vote"

    assert {:ok, next_state, {:decide, ^expected_prompt}} =
             Updater.apply_event(
               state,
               Events.make_accusation(hd(discussion_order), "Bram", "Answer this directly."),
               []
             )

    assert next_state.world.phase == "day_voting"
    assert next_state.world.discussion_turn_count == 0
    assert next_state.world.discussion_turn_limit == 0
    assert next_state.world.turn_order == voting_order
    assert next_state.world.active_actor_id == hd(voting_order)
  end

  test "accusation pulls a future speaker forward once and then discussion keeps moving" do
    players = sample_players()
    discussion_order = Roles.discussion_turn_order(players, 1, 1)

    state =
      State.new(
        sim_id: "werewolf-accusation-order",
        world: %{
          players: players,
          phase: "day_discussion",
          day_number: 1,
          active_actor_id: "Alice",
          turn_order: discussion_order,
          discussion_round: 1,
          discussion_round_limit: 1,
          discussion_turn_count: 0,
          discussion_turn_limit: length(discussion_order),
          night_actions: %{},
          night_history: [],
          discussion_transcript: [],
          votes: %{},
          vote_history: [],
          elimination_log: [],
          seer_history: [],
          status: "in_progress",
          winner: nil
        }
      )

    assert {:ok, after_accusation, {:decide, "Dane discussion turn"}} =
             Updater.apply_event(
               state,
               Events.make_accusation("Alice", "Dane", "Answer this directly."),
               []
             )

    assert after_accusation.world.turn_order == ["Alice", "Dane", "Bram", "Cora", "Esme"]
    assert after_accusation.world.active_actor_id == "Dane"

    assert {:ok, after_response, {:decide, "Bram discussion turn"}} =
             Updater.apply_event(
               after_accusation,
               Events.make_statement("Dane", "Here's my defense."),
               []
             )

    assert after_response.world.active_actor_id == "Bram"
    assert after_response.world.turn_order == ["Alice", "Dane", "Bram", "Cora", "Esme"]
  end

  test "counter-accusation does not bounce discussion back to an earlier speaker" do
    players = sample_players()

    state =
      State.new(
        sim_id: "werewolf-counter-accusation",
        world: %{
          players: players,
          phase: "day_discussion",
          day_number: 1,
          active_actor_id: "Dane",
          turn_order: ["Alice", "Dane", "Bram", "Cora", "Esme"],
          discussion_round: 1,
          discussion_round_limit: 1,
          discussion_turn_count: 1,
          discussion_turn_limit: 5,
          night_actions: %{},
          night_history: [],
          discussion_transcript: [
            %{
              player: "Alice",
              statement: "Answer this directly.",
              type: "accusation",
              target: "Dane"
            }
          ],
          votes: %{},
          vote_history: [],
          elimination_log: [],
          seer_history: [],
          status: "in_progress",
          winner: nil
        }
      )

    assert {:ok, next_state, {:decide, "Bram discussion turn"}} =
             Updater.apply_event(
               state,
               Events.make_accusation("Dane", "Alice", "You're deflecting."),
               []
             )

    assert next_state.world.active_actor_id == "Bram"
    assert next_state.world.turn_order == ["Alice", "Dane", "Bram", "Cora", "Esme"]
  end

  test "seer investigation resolves on night 1" do
    state =
      State.new(
        sim_id: "werewolf-seer-night-1-reject",
        world: %{
          players: %{
            "Cora" => %{role: "seer", status: "alive"},
            "Nora" => %{role: "werewolf", status: "alive"},
            "Dane" => %{role: "doctor", status: "alive"}
          },
          phase: "night",
          day_number: 1,
          active_actor_id: "Cora",
          turn_order: ["Cora", "Dane", "Nora"],
          discussion_transcript: [],
          votes: %{},
          vote_history: [],
          elimination_log: [],
          seer_history: [],
          night_actions: %{},
          night_history: [],
          status: "in_progress",
          winner: nil
        }
      )

    assert {:ok, next_state, {:decide, "Dane night action"}} =
             Updater.apply_event(state, Events.investigate_player("Cora", "Nora"), [])

    assert next_state.world.phase == "night"

    assert next_state.world.night_actions["Cora"] == %{
             action: "investigate",
             target: "Nora",
             result: "werewolf"
           }

    assert next_state.world.seer_history == [%{target: "Nora", role: "werewolf"}]
  end

  test "meeting resolver honors non-mutual directed requests when seats are available" do
    state =
      State.new(
        sim_id: "werewolf-directed-meetings",
        world: %{
          players: sample_players(),
          phase: "meeting_selection",
          day_number: 1,
          active_actor_id: "Esme",
          turn_order: ["Alice", "Bram", "Cora", "Dane", "Esme"],
          meeting_requests: %{
            "Alice" => "Dane",
            "Bram" => "Cora",
            "Cora" => "Alice",
            "Dane" => "Bram"
          },
          meeting_pairs: [],
          meeting_transcripts: [],
          current_meeting_messages: [],
          status: "in_progress"
        }
      )

    assert {:ok, next_state, {:decide, "Alice meeting with Dane"}} =
             Updater.apply_event(state, Events.request_meeting("Esme", "Alice"), [])

    assert next_state.world.meeting_pairs == [["Alice", "Dane"], ["Bram", "Cora"]]
    assert next_state.world.turn_order == ["Alice", "Dane"]
  end

  test "rejected actions cannot write another player's private journal" do
    state = discussion_state("Alice")

    event =
      Events.make_statement("Bram", "I should not be speaking.")
      |> Map.update!(:payload, &Map.put(&1, "thought", "forged private note"))

    assert {:ok, next_state, {:decide, "not the active actor"}} =
             Updater.apply_event(state, event, [])

    assert next_state.world.journals == %{}
    assert List.last(next_state.recent_events).kind == "action_rejected"
    refute Enum.any?(next_state.recent_events, &(&1.kind == "make_statement"))
  end

  test "anonymous letters require the active player's inventory and consume one item" do
    state = discussion_state("Alice")

    assert {:ok, rejected, {:decide, "item is not in your inventory"}} =
             Updater.apply_event(state, Events.anonymous_message("Alice", "Watch Bram."), [])

    assert rejected.world.discussion_transcript == []

    state =
      put_in(state.world.player_items, %{
        "Alice" => [%{type: "anonymous_letter", found_day: 1}]
      })

    assert {:ok, accepted, {:decide, _prompt}} =
             Updater.apply_event(state, Events.anonymous_message("Alice", "Watch Bram."), [])

    assert accepted.world.player_items["Alice"] == []
    assert List.last(accepted.world.discussion_transcript).player == "Anonymous"
  end

  test "night items require the right phase and actual ownership" do
    state = night_action_state("Alice", "villager")

    forged =
      LemonSim.Kernel.Event.new("use_item", %{"player_id" => "Alice", "item_type" => "lock"})

    assert {:ok, rejected, {:decide, "item is not in your inventory"}} =
             Updater.apply_event(state, forged, [])

    assert rejected.world.night_actions == %{}

    state = put_in(state.world.player_items, %{"Alice" => [%{type: "lock"}]})

    assert {:ok, accepted, _signal} = Updater.apply_event(state, forged, [])
    assert accepted.world.player_items["Alice"] == []
  end

  test "night actions reject roles that were not offered the action" do
    wolf_state = night_action_state("Cora", "werewolf")

    assert {:ok, after_sleep, {:decide, "wrong role for this action"}} =
             Updater.apply_event(wolf_state, Events.sleep("Cora"), [])

    seer_state = night_action_state("Dane", "seer", 2)

    assert {:ok, after_wander, {:decide, "wrong role for this action"}} =
             Updater.apply_event(seer_state, Events.night_wander("Dane"), [])

    assert after_sleep.world.night_actions == %{}
    assert after_wander.world.night_actions == %{}
  end

  test "voting rejects skip and non-candidate runoff targets" do
    state = voting_state("day_voting", nil)

    assert {:ok, skipped, {:decide, "invalid target"}} =
             Updater.apply_event(state, Events.cast_vote("Esme", "skip"), [])

    runoff = voting_state("runoff_voting", ["Alice", "Bram"])

    assert {:ok, forged, {:decide, "invalid target"}} =
             Updater.apply_event(runoff, Events.cast_vote("Esme", "Cora"), [])

    assert skipped.world.votes == %{}
    assert forged.world.votes == %{}
  end

  test "runoff selection is deterministic when candidates are tied" do
    state =
      voting_state("day_voting", nil)
      |> put_in([Access.key!(:world), Access.key!(:votes)], %{
        "Alice" => "Bram",
        "Bram" => "Cora",
        "Cora" => "Bram",
        "Dane" => "Cora"
      })

    assert {:ok, next_state, {:decide, _prompt}} =
             Updater.apply_event(state, Events.cast_vote("Esme", "Alice"), [])

    assert next_state.world.phase == "runoff_discussion"
    assert next_state.world.runoff_candidates == ["Bram", "Cora"]
  end

  test "majority ballots remain archived after the condemned player's last words" do
    ballots = %{
      "Alice" => "Bram",
      "Cora" => "Bram",
      "Dane" => "Bram"
    }

    state =
      voting_state("day_voting", nil)
      |> put_in([Access.key!(:world), Access.key!(:votes)], ballots)

    assert {:ok, last_words_state, {:decide, "Bram last words"}} =
             Updater.apply_event(state, Events.cast_vote("Esme", "Alice"), [])

    expected_ballots = Map.put(ballots, "Esme", "Alice")
    assert last_words_state.world.past_votes[1] == expected_ballots

    assert {:ok, night_state, {:decide, _prompt}} =
             Updater.apply_event(
               last_words_state,
               Events.make_last_words("Bram", "The village will regret this."),
               []
             )

    assert night_state.world.past_votes[1] == expected_ballots
  end

  test "free-form action text is bounded" do
    state = discussion_state("Alice")

    assert {:ok, blank, {:decide, "message cannot be empty"}} =
             Updater.apply_event(state, Events.make_statement("Alice", "   "), [])

    assert {:ok, oversized, {:decide, "message is too long"}} =
             Updater.apply_event(
               state,
               Events.make_statement("Alice", String.duplicate("x", 2_001)),
               []
             )

    assert {:ok, padded, {:decide, "message is too long"}} =
             Updater.apply_event(
               state,
               Events.make_statement("Alice", String.duplicate(" ", 2_001) <> "hello"),
               []
             )

    assert blank.world.discussion_transcript == []
    assert oversized.world.discussion_transcript == []
    assert padded.world.discussion_transcript == []
    refute Enum.any?(oversized.recent_events, &(&1.kind == "make_statement"))
  end

  test "oversized private thoughts reject the action instead of leaking into events" do
    state = discussion_state("Alice")

    event =
      Events.make_statement("Alice", "My public read.")
      |> Map.update!(:payload, &Map.put(&1, "thought", String.duplicate("x", 2_001)))

    assert {:ok, next_state, {:decide, "message is too long"}} =
             Updater.apply_event(state, event, [])

    assert next_state.world.discussion_transcript == []
    assert next_state.world.journals == %{}
    assert Enum.map(next_state.recent_events, & &1.kind) == ["action_rejected"]
  end

  test "night resolution handles seer targets without crashing evidence generation" do
    players = %{
      "Nora" => %{role: "werewolf", status: "alive"},
      "Cora" => %{role: "seer", status: "alive"},
      "Dane" => %{role: "doctor", status: "alive"},
      "Iris" => %{role: "villager", status: "alive"},
      "Lena" => %{role: "villager", status: "alive"}
    }

    state =
      State.new(
        sim_id: "werewolf-night-resolution",
        world: %{
          players: players,
          phase: "night",
          day_number: 2,
          active_actor_id: "Lena",
          turn_order: ["Nora", "Cora", "Dane", "Iris", "Lena"],
          night_actions: %{
            "Nora" => %{action: "choose_victim", target: "Cora"},
            "Cora" => %{action: "investigate", target: "Nora", result: "werewolf"},
            "Dane" => %{action: "protect", target: "Cora"},
            "Iris" => %{action: "wander"}
          },
          discussion_transcript: [],
          votes: %{},
          vote_history: [],
          elimination_log: [],
          seer_history: [%{target: "Nora", role: "werewolf"}],
          night_history: [],
          evidence_tokens: [],
          wanderer_results: [],
          village_event_history: [],
          current_village_event: nil,
          player_items: %{},
          meeting_requests: %{},
          meeting_pairs: [],
          meeting_transcripts: [],
          current_meeting_index: 0,
          current_meeting_messages: [],
          discussion_round: 0,
          discussion_round_limit: 0,
          past_transcripts: %{},
          past_votes: %{},
          pending_elimination: nil,
          last_words: [],
          status: "in_progress",
          winner: nil
        }
      )

    assert {:ok, next_state, {:decide, "Cora meeting with Dane"}} =
             Updater.apply_event(state, Events.sleep("Lena"), [])

    assert next_state.world.phase == "private_meeting"
    assert next_state.world.active_actor_id == "Cora"
    assert next_state.world.night_actions == %{}
  end

  test "seer killed at night does not receive last words" do
    players = %{
      "Alice" => %{role: "werewolf", status: "alive"},
      "Bram" => %{role: "seer", status: "alive"},
      "Cora" => %{role: "doctor", status: "alive"},
      "Dane" => %{role: "villager", status: "alive"},
      "Esme" => %{role: "villager", status: "alive"}
    }

    state =
      State.new(
        sim_id: "werewolf-seer-no-last-words",
        world: %{
          players: players,
          phase: "night",
          day_number: 2,
          active_actor_id: "Esme",
          turn_order: ["Alice", "Bram", "Cora", "Dane", "Esme"],
          night_actions: %{
            "Alice" => %{action: "choose_victim", target: "Bram"},
            "Bram" => %{action: "investigate", target: "Alice", result: "werewolf"},
            "Cora" => %{action: "protect", target: "Cora"},
            "Dane" => %{action: "sleep"}
          },
          discussion_transcript: [],
          votes: %{},
          vote_history: [],
          elimination_log: [],
          seer_history: [%{target: "Alice", role: "werewolf"}],
          night_history: [],
          evidence_tokens: [],
          wanderer_results: [],
          village_event_history: [],
          current_village_event: nil,
          player_items: %{},
          meeting_requests: %{},
          meeting_pairs: [],
          meeting_transcripts: [],
          current_meeting_index: 0,
          current_meeting_messages: [],
          discussion_round: 0,
          discussion_round_limit: 0,
          past_transcripts: %{},
          past_votes: %{},
          pending_elimination: nil,
          last_words: [],
          status: "in_progress",
          winner: nil
        }
      )

    assert {:ok, next_state, {:decide, "Alice meeting with Cora"}} =
             Updater.apply_event(state, Events.sleep("Esme"), [])

    assert next_state.world.phase == "private_meeting"
    assert next_state.world.pending_elimination == nil
    assert next_state.world.players["Bram"].status == "dead"
    assert next_state.world.last_words == []
  end

  for {event_type, expected_rounds} <- [{"blizzard", 1}, {"festival", 3}] do
    test "#{event_type} adjusts discussion limits after private meetings" do
      state =
        State.new(
          sim_id: "werewolf-#{unquote(event_type)}-limits",
          world: %{
            players: sample_players(),
            phase: "private_meeting",
            day_number: 2,
            active_actor_id: "Alice",
            turn_order: ["Alice", "Bram"],
            current_meeting_index: 0,
            current_meeting_messages: [],
            meeting_pairs: [["Alice", "Bram"]],
            meeting_transcripts: [],
            current_village_event: %{type: unquote(event_type)},
            status: "in_progress"
          }
        )

      assert {:ok, after_first, {:decide, "Bram meeting message"}} =
               Updater.apply_event(state, Events.meeting_message("Alice", "My first read."), [])

      assert {:ok, next_state, {:decide, _prompt}} =
               Updater.apply_event(
                 after_first,
                 Events.meeting_message("Bram", "Here is mine."),
                 []
               )

      assert next_state.world.phase == "day_discussion"
      assert next_state.world.discussion_round_limit == unquote(expected_rounds)
      assert next_state.world.discussion_turn_limit == unquote(expected_rounds) * 5
    end
  end

  test "a lock save is not counted as a successful wolf kill" do
    state =
      night_resolution_state(%{
        "Bram" => [%{type: "lock", found_day: 1}]
      })

    state =
      put_in(state.world.night_actions["Bram"], %{action: "use_item", item: "lock"})

    assert {:ok, next_state, {:decide, _prompt}} = NightResolution.resolve_night(state)

    assert next_state.world.players["Bram"].status == "alive"
    assert night_resolved_event(next_state).payload["saved"] == true
    refute wolf_history(next_state).successful
  end

  test "wolfsbane is consumed and is not counted as a successful wolf kill" do
    state = night_resolution_state(%{"Bram" => [%{type: "wolfsbane", found_day: 1}]})

    assert {:ok, next_state, {:decide, _prompt}} = NightResolution.resolve_night(state)

    assert next_state.world.players["Bram"].status == "alive"
    assert night_resolved_event(next_state).payload["saved"] == true
    refute wolf_history(next_state).successful
    refute Enum.any?(next_state.world.player_items["Bram"], &(&1.type == "wolfsbane"))
  end

  test "malformed event payloads return structured errors without changing state" do
    state = discussion_state("Alice")

    for payload <- [nil, [], "invalid", 42] do
      raw_event = %{kind: "make_statement", payload: payload}

      assert {:error, {:invalid_event_payload, "make_statement"}} =
               Updater.apply_event(state, raw_event, [])
    end

    assert {:error, :invalid_event} = Updater.apply_event(state, :invalid, [])
    assert state.recent_events == []
  end

  test "malformed player ids are rejected without raising" do
    state = discussion_state("Alice")

    raw_event = %{
      kind: "make_statement",
      payload: %{"player_id" => %{"forged" => true}, "statement" => "Trust me."}
    }

    assert {:ok, next_state, {:decide, "not the active actor"}} =
             Updater.apply_event(state, raw_event, [])

    assert [%{kind: "action_rejected", payload: payload}] = next_state.recent_events
    assert payload["player_id"] == "unknown"
  end

  test "wolf chat history survives the current-night transcript reset" do
    players = sample_players()

    state =
      State.new(
        sim_id: "werewolf-wolf-chat-history",
        world: %{
          players: players,
          phase: "wolf_discussion",
          day_number: 1,
          active_actor_id: "Cora",
          turn_order: ["Cora"],
          wolf_chat_transcript: [],
          wolf_chat_history: [],
          night_actions: %{},
          status: "in_progress"
        }
      )

    assert {:ok, after_chat, {:decide, _}} =
             Updater.apply_event(state, Events.wolf_chat("Cora", "Pressure Alice tomorrow."), [])

    assert after_chat.world.wolf_chat_history == [
             %{day: 1, player: "Cora", message: "Pressure Alice tomorrow."}
           ]

    assert {:ok, next_night, {:decide, _}} =
             Voting.transition_to_night(after_chat, players, [], [], [])

    assert next_night.world.wolf_chat_transcript == []

    assert next_night.world.wolf_chat_history == [
             %{day: 1, player: "Cora", message: "Pressure Alice tomorrow."}
           ]
  end

  test "classic rules skip private meetings and enter public discussion" do
    state =
      State.new(
        sim_id: "werewolf-classic-transition",
        world: %{
          players: sample_players(),
          phase: "night",
          day_number: 2,
          rules: LemonSim.Examples.Werewolf.RulesConfig.for_preset("classic"),
          current_village_event: nil,
          discussion_transcript: [],
          votes: %{},
          meeting_requests: %{},
          meeting_pairs: [],
          status: "in_progress"
        }
      )

    assert {:ok, next_state, {:decide, _message}} =
             Meetings.transition_to_meetings_or_discussion(state)

    assert next_state.world.phase == "day_discussion"
    assert next_state.world.meeting_pairs == []
    assert is_binary(next_state.world.active_actor_id)
  end

  defp night_resolution_state(player_items) do
    State.new(
      sim_id: "werewolf-item-save",
      world: %{
        players: sample_players(),
        phase: "night",
        day_number: 1,
        active_actor_id: nil,
        turn_order: [],
        night_actions: %{
          "Cora" => %{action: "choose_victim", target: "Bram"}
        },
        night_history: [],
        evidence_tokens: [],
        wanderer_results: [],
        village_event_history: [],
        current_village_event: nil,
        player_items: player_items,
        meeting_requests: %{},
        meeting_pairs: [],
        meeting_transcripts: [],
        current_meeting_index: 0,
        current_meeting_messages: [],
        discussion_transcript: [],
        votes: %{},
        vote_history: [],
        elimination_log: [],
        seer_history: [],
        past_transcripts: %{},
        past_votes: %{},
        pending_elimination: nil,
        last_words: [],
        status: "in_progress",
        winner: nil
      }
    )
  end

  defp discussion_state(active_actor) do
    State.new(
      sim_id: "werewolf-discussion-validation",
      world: %{
        players: sample_players(),
        phase: "day_discussion",
        day_number: 1,
        active_actor_id: active_actor,
        turn_order: ["Alice", "Bram", "Cora", "Dane", "Esme"],
        discussion_round: 1,
        discussion_round_limit: 1,
        discussion_turn_count: 0,
        discussion_turn_limit: 5,
        discussion_transcript: [],
        player_items: %{},
        journals: %{},
        status: "in_progress"
      }
    )
  end

  defp night_action_state(active_actor, role, day_number \\ 1) do
    players = Map.put(sample_players(), active_actor, %{role: role, status: "alive"})

    State.new(
      sim_id: "werewolf-night-validation",
      world: %{
        players: players,
        phase: "night",
        day_number: day_number,
        active_actor_id: active_actor,
        turn_order: [active_actor],
        night_actions: %{},
        night_history: [],
        evidence_tokens: [],
        wanderer_results: [],
        village_event_history: [],
        player_items: %{},
        discussion_transcript: [],
        votes: %{},
        vote_history: [],
        elimination_log: [],
        seer_history: [],
        past_transcripts: %{},
        past_votes: %{},
        status: "in_progress"
      }
    )
  end

  defp voting_state(phase, runoff_candidates) do
    State.new(
      sim_id: "werewolf-vote-validation",
      world: %{
        players: sample_players(),
        phase: phase,
        day_number: 1,
        active_actor_id: "Esme",
        turn_order: ["Alice", "Bram", "Cora", "Dane", "Esme"],
        votes: %{},
        vote_history: [],
        runoff_candidates: runoff_candidates,
        discussion_transcript: [],
        elimination_log: [],
        status: "in_progress"
      }
    )
  end

  defp night_resolved_event(state) do
    Enum.find(state.recent_events, &(&1.kind == "night_resolved"))
  end

  defp wolf_history(state) do
    Enum.find(state.world.night_history, &(&1.player == "Cora"))
  end

  defp sample_players do
    %{
      "Alice" => %{role: "villager", status: "alive"},
      "Bram" => %{role: "doctor", status: "alive"},
      "Cora" => %{role: "werewolf", status: "alive"},
      "Dane" => %{role: "seer", status: "alive"},
      "Esme" => %{role: "villager", status: "alive"}
    }
  end
end
