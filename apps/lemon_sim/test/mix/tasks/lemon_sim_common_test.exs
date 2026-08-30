defmodule Mix.Tasks.Lemon.Sim.CommonTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Lemon.Sim.Common

  @migrated_tasks [
    {"lemon.sim.auction", Mix.Tasks.Lemon.Sim.Auction},
    {"lemon.sim.courtroom", Mix.Tasks.Lemon.Sim.Courtroom},
    {"lemon.sim.diplomacy", Mix.Tasks.Lemon.Sim.Diplomacy},
    {"lemon.sim.dungeon_crawl", Mix.Tasks.Lemon.Sim.DungeonCrawl},
    {"lemon.sim.intel_network", Mix.Tasks.Lemon.Sim.IntelNetwork},
    {"lemon.sim.leaderboard", Mix.Tasks.Lemon.Sim.Leaderboard},
    {"lemon.sim.legislature", Mix.Tasks.Lemon.Sim.Legislature},
    {"lemon.sim.murder_mystery", Mix.Tasks.Lemon.Sim.MurderMystery},
    {"lemon.sim.pandemic", Mix.Tasks.Lemon.Sim.Pandemic},
    {"lemon.sim.poker", Mix.Tasks.Lemon.Sim.Poker},
    {"lemon.sim.ratings", Mix.Tasks.Lemon.Sim.Ratings},
    {"lemon.sim.replay", Mix.Tasks.Lemon.Sim.Replay},
    {"lemon.sim.skirmish", Mix.Tasks.Lemon.Sim.Skirmish},
    {"lemon.sim.space_station", Mix.Tasks.Lemon.Sim.SpaceStation},
    {"lemon.sim.startup_incubator", Mix.Tasks.Lemon.Sim.StartupIncubator},
    {"lemon.sim.stock_market", Mix.Tasks.Lemon.Sim.StockMarket},
    {"lemon.sim.suite", Mix.Tasks.Lemon.Sim.Suite},
    {"lemon.sim.supply_chain", Mix.Tasks.Lemon.Sim.SupplyChain},
    {"lemon.sim.survivor", Mix.Tasks.Lemon.Sim.Survivor},
    {"lemon.sim.tcg_shop", Mix.Tasks.Lemon.Sim.TcgShop},
    {"lemon.sim.tic_tac_toe", Mix.Tasks.Lemon.Sim.TicTacToe},
    {"lemon.sim.vending_bench", Mix.Tasks.Lemon.Sim.VendingBench},
    {"lemon.sim.vending_bench_replay", Mix.Tasks.Lemon.Sim.VendingBenchReplay},
    {"lemon.sim.werewolf", Mix.Tasks.Lemon.Sim.Werewolf}
  ]

  setup do
    original_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn -> Mix.shell(original_shell) end)
  end

  test "maybe_put omits nil and retains ordinary values" do
    assert Common.maybe_put([persist?: false], :model, nil) == [persist?: false]

    assert Common.maybe_put([persist?: false], :model, :configured) == [
             model: :configured,
             persist?: false
           ]
  end

  test "resolves qualified, unqualified, and aliased known models" do
    qualified = Common.resolve_model("anthropic:claude-sonnet-4-20250514")
    unqualified = Common.resolve_model("claude-sonnet-4-20250514")
    gemini = Common.resolve_model("gemini:gemini-2.5-flash")

    assert qualified.provider == :anthropic
    assert qualified.id == "claude-sonnet-4-20250514"
    assert unqualified == qualified
    assert gemini.provider == :google_gemini_cli
    assert gemini.id == "gemini-2.5-flash"
  end

  test "provider aliases and normalized known-provider spellings stay stable" do
    assert Common.resolve_provider("gemini") == :google_gemini_cli
    assert Common.resolve_provider("gemini-cli") == :google_gemini_cli
    assert Common.resolve_provider("gemini_cli") == :google_gemini_cli
    assert Common.resolve_provider("openai_codex") == :"openai-codex"
    assert Common.resolve_provider(" OpenAI-Codex ") == :"openai-codex"
    assert Common.resolve_provider("google-vertex") == :google_vertex
  end

  test "unknown providers preserve model errors without creating atoms" do
    provider = "lemon_sim_missing_provider_#{System.unique_integer([:positive])}"

    assert_raise ArgumentError, fn -> String.to_existing_atom(provider) end
    assert Common.resolve_provider(provider) == nil

    assert_raise Mix.Error,
                 ~s(unknown model "missing-model" for provider "#{provider}"),
                 fn -> Common.resolve_model("#{provider}:missing-model") end

    assert_raise ArgumentError, fn -> String.to_existing_atom(provider) end
  end

  test "unknown model errors retain their task-facing text" do
    assert_raise Mix.Error, ~s(unknown model "missing-model"), fn ->
      Common.resolve_model("missing-model")
    end

    assert_raise Mix.Error,
                 ~s(unknown model "missing-model" for provider "anthropic"),
                 fn -> Common.resolve_model("anthropic:missing-model") end
  end

  test "runtime startup contracts remain callable" do
    assert Common.ensure_runtime_started!() == :ok
    assert {:ok, _started} = Common.ensure_runtime_and_core_started()
  end

  test "every migrated task keeps its task name, run API, and help path" do
    Enum.each(@migrated_tasks, fn {name, task} ->
      assert Code.ensure_loaded?(task)
      assert function_exported?(task, :run, 1)
      assert Mix.Task.get(name) == task
      assert task.run(["--help"]) == :ok
    end)

    refute function_exported?(Common, :run, 1)
  end

  test "representative wrappers preserve help aliases and option/model errors" do
    assert Mix.Tasks.Lemon.Sim.TicTacToe.run(["--help"]) == :ok
    assert_receive {:mix_shell, :info, [help]}
    assert help =~ "--max-driver-turns"

    assert_raise Mix.Error, "invalid options: [{\"--unknown\", nil}]", fn ->
      Mix.Tasks.Lemon.Sim.Auction.run(["--unknown"])
    end

    provider = "task_missing_provider_#{System.unique_integer([:positive])}"

    assert_raise Mix.Error,
                 ~s(unknown model "missing" for provider "#{provider}"),
                 fn -> Mix.Tasks.Lemon.Sim.Skirmish.run(["--model", "#{provider}:missing"]) end

    vending_provider = "vending_missing_provider_#{System.unique_integer([:positive])}"

    assert catch_exit(
             Mix.Tasks.Lemon.Sim.VendingBench.run([
               "--model",
               "#{vending_provider}:missing"
             ])
           ) == {:shutdown, 1}

    expected_error =
      "Could not resolve model #{vending_provider}:missing: :model_not_found"

    assert_receive {:mix_shell, :error, [^expected_error]}

    assert_raise ArgumentError, fn -> String.to_existing_atom(vending_provider) end
  end
end
