defmodule Mix.Tasks.Lemon.Eval.Latency do
  use Mix.Task

  @shortdoc "Measure offline native-runtime latency against a local provider fixture"
  @moduledoc """
  Runs the isolated, credential-free latency lane without booting this VM's apps.

      mix lemon.eval.latency --output /tmp/latency.json --revision FULL_SHA

  Options are documented in `docs/benchmarks/latency-sla.md`. Dependencies and the
  development build must already exist; the child uses `--no-compile`. Only the
  allowlisted JSON result is suitable for uploading, not runtime diagnostics.
  """
  @impl true
  def run(args) do
    script = Path.expand("../../../priv/latency_benchmark.py", __DIR__)
    python = System.find_executable("python3") || Mix.raise("python3 is required")

    {_output, status} =
      System.cmd(python, ["-B", script | args],
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true
      )

    if status != 0, do: Mix.raise("Offline latency lane failed (#{status})")
  end
end
