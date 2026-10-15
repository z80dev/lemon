defmodule Mix.Tasks.Lemon.Sim.CommonTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Lemon.Sim.Common

  @migrated_tasks [
    {"lemon.sim.leaderboard", Mix.Tasks.Lemon.Sim.Leaderboard},
    {"lemon.sim.poker", Mix.Tasks.Lemon.Sim.Poker},
    {"lemon.sim.ratings", Mix.Tasks.Lemon.Sim.Ratings},
    {"lemon.sim.replay", Mix.Tasks.Lemon.Sim.Replay},
    {"lemon.sim.suite", Mix.Tasks.Lemon.Sim.Suite},
    {"lemon.sim.tic_tac_toe", Mix.Tasks.Lemon.Sim.TicTacToe},
    {"lemon.sim.vending_bench", Mix.Tasks.Lemon.Sim.VendingBench},
    {"lemon.sim.vending_bench_replay", Mix.Tasks.Lemon.Sim.VendingBenchReplay},
    {"lemon.sim.werewolf", Mix.Tasks.Lemon.Sim.Werewolf}
  ]

  @runtime_only_migrated_tasks [
    {"lemon.sim.verify", Mix.Tasks.Lemon.Sim.Verify}
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

  test "migrated tasks preserve dispatch and help paths" do
    Enum.each(@migrated_tasks ++ @runtime_only_migrated_tasks, fn {name, task} ->
      assert Mix.Task.get(name) == task

      if task in Enum.map(@migrated_tasks, &elem(&1, 1)) do
        assert task.run(["--help"]) == :ok
      end
    end)
  end

  test "replay requires an explicit scenario and only offers kept scenarios" do
    assert_raise Mix.Error, ~r/^missing scenario\n.*Scenarios: poker, werewolf$/s, fn ->
      Mix.Tasks.Lemon.Sim.Replay.run(["priv/game_logs/abc123.jsonl"])
    end

    assert_raise Mix.Error, ~r/^unknown scenario "chess"\n\nScenarios: poker, werewolf$/, fn ->
      Mix.Tasks.Lemon.Sim.Replay.run(["chess", "priv/game_logs/abc123.jsonl"])
    end
  end

  test "representative wrappers preserve help aliases and option/model errors" do
    assert Mix.Tasks.Lemon.Sim.TicTacToe.run(["--help"]) == :ok
    assert_receive {:mix_shell, :info, [help]}
    assert help =~ "--max-driver-turns"

    assert_raise Mix.Error, "invalid options: [{\"--unknown\", nil}]", fn ->
      Mix.Tasks.Lemon.Sim.TicTacToe.run(["--unknown"])
    end

    provider = "task_missing_provider_#{System.unique_integer([:positive])}"

    assert_raise Mix.Error,
                 ~s(unknown model "missing" for provider "#{provider}"),
                 fn -> Mix.Tasks.Lemon.Sim.TicTacToe.run(["--model", "#{provider}:missing"]) end

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
