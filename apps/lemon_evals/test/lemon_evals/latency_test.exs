defmodule LemonEvals.LatencyBudgetContractTest do
  use ExUnit.Case, async: true

  @priv Path.expand("../../priv", __DIR__)

  defp python!(source) do
    python = System.find_executable("python3") || raise "python3 is required"
    {output, status} = System.cmd(python, ["-B", "-c", source], cd: @priv, stderr_to_stdout: true)
    assert status == 0, output
    output
  end

  test "nearest-rank p50 and p99 use all samples and preserve units" do
    python!("""
    from latency_benchmark import summarize
    assert summarize(list(range(1, 101))) == {'n': 100, 'p50_ms': .05, 'p99_ms': .099}
    assert summarize([2000]) == {'n': 1, 'p50_ms': 2, 'p99_ms': 2}
    for invalid in ([], [-1], [float('nan')], [float('inf')], [True]):
        try:
            summarize(invalid)
        except ValueError:
            pass
        else:
            raise AssertionError('invalid latency accepted')
    """)
  end

  test "regressions require both thresholds and compare every metric and percentile" do
    python!("""
    from copy import deepcopy
    from latency_benchmark import METRICS, regressions
    base = {'schema_version': 1, 'environment': {'otp': 'fixture'},
            'metrics': {m: {'p50_ms': 10, 'p99_ms': 20} for m in METRICS}}
    current = deepcopy(base)
    assert regressions(current, base) == []
    current['metrics'][METRICS[0]]['p50_ms'] = 12.5
    assert regressions(current, base) == []
    current['metrics'][METRICS[0]]['p50_ms'] = 13
    assert len(regressions(current, base)) == 1
    for m in METRICS:
        current = deepcopy(base)
        current['metrics'][m]['p99_ms'] = 26
        assert len(regressions(current, base)) == 1
    base['metrics'][METRICS[0]]['p50_ms'] = 1
    current = deepcopy(base)
    current['metrics'][METRICS[0]]['p50_ms'] = 2
    assert regressions(current, base) == []  # absolute noise floor
    current['environment'] = {'otp': 'different'}
    try:
        regressions(current, base)
    except ValueError:
        pass
    else:
        raise AssertionError('incomparable baseline accepted')
    """)
  end

  @tag :integration
  @tag timeout: 240_000
  @tag :tmp_dir
  test "native offline lane emits every required distribution without credentials", %{
    tmp_dir: tmp
  } do
    output = Path.join(tmp, "latency.json")
    python = System.find_executable("python3") || raise "python3 is required"

    {diagnostic, status} =
      System.cmd(
        python,
        [
          "-B",
          Path.join(@priv, "latency_benchmark.py"),
          "--boots",
          "1",
          "--turns",
          "1",
          "--revision",
          String.duplicate("a", 40),
          "--output",
          output
        ],
        stderr_to_stdout: true
      )

    assert status == 0, diagnostic
    report = output |> File.read!() |> Jason.decode!()
    assert report["baseline_status"] == "bootstrap_no_baseline"
    assert length(report["top_three_session_contributors"]) == 3

    for {_metric, distribution} <- report["metrics"] do
      assert distribution["n"] >= 1
      assert distribution["p50_ms"] >= 0
      assert distribution["p99_ms"] >= distribution["p50_ms"]
    end

    refute File.read!(output) =~ "offline-fixture-not-a-real-credential"
  end
end
