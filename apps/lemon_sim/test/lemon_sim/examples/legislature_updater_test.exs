defmodule LemonSim.Examples.LegislatureUpdaterTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.Legislature.{Bills, Events, Updater}
  alias LemonSim.State

  defp base_world(overrides \\ %{}) do
    player_ids = ["player_1", "player_2", "player_3", "player_4", "player_5"]

    base = %{
      bills: Bills.all_bills(),
      players: %{
        "player_1" => %{
          faction: "Rural Caucus",
          faction_id: "rural",
          preference_ranking: ["infrastructure", "defense", "education", "healthcare", "environment"],
          political_capital: 100,
          status: "alive"
        },
        "player_2" => %{
          faction: "Progressive Coalition",
          faction_id: "progressive",
          preference_ranking: ["healthcare", "environment", "education", "defense", "infrastructure"],
          political_capital: 100,
          status: "alive"
        },
        "player_3" => %{
          faction: "Conservative Alliance",
          faction_id: "conservative",
          preference_ranking: ["defense", "infrastructure", "education", "healthcare", "environment"],
          political_capital: 100,
          status: "alive"
        },
        "player_4" => %{
          faction: "Moderate Democrats",
          faction_id: "centrist",
          preference_ranking: ["healthcare", "education", "infrastructure", "defense", "environment"],
          political_capital: 100,
          status: "alive"
        },
        "player_5" => %{
          faction: "Liberty Caucus",
          faction_id: "libertarian",
          preference_ranking: ["infrastructure", "education", "healthcare", "defense", "environment"],
          political_capital: 100,
          status: "alive"
        }
      },
      session: 1,
      max_sessions: 3,
      phase: "caucus",
      active_actor_id: "player_1",
      turn_order: player_ids,
      caucus_messages: Enum.into(player_ids, %{}, &{&1, []}),
      caucus_messages_sent: %{},
      message_history: [],
      floor_statements: [],
      proposed_amendments: [],
      vote_record: %{},
      scores: Enum.into(player_ids, %{}, &{&1, 0}),
      caucus_done: MapSet.new(),
      floor_debate_done: MapSet.new(),
      amendment_done: MapSet.new(),
      amendment_vote_done: MapSet.new(),
      votes_cast: MapSet.new(),
      journals: %{},
      status: "in_progress",
      winner: nil
    }

    Map.merge(base, overrides)
  end

  defp new_state(world_overrides \\ %{}) do
    State.new(
      sim_id: "legislature-test",
      world: base_world(world_overrides)
    )
  end

  # -- Caucus tests --

  test "send_message records message in recipient inbox without leaking to others" do
    state = new_state()

    assert {:ok, next_state, {:decide, _}} =
             Updater.apply_event(
               state,
               Events.send_message("player_1", "player_2", "Let's trade: I vote healthcare if you vote infrastructure."),
               []
             )

    # Recipient has message
    inbox = next_state.world.caucus_messages["player_2"]
    assert length(inbox) == 1
    assert List.last(inbox)["message"] =~ "healthcare"
    assert List.last(inbox)["from"] == "player_1"

    # Others do not
    assert next_state.world.caucus_messages["player_3"] == []

    # Message history records metadata only (not content)
    assert [%{session: 1, from: "player_1", to: "player_2"}] =
             next_state.world.message_history
  end

  test "send_message enforces 3-message quota per session" do
    # Pre-fill 3 messages for player_1 in session 1
    state =
      new_state(%{
        caucus_messages_sent: %{"player_1" => %{1 => 3}}
      })

    assert {:ok, next_state, {:decide, msg}} =
             Updater.apply_event(
               state,
               Events.send_message("player_1", "player_2", "One more message"),
               []
             )

    assert msg =~ "quota"
    # No new message added
    assert next_state.world.caucus_messages["player_2"] == []
  end

  test "propose_trade delivers trade proposal to recipient's inbox" do
    state = new_state()

    assert {:ok, next_state, {:decide, _}} =
             Updater.apply_event(
               state,
               Events.propose_trade("player_1", "player_2", "infrastructure", "healthcare"),
               []
             )

    inbox = next_state.world.caucus_messages["player_2"]
    assert length(inbox) == 1
    msg = List.last(inbox)
    assert msg["type"] == "trade_proposal"
    assert msg["bill_a"] == "infrastructure"
    assert msg["bill_b"] == "healthcare"
  end

  test "end_caucus transitions all players to floor_debate when all done" do
    player_ids = ["player_1", "player_2", "player_3", "player_4", "player_5"]

    # Pre-fill all but player_1 as done
    already_done = MapSet.new(["player_2", "player_3", "player_4", "player_5"])

    state = new_state(%{caucus_done: already_done})

    assert {:ok, next_state, {:decide, _}} =
             Updater.apply_event(state, Events.end_caucus("player_1"), [])

    assert next_state.world.phase == "floor_debate"
    assert next_state.world.active_actor_id == List.first(player_ids)
  end

  test "end_caucus advances to next player when not all done" do
    state = new_state()

    assert {:ok, next_state, {:decide, msg}} =
             Updater.apply_event(state, Events.end_caucus("player_1"), [])

    assert next_state.world.phase == "caucus"
    assert next_state.world.active_actor_id == "player_2"
    assert msg =~ "player_2"
  end

  # -- Floor debate tests --

  test "make_speech records speech in floor_statements" do
    state = new_state(%{phase: "floor_debate"})

    assert {:ok, next_state, {:decide, _}} =
             Updater.apply_event(
               state,
               Events.make_speech("player_1", "infrastructure", "Infrastructure is critical for our rural communities."),
               []
             )

    assert length(next_state.world.floor_statements) == 1
    stmt = List.first(next_state.world.floor_statements)
    assert stmt["player_id"] == "player_1"
    assert stmt["bill_id"] == "infrastructure"
    assert stmt["session"] == 1
  end

  test "end_floor_debate transitions to amendment when all done" do
    already_done = MapSet.new(["player_2", "player_3", "player_4", "player_5"])

    state = new_state(%{phase: "floor_debate", floor_debate_done: already_done})

    assert {:ok, next_state, {:decide, _}} =
             Updater.apply_event(state, Events.end_floor_debate("player_1"), [])

    assert next_state.world.phase == "amendment"
  end

  # -- Amendment tests --

  test "propose_amendment deducts capital and records amendment" do
    state = new_state(%{phase: "amendment"})

    assert {:ok, next_state, {:decide, _}} =
             Updater.apply_event(
               state,
               Events.propose_amendment("player_1", "infrastructure", "Add rural broadband provisions"),
               []
             )

    assert next_state.world.players["player_1"].political_capital == 80
    assert length(next_state.world.proposed_amendments) == 1

    amendment = List.first(next_state.world.proposed_amendments)
    assert amendment.proposer_id == "player_1"
    assert amendment.bill_id == "infrastructure"
  end

  test "propose_amendment rejects when insufficient capital" do
    state = new_state(%{
      phase: "amendment",
      players: %{
        "player_1" => %{
          faction: "Rural Caucus",
          preference_ranking: ["infrastructure", "defense", "education", "healthcare", "environment"],
          political_capital: 10,
          status: "alive"
        }
      }
    })

    assert {:ok, next_state, {:decide, msg}} =
             Updater.apply_event(
               state,
               Events.propose_amendment("player_1", "infrastructure", "Too expensive"),
               []
             )

    assert msg =~ "capital"
    assert next_state.world.proposed_amendments == []
  end

  test "lobby spends capital and records lobby support" do
    state = new_state(%{phase: "amendment"})

    assert {:ok, next_state, {:decide, _}} =
             Updater.apply_event(
               state,
               Events.lobby("player_1", "infrastructure", 30),
               []
             )

    assert next_state.world.players["player_1"].political_capital == 70
    bill = next_state.world.bills["infrastructure"]
    assert Map.get(bill, :lobby_support, %{})["player_1"] == 30
  end

  # -- Amendment vote tests --

  test "cast_amendment_vote records vote on amendment" do
    amendment = %{
      id: "amendment_1_player_2_healthcare",
      proposer_id: "player_2",
      bill_id: "healthcare",
      amendment_text: "Add mental health coverage",
      session: 1,
      votes: %{},
      passed: nil
    }

    state = new_state(%{
      phase: "amendment_vote",
      proposed_amendments: [amendment]
    })

    assert {:ok, next_state, {:decide, _}} =
             Updater.apply_event(
               state,
               Events.cast_amendment_vote("player_1", "amendment_1_player_2_healthcare", "yes", "healthcare"),
               []
             )

    updated = List.first(next_state.world.proposed_amendments)
    assert Map.get(updated, :votes, %{})["player_1"] == "yes"
  end

  test "end_amendment_vote resolves amendments when all players done" do
    amendment = %{
      id: "amendment_1_player_2_healthcare",
      proposer_id: "player_2",
      bill_id: "healthcare",
      amendment_text: "Add mental health coverage",
      session: 1,
      votes: %{
        "player_1" => "yes",
        "player_2" => "yes",
        "player_3" => "yes",
        "player_4" => "no",
        "player_5" => "no"
      },
      passed: nil
    }

    already_done = MapSet.new(["player_2", "player_3", "player_4", "player_5"])

    state = new_state(%{
      phase: "amendment_vote",
      amendment_vote_done: already_done,
      proposed_amendments: [amendment]
    })

    assert {:ok, next_state, {:decide, _}} =
             Updater.apply_event(state, Events.end_amendment_vote("player_1"), [])

    assert next_state.world.phase == "final_vote"

    resolved = List.first(next_state.world.proposed_amendments)
    # 3 yes vs 2 no -> majority passes
    assert Map.get(resolved, :passed) == true
  end

  # -- Final vote tests --

  test "cast_votes records votes and advances to next player" do
    state = new_state(%{phase: "final_vote"})

    votes = %{
      "infrastructure" => "yes",
      "healthcare" => "no",
      "defense" => "yes",
      "education" => "yes",
      "environment" => "no"
    }

    assert {:ok, next_state, {:decide, msg}} =
             Updater.apply_event(state, Events.cast_votes("player_1", votes), [])

    assert MapSet.member?(next_state.world.votes_cast, "player_1")
    assert next_state.world.vote_record["player_1"] == votes
    assert msg =~ "player_2"
  end

  test "cast_votes resolves bills and advances session when all players voted" do
    # All players have already voted except player_5 (last in turn order)
    prior_votes = %{
      "player_1" => %{"infrastructure" => "yes", "healthcare" => "yes", "defense" => "yes", "education" => "yes", "environment" => "no"},
      "player_2" => %{"infrastructure" => "yes", "healthcare" => "yes", "defense" => "no", "education" => "yes", "environment" => "yes"},
      "player_3" => %{"infrastructure" => "yes", "healthcare" => "no", "defense" => "yes", "education" => "no", "environment" => "no"},
      "player_4" => %{"infrastructure" => "no", "healthcare" => "yes", "defense" => "no", "education" => "yes", "environment" => "yes"}
    }

    already_voted = MapSet.new(["player_1", "player_2", "player_3", "player_4"])

    state = new_state(%{
      phase: "final_vote",
      active_actor_id: "player_5",
      votes_cast: already_voted,
      vote_record: prior_votes
    })

    final_vote = %{
      "infrastructure" => "yes",
      "healthcare" => "yes",
      "defense" => "no",
      "education" => "yes",
      "environment" => "no"
    }

    assert {:ok, next_state, {:decide, _}} =
             Updater.apply_event(state, Events.cast_votes("player_5", final_vote), [])

    # Should have advanced to session 2
    assert next_state.world.session == 2
    assert next_state.world.phase == "caucus"

    # Infrastructure: 4 yes, 1 no -> passed
    assert next_state.world.bills["infrastructure"].status == "passed"
    # Healthcare: 4 yes, 1 no -> passed
    assert next_state.world.bills["healthcare"].status == "passed"
    # Defense: 2 yes, 3 no -> failed
    assert next_state.world.bills["defense"].status == "failed"

    # Scores should be non-zero
    assert Enum.any?(next_state.world.scores, fn {_k, v} -> v > 0 end)
  end

  test "game ends after max sessions with highest score winner" do
    prior_votes = %{
      "player_1" => %{"infrastructure" => "yes", "healthcare" => "yes", "defense" => "yes", "education" => "yes", "environment" => "yes"},
      "player_2" => %{"infrastructure" => "yes", "healthcare" => "yes", "defense" => "yes", "education" => "yes", "environment" => "yes"},
      "player_3" => %{"infrastructure" => "yes", "healthcare" => "yes", "defense" => "yes", "education" => "yes", "environment" => "yes"},
      "player_4" => %{"infrastructure" => "yes", "healthcare" => "yes", "defense" => "yes", "education" => "yes", "environment" => "yes"}
    }

    already_voted = MapSet.new(["player_1", "player_2", "player_3", "player_4"])

    # Set session to max so this vote will end the game
    state = new_state(%{
      phase: "final_vote",
      session: 3,
      max_sessions: 3,
      active_actor_id: "player_5",
      votes_cast: already_voted,
      vote_record: prior_votes,
      scores: %{
        "player_1" => 50,
        "player_2" => 80,
        "player_3" => 40,
        "player_4" => 60,
        "player_5" => 30
      }
    })

    final_vote = %{
      "infrastructure" => "yes",
      "healthcare" => "yes",
      "defense" => "yes",
      "education" => "yes",
      "environment" => "yes"
    }

    assert {:ok, next_state, :skip} =
             Updater.apply_event(state, Events.cast_votes("player_5", final_vote), [])

    assert next_state.world.status == "won"
    assert next_state.world.winner != nil
  end

  # -- Validation tests --

  test "rejects action from wrong player" do
    state = new_state()

    assert {:ok, next_state, {:decide, msg}} =
             Updater.apply_event(
               state,
               Events.send_message("player_2", "player_3", "Hello"),
               []
             )

    assert msg =~ "active"
  end

  test "rejects action in wrong phase" do
    state = new_state(%{phase: "floor_debate"})

    assert {:ok, next_state, {:decide, msg}} =
             Updater.apply_event(
               state,
               Events.send_message("player_1", "player_2", "Hello"),
               []
             )

    assert msg =~ "phase"
  end

  test "rejects message to self" do
    state = new_state()

    assert {:ok, next_state, {:decide, msg}} =
             Updater.apply_event(
               state,
               Events.send_message("player_1", "player_1", "Talking to myself"),
               []
             )

    assert msg =~ "yourself"
  end

  test "rejects duplicate vote" do
    state = new_state(%{
      phase: "final_vote",
      votes_cast: MapSet.new(["player_1"]),
      vote_record: %{
        "player_1" => %{"infrastructure" => "yes", "healthcare" => "yes", "defense" => "yes", "education" => "yes", "environment" => "yes"}
      }
    })

    assert {:ok, next_state, {:decide, msg}} =
             Updater.apply_event(
               state,
               Events.cast_votes("player_1", %{
                 "infrastructure" => "yes",
                 "healthcare" => "yes",
                 "defense" => "yes",
                 "education" => "yes",
                 "environment" => "yes"
               }),
               []
             )

    assert msg =~ "voted"
  end
end
