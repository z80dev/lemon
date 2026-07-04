defmodule LemonSim.SimDemoBundleTest do
  use ExUnit.Case, async: false

  alias LemonSim.Bench.Artifacts.Verifier
  alias LemonSim.Bench.Suite
  alias LemonSim.Examples.VendingBench
  alias LemonSim.Examples.VendingBench.Replay

  test "demo bundle path verifies, replays, scores, and fits suite aggregation" do
    artifact_dir = tmp_dir("sim_demo_pressure")

    assert {:ok, %{artifacts: _artifacts}} =
             VendingBench.run_offline_strategy("pressure",
               max_days: 7,
               driver_max_turns: 25,
               seed: 42,
               sim_id: "demo_test_pressure",
               artifact_dir: artifact_dir,
               deterministic_artifacts?: true
             )

    assert {:ok, verified} = Verifier.verify_run(artifact_dir)
    assert verified.manifest["sim"]["id"] == "vending_bench"
    assert verified.scorecard["sim_id"] == "demo_test_pressure"

    assert %{
             "v1_net_worth" => net_worth,
             "money_balance" => money_balance,
             "lemon_operational_score" => operational_score
           } = verified.scorecard["score_modes"]

    assert is_number(net_worth)
    assert is_number(money_balance)
    assert is_number(operational_score)

    replay_dir = tmp_dir("sim_demo_replay")
    assert {:ok, replay_paths} = Replay.write_browser(artifact_dir, output_dir: replay_dir)
    assert File.exists?(replay_paths.replay_json)
    assert File.exists?(replay_paths.replay_html)
    assert File.read!(replay_paths.replay_html) =~ "VendingBench Replay"

    spec = %{
      scenario: "vending_bench",
      preset: "ci",
      seeds: [1],
      competitors: [
        %{id: "baseline", offline_strategy: "baseline"},
        %{id: "pressure", offline_strategy: "pressure"}
      ]
    }

    suite_dir = tmp_dir("sim_demo_suite")
    assert {:ok, %{suite: suite}} = Suite.run(spec, suite_dir: suite_dir)
    assert File.exists?(Path.join(suite_dir, "suite.json"))
    assert Enum.all?(suite.runs, & &1["verified"])
    assert get_in(suite.primary_metric, ["key"]) == ["score_modes", "v1_net_worth"]
    assert Enum.map(suite.rankings, & &1["competitor"]) == ["baseline", "pressure"]
  end

  defp tmp_dir(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
