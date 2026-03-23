defmodule LemonSim.Examples.StartupIncubatorUpdaterTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.StartupIncubator.{Events, Updater}
  alias LemonSim.State

  defp base_world(overrides \\ %{}) do
    Map.merge(
      %{
        players: %{
          "founder_1" => %{role: "founder", status: "active"},
          "founder_2" => %{role: "founder", status: "active"},
          "investor_1" => %{role: "investor", status: "active"}
        },
        startups: %{
          "founder_1" => %{
            sector: "ai",
            traction: 10,
            burn_rate: 50_000,
            funding_raised: 0,
            cash_on_hand: 100_000,
            valuation: 120_000,
            employees: 3,
            pivoted?: false
          },
          "founder_2" => %{
            sector: "fintech",
            traction: 8,
            burn_rate: 50_000,
            funding_raised: 0,
            cash_on_hand: 100_000,
            valuation: 96_000,
            employees: 2,
            pivoted?: false
          }
        },
        investors: %{
          "investor_1" => %{
            fund_size: 5_000_000,
            remaining_capital: 5_000_000,
            portfolio: [],
            sector_preferences: ["ai", "fintech"],
            risk_tolerance: "moderate"
          }
        },
        round: 1,
        max_rounds: 5,
        phase: "pitch",
        active_actor_id: "founder_1",
        turn_order: ["founder_1", "founder_2", "investor_1"],
        phase_done: MapSet.new(),
        term_sheets: %{},
        pending_answers: %{},
        market_conditions: %{
          "ai" => 12.0,
          "fintech" => 8.0,
          "healthtech" => 9.0,
          "edtech" => 6.0,
          "climatetech" => 7.0,
          "ecommerce" => 5.0
        },
        market_event_log: [],
        pitch_log: [],
        question_log: [],
        deal_history: [],
        journals: %{},
        status: "in_progress",
        winner: nil,
        final_scores: %{}
      },
      overrides
    )
  end

  defp base_state(world_overrides \\ %{}) do
    State.new(
      sim_id: "startup-incubator-test",
      world: base_world(world_overrides)
    )
  end

  # ---------------------------------------------------------------------------
  # Pitch phase
  # ---------------------------------------------------------------------------

  test "make_pitch records pitch in pitch_log and advances to next actor" do
    state = base_state()

    assert {:ok, next_state, {:decide, _}} =
             Updater.apply_event(
               state,
               Events.make_pitch("founder_1", "We are the next big AI unicorn! 10x growth QoQ."),
               []
             )

    pitch_log = next_state.world.pitch_log
    assert length(pitch_log) == 1
    assert hd(pitch_log)["founder_id"] == "founder_1"
    assert hd(pitch_log)["pitch_text"] =~ "AI unicorn"
    assert next_state.world.active_actor_id == "founder_2"
  end

  test "make_pitch fails when wrong phase" do
    state = base_state(%{phase: "operations"})

    assert {:ok, next_state, {:decide, msg}} =
             Updater.apply_event(
               state,
               Events.make_pitch("founder_1", "This shouldn't work"),
               []
             )

    assert msg =~ "wrong phase"
    assert next_state.world.pitch_log == []
  end

  test "make_pitch fails when not active actor" do
    state = base_state()

    assert {:ok, _next_state, {:decide, msg}} =
             Updater.apply_event(
               state,
               Events.make_pitch("founder_2", "jumping queue"),
               []
             )

    assert msg =~ "not the active player"
  end

  # ---------------------------------------------------------------------------
  # Due diligence phase
  # ---------------------------------------------------------------------------

  test "ask_question records in question_log" do
    state =
      base_state(%{
        phase: "due_diligence",
        active_actor_id: "investor_1"
      })

    assert {:ok, next_state, {:decide, _}} =
             Updater.apply_event(
               state,
               Events.ask_question("investor_1", "founder_1", "What is your real MRR?"),
               []
             )

    log = next_state.world.question_log
    assert length(log) >= 1
    last = List.last(log)
    assert last["investor_id"] == "investor_1"
    assert last["founder_id"] == "founder_1"
    assert last["question"] =~ "MRR"
  end

  test "answer_question records in question_log" do
    state =
      base_state(%{
        phase: "due_diligence",
        active_actor_id: "founder_1"
      })

    assert {:ok, next_state, {:decide, _}} =
             Updater.apply_event(
               state,
               Events.answer_question(
                 "founder_1",
                 "investor_1",
                 "MRR is $50K and growing 20% MoM."
               ),
               []
             )

    log = next_state.world.question_log
    assert Enum.any?(log, fn e -> Map.get(e, "founder_id") == "founder_1" end)
  end

  # ---------------------------------------------------------------------------
  # Negotiation phase
  # ---------------------------------------------------------------------------

  test "make_offer creates term sheet" do
    state =
      base_state(%{
        phase: "negotiation",
        active_actor_id: "investor_1"
      })

    assert {:ok, next_state, {:decide, _}} =
             Updater.apply_event(
               state,
               Events.make_offer("investor_1", "founder_1", 500_000, 15.0),
               []
             )

    term_sheets = next_state.world.term_sheets
    sheet = Map.get(term_sheets, "investor_1->founder_1")
    assert sheet != nil
    assert sheet["amount"] == 500_000
    assert sheet["equity_pct"] == 15.0
    assert sheet["status"] == "pending"
  end

  test "accept_deal closes deal and updates funding" do
    term_sheets = %{
      "investor_1->founder_1" => %{
        "investor_id" => "investor_1",
        "founder_id" => "founder_1",
        "amount" => 500_000,
        "equity_pct" => 15.0,
        "status" => "pending"
      }
    }

    state =
      base_state(%{
        phase: "negotiation",
        active_actor_id: "founder_1",
        term_sheets: term_sheets
      })

    assert {:ok, next_state, {:decide, _}} =
             Updater.apply_event(
               state,
               Events.accept_deal("founder_1", "investor_1"),
               []
             )

    startup = next_state.world.startups["founder_1"]
    assert startup.funding_raised == 500_000
    assert startup.cash_on_hand == 600_000

    investor = next_state.world.investors["investor_1"]
    assert investor.remaining_capital == 4_500_000
    assert length(investor.portfolio) == 1

    assert length(next_state.world.deal_history) == 1
    deal = hd(next_state.world.deal_history)
    assert deal["amount"] == 500_000
    assert deal["equity_pct"] == 15.0
  end

  test "reject_deal marks term sheet rejected" do
    term_sheets = %{
      "investor_1->founder_1" => %{
        "investor_id" => "investor_1",
        "founder_id" => "founder_1",
        "amount" => 100_000,
        "equity_pct" => 30.0,
        "status" => "pending"
      }
    }

    state =
      base_state(%{
        phase: "negotiation",
        active_actor_id: "founder_1",
        term_sheets: term_sheets
      })

    assert {:ok, next_state, {:decide, _}} =
             Updater.apply_event(
               state,
               Events.reject_deal("founder_1", "investor_1"),
               []
             )

    sheet = next_state.world.term_sheets["investor_1->founder_1"]
    assert sheet["status"] == "rejected"
    assert next_state.world.deal_history == []
  end

  test "make_offer fails when insufficient capital" do
    investors_broke = %{
      "investor_1" => %{
        fund_size: 5_000_000,
        remaining_capital: 10_000,
        portfolio: [],
        sector_preferences: ["ai"],
        risk_tolerance: "moderate"
      }
    }

    state =
      base_state(%{
        phase: "negotiation",
        active_actor_id: "investor_1",
        investors: investors_broke
      })

    assert {:ok, _next_state, {:decide, msg}} =
             Updater.apply_event(
               state,
               Events.make_offer("investor_1", "founder_1", 1_000_000, 20.0),
               []
             )

    assert msg =~ "insufficient funds"
  end

  # ---------------------------------------------------------------------------
  # Merges
  # ---------------------------------------------------------------------------

  test "merge_startups combines traction and employees" do
    state =
      base_state(%{
        phase: "negotiation",
        active_actor_id: "founder_1"
      })

    assert {:ok, next_state, {:decide, _}} =
             Updater.apply_event(
               state,
               Events.merge_startups("founder_1", "founder_2"),
               []
             )

    merged = next_state.world.startups["founder_1"]
    # founder_1 traction 10 + founder_2 traction 8
    assert merged.traction == 18
    # founder_1 employees 3 + founder_2 employees 2
    assert merged.employees == 5

    absorbed = next_state.world.startups["founder_2"]
    assert absorbed.merged_into == "founder_1"
  end

  # ---------------------------------------------------------------------------
  # Operations phase
  # ---------------------------------------------------------------------------

  test "allocate_funds growth increases traction" do
    state =
      base_state(%{
        phase: "operations",
        active_actor_id: "founder_1"
      })

    assert {:ok, next_state, {:decide, _}} =
             Updater.apply_event(
               state,
               Events.allocate_funds("founder_1", "growth", 100_000),
               []
             )

    startup = next_state.world.startups["founder_1"]
    # 100_000 / 100_000 = 1 traction_gain, so traction should be 10 + max(1, 1) = 11
    assert startup.traction > 10
    assert startup.cash_on_hand == 0
  end

  test "allocate_funds hiring increases employees" do
    state =
      base_state(%{
        phase: "operations",
        active_actor_id: "founder_1"
      })

    assert {:ok, next_state, {:decide, _}} =
             Updater.apply_event(
               state,
               Events.allocate_funds("founder_1", "hiring", 80_000),
               []
             )

    startup = next_state.world.startups["founder_1"]
    # 80_000 / 80_000 = 1 new employee, so 3 + max(1,1) = 4
    assert startup.employees > 3
    assert startup.cash_on_hand == 20_000
  end

  test "allocate_funds pivot changes sector" do
    state =
      base_state(%{
        phase: "operations",
        active_actor_id: "founder_1"
      })

    assert {:ok, next_state, {:decide, _}} =
             Updater.apply_event(
               state,
               Events.allocate_funds("founder_1", "pivot", 50_000),
               []
             )

    startup = next_state.world.startups["founder_1"]
    assert startup.pivoted? == true
    # Traction halved: 10 / 2 = 5
    assert startup.traction == 5
  end

  test "allocate_funds fails when insufficient cash" do
    state =
      base_state(%{
        phase: "operations",
        active_actor_id: "founder_1"
      })

    assert {:ok, _next_state, {:decide, msg}} =
             Updater.apply_event(
               state,
               Events.allocate_funds("founder_1", "growth", 999_999_999),
               []
             )

    assert msg =~ "insufficient funds"
  end

  # ---------------------------------------------------------------------------
  # End phase
  # ---------------------------------------------------------------------------

  test "end_phase advances active actor" do
    state = base_state()

    assert {:ok, next_state, {:decide, _}} =
             Updater.apply_event(
               state,
               Events.end_phase("founder_1", "pitch"),
               []
             )

    assert next_state.world.active_actor_id == "founder_2"
    assert MapSet.member?(next_state.world.phase_done, "founder_1")
  end

  test "end_phase by all pitch actors transitions phase to due_diligence" do
    state =
      base_state(%{
        phase: "pitch",
        active_actor_id: "founder_2",
        phase_done: MapSet.new(["founder_1"])
      })

    assert {:ok, next_state, {:decide, _}} =
             Updater.apply_event(
               state,
               Events.end_phase("founder_2", "pitch"),
               []
             )

    assert next_state.world.phase == "due_diligence"
  end

  # ---------------------------------------------------------------------------
  # Game-over state
  # ---------------------------------------------------------------------------

  test "actions rejected when game is over" do
    state = base_state(%{status: "won", winner: "founder_1"})

    assert {:ok, _next_state, {:decide, msg}} =
             Updater.apply_event(
               state,
               Events.make_pitch("founder_1", "Too late!"),
               []
             )

    assert msg =~ "game already over"
  end
end
