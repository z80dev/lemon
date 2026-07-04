defmodule LemonSim.Bench.Artifacts.VerifierTest do
  use ExUnit.Case, async: true

  alias LemonSim.Bench.Artifacts.{Bundle, Verifier}
  alias LemonSim.Examples.{Pandemic, Poker, StockMarket}
  alias LemonSim.Examples.Pandemic.Artifacts, as: PandemicArtifacts
  alias LemonSim.Examples.Poker.Artifacts, as: PokerArtifacts
  alias LemonSim.Examples.StockMarket.Artifacts, as: StockMarketArtifacts

  test "registered poker bundle recomputes and rejects a tampered scorecard" do
    artifact_dir = tmp_dir("poker_bundle")

    state =
      Poker.initial_state(sim_id: "poker_bundle_test", player_count: 2, max_hands: 1, seed: 7)

    events = [%{kind: "hand_started", payload: %{hand: 1}, ts_ms: 123}]

    assert {:ok, _paths} =
             PokerArtifacts.write_run_artifacts(state, events, [],
               artifact_dir: artifact_dir,
               deterministic_artifacts?: true
             )

    assert {:ok, verified} = Verifier.verify_run(artifact_dir)
    assert verified.manifest["sim"]["id"] == "poker"
    assert verified.scorecard["sim_id"] == "poker_bundle_test"

    tamper_scorecard!(artifact_dir, fn scorecard ->
      Map.update!(scorecard, "hands_completed", &(&1 + 1))
    end)

    assert {:error, {:scorecard_mismatch, "poker"}} = Verifier.verify_run(artifact_dir)
  end

  test "registered stock market bundle recomputes and rejects a tampered scorecard" do
    artifact_dir = tmp_dir("stock_bundle")
    state = StockMarket.initial_state(sim_id: "stock_bundle_test", player_count: 2)
    events = [%{kind: "market_news_generated", payload: %{round: 1}, ts_ms: 456}]

    assert {:ok, _paths} =
             StockMarketArtifacts.write_run_artifacts(state, events, [],
               artifact_dir: artifact_dir,
               deterministic_artifacts?: true
             )

    assert {:ok, verified} = Verifier.verify_run(artifact_dir)
    assert verified.manifest["sim"]["id"] == "stock_market"
    assert is_number(verified.scorecard["best_final_value"])

    tamper_scorecard!(artifact_dir, fn scorecard ->
      Map.update!(scorecard, "best_final_value", &(&1 + 1))
    end)

    assert {:error, {:scorecard_mismatch, "stock_market"}} = Verifier.verify_run(artifact_dir)
  end

  test "registered pandemic bundle recomputes and rejects a tampered scorecard" do
    artifact_dir = tmp_dir("pandemic_bundle")
    state = Pandemic.initial_state(sim_id: "pandemic_bundle_test", player_count: 4, max_rounds: 2)
    events = [%{kind: "phase_changed", payload: %{phase: "intelligence"}, ts_ms: 789}]

    assert {:ok, _paths} =
             PandemicArtifacts.write_run_artifacts(state, events, [],
               artifact_dir: artifact_dir,
               deterministic_artifacts?: true
             )

    assert {:ok, verified} = Verifier.verify_run(artifact_dir)
    assert verified.manifest["sim"]["id"] == "pandemic"
    assert is_number(get_in(verified.scorecard, ["team", "global_death_rate"]))

    tamper_scorecard!(artifact_dir, fn scorecard ->
      put_in(scorecard, ["team", "global_death_rate"], 99.99)
    end)

    assert {:error, {:scorecard_mismatch, "pandemic"}} = Verifier.verify_run(artifact_dir)
  end

  test "unregistered bundles still skip scorecard recompute" do
    artifact_dir = tmp_dir("unregistered_bundle")
    File.mkdir_p!(artifact_dir)

    usage = LemonSim.LLM.Usage.artifact(nil, "unregistered_bundle_test")

    contents = %{
      Path.join(artifact_dir, "final_world.json") => Bundle.encode_json(%{"status" => "done"}),
      Path.join(artifact_dir, "events.jsonl") => Bundle.jsonl([%{kind: "done", payload: %{}}]),
      Path.join(artifact_dir, "actions.jsonl") => "",
      Path.join(artifact_dir, "scorecard.json") => Bundle.encode_json(%{"made_up" => 1}),
      Path.join(artifact_dir, "usage.json") => LemonSim.LLM.Usage.encode_artifact(usage)
    }

    Bundle.write_bundle!(
      artifact_dir,
      contents,
      Path.join(artifact_dir, "hashes.json"),
      Path.join(artifact_dir, "manifest.json"),
      fn hashes ->
        %{
          schema_version: "lemon_sim.run.v1",
          sim: %{id: "unregistered", version: "1.0.0", ruleset_hash: nil, seed: nil},
          agent: nil,
          runtime: %{lemon_commit: nil, elixir: System.version(), otp: "test"},
          integrity: %{
            events_sha256: hashes.files["events.jsonl"],
            scorecard_sha256: hashes.files["scorecard.json"],
            usage_sha256: hashes.files["usage.json"]
          }
        }
      end
    )

    tamper_scorecard!(artifact_dir, fn scorecard -> Map.put(scorecard, "made_up", 2) end)

    assert {:ok, verified} = Verifier.verify_run(artifact_dir)
    assert verified.scorecard["made_up"] == 2
  end

  defp tmp_dir(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
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

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end
