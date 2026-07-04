defmodule LemonSim.Bench.SuiteTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonSim.Bench.Suite
  alias LemonSim.Examples.Poker
  alias LemonSim.Examples.Poker.Artifacts, as: PokerArtifacts

  test "keyless vending bench suite writes verified stable leaderboard artifacts" do
    spec = %{
      scenario: "vending_bench",
      preset: "ci",
      seeds: [7, 8],
      competitors: [
        %{id: "baseline", offline_strategy: "baseline"},
        %{id: "pressure", offline_strategy: "pressure"}
      ]
    }

    dir_a = tmp_dir("suite_vending_a")
    dir_b = tmp_dir("suite_vending_b")

    assert {:ok, %{suite: suite_a}} = Suite.run(spec, suite_dir: dir_a)
    assert {:ok, %{suite: suite_b}} = Suite.run(spec, suite_dir: dir_b)

    assert File.exists?(Path.join(dir_a, "suite.json"))
    assert File.exists?(Path.join(dir_a, "leaderboard.md"))
    assert Enum.all?(suite_a.runs, & &1["verified"])

    assert Enum.map(suite_a.rankings, & &1["competitor"]) == ["baseline", "pressure"]
    assert Enum.map(suite_b.rankings, & &1["competitor"]) == ["baseline", "pressure"]

    assert File.read!(Path.join(dir_a, "suite.json")) ==
             File.read!(Path.join(dir_b, "suite.json"))
  end

  test "metric paths, directions, null cost aggregation, and failure exclusion aggregate correctly" do
    assert Suite.metric_value(%{"net_worth" => 12.5}, "net_worth") == {:ok, 12.5}

    assert Suite.metric_value(%{"score_modes" => %{"v1_net_worth" => 9}}, [
             "score_modes",
             "v1_net_worth"
           ]) == {:ok, 9}

    maximize_spec = %{
      "scenario" => "stock_market",
      "preset" => nil,
      "seeds" => [1],
      "competitors" => [%{"id" => "low"}, %{"id" => "high"}]
    }

    assert {:ok, maximize_suite} =
             Suite.build_suite(maximize_spec, [
               verified_run(0, "stock_market", "low", 1, 10, %{"cost_usd" => 0.1}),
               verified_run(1, "stock_market", "high", 1, 20, %{"cost_usd" => nil})
             ])

    assert Enum.map(maximize_suite.rankings, & &1["competitor"]) == ["high", "low"]
    assert get_in(maximize_suite.rankings, [Access.at(0), "usage_totals", "cost_usd"]) == nil

    minimize_spec = %{
      "scenario" => "pandemic",
      "preset" => nil,
      "seeds" => [1],
      "competitors" => [%{"id" => "worse"}, %{"id" => "better"}]
    }

    assert {:ok, minimize_suite} =
             Suite.build_suite(minimize_spec, [
               verified_run(0, "pandemic", "worse", 1, 0.4, %{"cost_usd" => 0.1}),
               verified_run(1, "pandemic", "better", 1, 0.2, %{"cost_usd" => 0.2}),
               failed_run(2, "pandemic", "better", 2)
             ])

    assert Enum.map(minimize_suite.rankings, & &1["competitor"]) == ["better", "worse"]
    assert get_in(minimize_suite.rankings, [Access.at(0), "failed_runs"]) == 1
    assert length(minimize_suite.failures) == 1
  end

  test "recompute excludes a tampered verified bundle from rankings" do
    suite_dir = tmp_dir("suite_tamper")
    good_dir = Path.join([suite_dir, "runs", "good", "1"])
    bad_dir = Path.join([suite_dir, "runs", "bad", "1"])

    write_poker_bundle!(good_dir, "poker_good", 10)
    write_poker_bundle!(bad_dir, "poker_bad", 11)

    tamper_scorecard!(bad_dir, fn scorecard ->
      Map.update!(scorecard, "hands_completed", &(&1 + 1))
    end)

    suite_json = %{
      "schema_version" => "lemon_sim.suite.v1",
      "spec" => %{
        "scenario" => "poker",
        "preset" => nil,
        "seeds" => [1],
        "competitors" => [
          %{"id" => "good", "offline_strategy" => "fixture"},
          %{"id" => "bad", "offline_strategy" => "fixture"}
        ]
      },
      "runs" => [
        %{
          "index" => 0,
          "competitor" => "good",
          "seed" => 1,
          "sim_id" => "poker_good",
          "artifact_dir" => "runs/good/1"
        },
        %{
          "index" => 1,
          "competitor" => "bad",
          "seed" => 1,
          "sim_id" => "poker_bad",
          "artifact_dir" => "runs/bad/1"
        }
      ]
    }

    File.write!(Path.join(suite_dir, "suite.json"), Jason.encode!(suite_json, pretty: true))

    assert {:ok, suite} = Suite.recompute(suite_dir)
    assert Enum.map(suite.rankings, & &1["competitor"]) == ["good"]
    assert [%{"competitor" => "bad", "error" => error}] = suite.failures
    assert error =~ "scorecard_mismatch"
  end

  test "leaderboard renderer emits the expected table structure" do
    suite = %{
      "spec" => %{"scenario" => "vending_bench", "preset" => "ci", "seeds" => [7, 8]},
      "primary_metric" => %{
        "name" => "score_modes.v1_net_worth",
        "direction" => "maximize"
      },
      "rankings" => [
        %{
          "rank" => 1,
          "competitor" => "baseline",
          "mean" => 766.525,
          "values_by_seed" => %{"7" => 782.4, "8" => 750.65},
          "usage_totals" => %{
            "input_tokens" => 1,
            "output_tokens" => 2,
            "cache_read_tokens" => 3,
            "cache_write_tokens" => 4,
            "cost_usd" => 0.1234
          }
        }
      ],
      "failures" => [
        %{
          "competitor" => "pressure",
          "seed" => 8,
          "error" => "{:hash_mismatch, \"scorecard.json\"}"
        }
      ]
    }

    leaderboard = Suite.render_leaderboard(suite)

    assert leaderboard =~ "# LemonSim Suite Leaderboard"

    assert leaderboard =~
             "| Rank | Competitor | Mean score_modes.v1_net_worth (maximize) | Per-seed values | Tokens | Cost |"

    assert leaderboard =~ "| 1 | baseline | 766.52 | 7: 782.4, 8: 750.65 | 10 | $0.1234 |"
    assert leaderboard =~ "## Failures"
    assert leaderboard =~ "| pressure | 8 | `{:hash_mismatch, \"scorecard.json\"}` |"
  end

  test "mix lemon.sim.leaderboard round-trips a suite directory" do
    spec = %{
      scenario: "vending_bench",
      preset: "ci",
      seeds: [7],
      competitors: [%{id: "baseline", offline_strategy: "baseline"}]
    }

    suite_dir = tmp_dir("suite_mix_roundtrip")
    assert {:ok, %{leaderboard: expected}} = Suite.run(spec, suite_dir: suite_dir)

    Mix.Task.reenable("lemon.sim.leaderboard")

    output =
      capture_io(fn ->
        assert :ok = Mix.Task.run("lemon.sim.leaderboard", [suite_dir])
      end)

    assert output =~ "# LemonSim Suite Leaderboard"
    assert File.read!(Path.join(suite_dir, "leaderboard.md")) == expected
  end

  defp verified_run(index, scenario, competitor, seed, metric, usage) do
    %{
      "index" => index,
      "scenario" => scenario,
      "competitor" => competitor,
      "competitor_spec" => %{"id" => competitor},
      "seed" => seed,
      "sim_id" => "#{scenario}_#{competitor}_#{seed}",
      "artifact_dir" => "runs/#{competitor}/#{seed}",
      "verified" => true,
      "metric" => metric,
      "usage_totals" =>
        Map.merge(
          %{
            "input_tokens" => 1,
            "output_tokens" => 2,
            "cache_read_tokens" => 3,
            "cache_write_tokens" => 4,
            "decisions" => 1,
            "cost_usd" => 0.0
          },
          usage
        )
    }
  end

  defp failed_run(index, scenario, competitor, seed) do
    %{
      "index" => index,
      "scenario" => scenario,
      "competitor" => competitor,
      "seed" => seed,
      "sim_id" => "#{scenario}_#{competitor}_#{seed}",
      "artifact_dir" => "runs/#{competitor}/#{seed}",
      "verified" => false,
      "metric" => nil,
      "usage_totals" => %{},
      "error" => "{:scorecard_mismatch, \"#{scenario}\"}"
    }
  end

  defp write_poker_bundle!(artifact_dir, sim_id, seed) do
    state = Poker.initial_state(sim_id: sim_id, player_count: 2, max_hands: 1, seed: seed)
    events = [%{kind: "hand_started", payload: %{hand: 1}, ts_ms: 123}]

    assert {:ok, _paths} =
             PokerArtifacts.write_run_artifacts(state, events, [],
               artifact_dir: artifact_dir,
               deterministic_artifacts?: true
             )
  end

  defp tamper_scorecard!(artifact_dir, fun) do
    scorecard_path = Path.join(artifact_dir, "scorecard.json")
    manifest_path = Path.join(artifact_dir, "manifest.json")
    hashes_path = Path.join(artifact_dir, "hashes.json")

    scorecard =
      scorecard_path
      |> File.read!()
      |> Jason.decode!()
      |> fun.()

    File.write!(scorecard_path, Jason.encode!(scorecard, pretty: true))
    scorecard_hash = sha256(File.read!(scorecard_path))

    manifest =
      manifest_path
      |> File.read!()
      |> Jason.decode!()
      |> put_in(["integrity", "scorecard_sha256"], scorecard_hash)

    hashes =
      hashes_path
      |> File.read!()
      |> Jason.decode!()
      |> put_in(["files", "scorecard.json"], scorecard_hash)

    File.write!(manifest_path, Jason.encode!(manifest, pretty: true))
    File.write!(hashes_path, Jason.encode!(hashes, pretty: true))
  end

  defp tmp_dir(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end
