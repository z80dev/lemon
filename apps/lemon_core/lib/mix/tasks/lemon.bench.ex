defmodule Mix.Tasks.Lemon.Bench do
  use Mix.Task

  @shortdoc "Run the platform microbenchmark suites"

  @moduledoc """
  Runs the benchmark suites in `bench/` and prints their results.

  These measure platform primitives — store throughput, bus fanout, coalescer
  burst absorption, per-conversation process lifecycle — not model quality.
  For model behaviour see the simulation arenas (`mix sim.bench`).

  ## Usage

      mix lemon.bench              # every suite
      mix lemon.bench store        # one suite
      mix lemon.bench bus process  # several

  ## Suites

    * `store`     — `LemonCore.Store` put/get/list, ETS vs SQLite, one instance vs several
    * `bus`       — `LemonCore.Bus` fanout by subscriber count, PubSub vs Registry
    * `coalescer` — stream and tool-status coalescers under burst
    * `process`   — registry-named GenServer spawn, lookup and memory

  ## Notes

  Each suite runs in its own VM via `mix run --no-start`, for two reasons:
  nothing in the umbrella starts unless a suite starts it deliberately, and no
  suite inherits another's leftover processes.

  Results are written to stdout. Published numbers, with the caveats that
  belong next to them, live in `docs/benchmarks/platform.md`.

  These are deliberately **not** part of any CI lane — see the rationale in
  that document.
  """

  @suites ~w(store bus coalescer process)

  @impl Mix.Task
  def run(args) do
    unless Mix.Project.umbrella?() do
      Mix.raise("mix lemon.bench must be run from the umbrella root")
    end

    suites =
      case args do
        [] ->
          @suites

        names ->
          case Enum.reject(names, &(&1 in @suites)) do
            [] ->
              names

            unknown ->
              Mix.raise(
                "unknown suite(s): #{Enum.join(unknown, ", ")}. " <>
                  "Available: #{Enum.join(@suites, ", ")}"
              )
          end
      end

    Enum.each(suites, &run_suite/1)
  end

  defp run_suite(suite) do
    path = Path.join("bench", "#{suite}.exs")

    unless File.exists?(path) do
      Mix.raise("benchmark suite not found: #{path}")
    end

    Mix.shell().info("\n==> #{suite}\n")

    {_, status} =
      System.cmd("mix", ["run", "--no-start", path],
        into: IO.stream(:stdio, :line),
        env: [{"MIX_ENV", "dev"}]
      )

    if status != 0 do
      Mix.raise("benchmark suite #{suite} exited with status #{status}")
    end
  end
end
