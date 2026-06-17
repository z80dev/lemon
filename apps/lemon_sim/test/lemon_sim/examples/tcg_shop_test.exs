defmodule LemonSim.Examples.TcgShopTest do
  use ExUnit.Case, async: true

  alias AgentCore.Types.AgentTool
  alias Ai.Types.{AssistantMessage, Model, ToolCall}
  alias LemonSim.Examples.TcgShop
  alias LemonSim.Bench.Artifacts.Verifier
  alias LemonSim.Examples.TcgShop.{Events, OfflineRunner, Performance, Updater}
  alias LemonSim.Kernel.Runner
  alias LemonSim.LLM.Deciders.ToolPolicies.SingleTerminal

  test "initial world models a realistic TCG shop mix" do
    world = TcgShop.initial_world(max_days: 14, seed: 7)

    assert world.mode == "tcg_shop"
    assert world.bank_balance == 10_000.0
    assert Map.has_key?(world.catalog, "pokemon_booster_box")
    assert Map.has_key?(world.catalog, "yugioh_core_box")
    assert Map.has_key?(world.catalog, "one_piece_booster_box")
    assert Map.has_key?(world.catalog, "dragon_ball_fusion_box")
    assert world.singles_case.cards_on_hand > 0
    assert length(world.release_calendar) > 0
  end

  test "default options classify TCG research as support and operating actions as terminal" do
    opts =
      TcgShop.default_opts(
        model: fake_model("operator"),
        stream_options: %{},
        complete_fn: fn _model, _context, _stream_opts -> flunk("unused") end
      )

    assert opts[:support_tool_matcher].(%AgentTool{name: "tcg_check_dashboard"})
    assert opts[:support_tool_matcher].(%AgentTool{name: "tcg_research_market"})
    assert opts[:support_tool_matcher].(%AgentTool{name: "memory_read_file"})
    refute opts[:support_tool_matcher].(%AgentTool{name: "tcg_order_product_line"})
    refute opts[:support_tool_matcher].(%AgentTool{name: "tcg_host_event"})
  end

  test "support research can precede a terminal product order" do
    state = TcgShop.initial_state(sim_id: "tcg_support_order", seed: 4)

    complete_fn = fn _model, _context, _stream_opts ->
      {:ok,
       %AssistantMessage{
         role: :assistant,
         content: [
           tool_call("tcg_research_market", %{"query" => "One Piece allocation"}),
           tool_call("tcg_order_product_line", %{
             "line_id" => "one_piece_booster_box",
             "quantity" => 2
           })
         ],
         stop_reason: :tool_use,
         timestamp: System.system_time(:millisecond)
       }}
    end

    assert {:ok, result} =
             Runner.step(
               state,
               TcgShop.modules(),
               model: fake_model("operator"),
               complete_fn: complete_fn,
               stream_options: %{},
               persist?: false,
               tool_policy: SingleTerminal,
               support_tool_matcher: &TcgShop.support_tool?/1
             )

    assert Enum.map(result.events, & &1.kind) == [
             "tcg_researched_market",
             "tcg_order_product_line"
           ]

    assert [%{query: "One Piece allocation"}] = result.state.world.research_history
  end

  test "next-day resolution delivers inventory, applies rent, and records sales" do
    state = TcgShop.initial_state(sim_id: "tcg_next_day", seed: 2)

    assert {:ok, ordered, _} =
             Updater.apply_event(state, Events.order_product_line("card_sleeves", 3), [])

    assert ordered.world.pending_deliveries != []
    assert ordered.world.bank_balance == 9_993.7

    assert {:ok, advanced, _} =
             Updater.apply_event(ordered, Events.wait_next_day("close register"), [])

    assert advanced.world.pending_deliveries == []
    assert advanced.world.day_number == 2
    assert advanced.world.bank_balance != ordered.world.bank_balance
    assert length(advanced.world.sales_history) > 0
  end

  test "invalid orders become benchmark-visible rejections" do
    state = TcgShop.initial_state(sim_id: "tcg_reject", starting_balance: 100.0)

    assert {:ok, result, _} =
             Updater.apply_event(
               state,
               Events.order_product_line("pokemon_booster_box", 10),
               []
             )

    assert result.world.invalid_action_count == 1
    assert [%{kind: "action_rejected"}] = result.recent_events
    assert result.world.bank_balance == 100.0
  end

  test "performance scorecard includes inventory, singles, grading, and ROI" do
    world = TcgShop.initial_world(seed: 5)
    scorecard = Performance.scorecard(world)

    assert scorecard.net_worth > world.bank_balance
    assert scorecard.inventory_value > 0
    assert scorecard.singles_value > 0
    assert is_float(scorecard.roi_pct)
  end

  test "offline baseline writes verifiable benchmark artifacts" do
    artifact_dir =
      Path.join(System.tmp_dir!(), "tcg_baseline_#{System.unique_integer([:positive])}")

    assert {:ok, %{state: state, artifacts: artifacts, steps: steps}} =
             OfflineRunner.run_strategy("baseline",
               sim_id: "tcg_baseline_test",
               max_days: 5,
               driver_max_turns: 20,
               seed: 3,
               artifact_dir: artifact_dir
             )

    assert state.world.status == "complete"
    assert steps > 0
    assert File.exists?(artifacts.final_world)
    assert File.exists?(artifacts.replay_html)

    assert {:ok, verified} = Verifier.verify_run(artifact_dir)
    assert verified.manifest["sim"]["id"] == "tcg_shop"
    assert verified.scorecard["status"] == "complete"
    assert verified.scorecard["net_worth"] > 0

    assert File.read!(artifacts.report) =~ "TCG Shop Offline Baseline Report"
    assert File.read!(artifacts.replay_html) =~ "TCG Shop Replay"
  end

  test "offline pressure strategy exercises buylist, grading, events, and market research" do
    artifact_dir =
      Path.join(System.tmp_dir!(), "tcg_pressure_#{System.unique_integer([:positive])}")

    assert {:ok, %{state: state}} =
             OfflineRunner.run_strategy(:pressure,
               sim_id: "tcg_pressure_test",
               max_days: 12,
               driver_max_turns: 40,
               seed: 8,
               artifact_dir: artifact_dir
             )

    assert length(state.world.buylist_history) > 0
    assert length(state.world.grading_history) > 0
    assert length(state.world.tournament_history) > 0
    assert length(state.world.research_history) > 0

    scorecard = Performance.scorecard(state.world)
    assert scorecard.events_hosted > 0
    assert scorecard.grading_submissions > 0

    assert {:ok, verified} = Verifier.verify_run(artifact_dir)
    assert verified.scorecard["events_hosted"] > 0
  end

  test "mix task can run a deterministic TCG shop artifact bundle" do
    artifact_dir = Path.join(System.tmp_dir!(), "tcg_mix_#{System.unique_integer([:positive])}")

    Mix.Tasks.Lemon.Sim.TcgShop.run([
      "--preset",
      "ci",
      "--offline-strategy",
      "baseline",
      "--sim-id",
      "tcg_mix_test",
      "--artifact-dir",
      artifact_dir
    ])

    assert File.exists?(Path.join(artifact_dir, "manifest.json"))
    assert {:ok, verified} = Verifier.verify_run(artifact_dir)
    assert verified.manifest["sim"]["id"] == "tcg_shop"
  end

  defp fake_model(id) do
    %Model{
      id: id,
      name: id,
      api: :openai_responses,
      provider: :openai,
      base_url: "https://example.invalid",
      reasoning: false,
      input: [:text],
      cost: %Ai.Types.ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4_096,
      headers: %{},
      compat: nil
    }
  end

  defp tool_call(name, arguments) do
    %ToolCall{
      type: :tool_call,
      id: "call_#{name}_#{System.unique_integer([:positive])}",
      name: name,
      arguments: arguments
    }
  end
end
