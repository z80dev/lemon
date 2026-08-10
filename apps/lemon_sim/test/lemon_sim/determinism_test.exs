defmodule LemonSim.DeterminismTest do
  @moduledoc """
  Executable proof that LemonSim's kernel is a pure reducer: the same seed
  produces a byte-identical run.

  This uses the fully offline VendingBench strategy (a scripted decider, no LLM
  calls) so the only sources of variation are the kernel reducer and the
  artifact serializer. Both are asserted identical across two independent runs
  with the same seed — at the in-memory layer (final world state) and at the
  on-disk layer (the sha256 hashes Bench already computes for every artifact).

  When this passes, the "same seed → identical run" claim in the README and the
  Why-BEAM essay is verified, not merely asserted.
  """
  use ExUnit.Case, async: false

  alias LemonSim.Examples.VendingBench

  @seed 20_260_810

  defp run(dir) do
    {:ok, result} =
      VendingBench.run_offline_strategy("baseline",
        max_days: 7,
        driver_max_turns: 25,
        seed: @seed,
        # Fixed sim_id + deterministic_artifacts? pin the two knobs that are
        # legitimately nondeterministic by default (a unique run id and the
        # wall-clock timestamp), isolating the assertion to the reducer itself.
        sim_id: "determinism_test",
        deterministic_artifacts?: true,
        persist?: false,
        artifact_dir: dir
      )

    result
  end

  defp artifact_hashes(dir) do
    dir
    |> Path.join("hashes.json")
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("files")
  end

  defp tmp_dir(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  test "same seed produces a byte-identical run (pure kernel + identical artifacts)" do
    dir_a = tmp_dir("determinism_a")
    dir_b = tmp_dir("determinism_b")

    a = run(dir_a)
    b = run(dir_b)

    # Pure-kernel layer: the final world state is the fold of a fixed event
    # sequence through the reducer. It must be structurally identical.
    assert a.state.world == b.state.world
    assert a.steps == b.steps

    # On-disk layer: every artifact Bench writes hashes identically. This is the
    # "byte-identical" half of the claim, verified with the same sha256 map the
    # bench bundle/verifier already produce.
    hashes_a = artifact_hashes(dir_a)
    hashes_b = artifact_hashes(dir_b)

    assert hashes_a == hashes_b

    # Guard against a vacuous pass: the run really did emit the core artifacts,
    # so the equality above is comparing real content, not two empty maps.
    assert Map.has_key?(hashes_a, "final_world.json")
    assert Map.has_key?(hashes_a, "events.jsonl")
    assert Map.has_key?(hashes_a, "scorecard.json")
  end

  test "the hash comparison has teeth: a different strategy diverges" do
    dir_baseline = tmp_dir("determinism_baseline")
    dir_pressure = tmp_dir("determinism_pressure")

    baseline = run(dir_baseline)

    {:ok, pressure} =
      VendingBench.run_offline_strategy("pressure",
        max_days: 7,
        driver_max_turns: 25,
        seed: @seed,
        sim_id: "determinism_test",
        deterministic_artifacts?: true,
        persist?: false,
        artifact_dir: dir_pressure
      )

    # If the assertions above ever start comparing constants, this catches it:
    # a genuinely different run must produce a different world and different
    # artifact hashes.
    refute baseline.state.world == pressure.state.world
    refute artifact_hashes(dir_baseline) == artifact_hashes(dir_pressure)
  end
end
