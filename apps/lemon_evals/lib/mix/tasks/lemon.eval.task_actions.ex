defmodule Mix.Tasks.Lemon.Eval.TaskActions do
  use Mix.Task

  @shortdoc "Aggregate content-free task action telemetry from an eval or arena runtime"
  @moduledoc """
  Reads a JSONL file collected by `LemonEvals.TaskActions` without starting apps.

      mix lemon.eval.task_actions --input /tmp/task-actions.jsonl --output /tmp/task-actions.json

  Without `--output`, prints the JSON report. See `docs/telemetry.md` for capture
  setup, counting units, and limits. This command never runs a model or benchmark.
  """
  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [input: :string, output: :string])

    if rest != [] or invalid != [] or not is_binary(opts[:input]) do
      Mix.raise(
        "Usage: mix lemon.eval.task_actions --input TELEMETRY.jsonl [--output REPORT.json]"
      )
    end

    json = opts[:input] |> LemonEvals.TaskActions.report() |> Jason.encode!(pretty: true)

    case opts[:output] do
      nil -> Mix.shell().info(json)
      path -> File.write!(path, json <> "\n")
    end
  end
end
