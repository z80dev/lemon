defmodule Mix.Tasks.Lemon.Eval do
  use Mix.Task

  alias LemonEvals.{Harness, Report}

  @shortdoc "Run coding quality eval harness"
  @moduledoc """
  Run the coding eval harness with deterministic, statistical, and workflow checks.

  Usage:
    mix lemon.eval
    mix lemon.eval --iterations 50
    mix lemon.eval --json
    mix lemon.eval --live-model
    mix lemon.eval --output eval-report.json --revision <full-commit-sha>

  `--live-model` adds opt-in model-backed checks. Configure them with
  `LEMON_EVAL_API_KEY`, `LEMON_EVAL_API_KEY_SECRET`, `LEMON_EVAL_PROVIDER`,
  `LEMON_EVAL_MODEL`, `LEMON_EVAL_BASE_URL`, and `LEMON_EVAL_API_TYPE`; the
  matching `INTEGRATION_*` variables are also accepted.

  `--output` writes a versioned, allowlisted artifact before raising for failed
  checks. Raw check details are omitted from that file. `--json` retains its
  existing detailed stdout format and may include sensitive diagnostic data.
  `--iterations` controls statistical checks, not repeated live-model trials.
  """

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          iterations: :integer,
          json: :boolean,
          cwd: :string,
          live_model: :boolean,
          live_timeout_ms: :integer,
          output: :string,
          revision: :string
        ],
        aliases: [n: :iterations]
      )

    if invalid != [] do
      Mix.raise("Invalid eval option(s): #{inspect(invalid)}")
    end

    if rest != [] do
      Mix.raise("Unexpected eval argument(s): #{Enum.join(rest, " ")}")
    end

    iterations = opts[:iterations] || 25
    live_timeout_ms = opts[:live_timeout_ms] || 90_000

    if iterations <= 0 do
      Mix.raise("--iterations must be a positive integer")
    end

    if live_timeout_ms <= 0 do
      Mix.raise("--live-timeout-ms must be a positive integer")
    end

    unless Report.valid_revision?(opts[:revision]) do
      Mix.raise("--revision must be a full 40-character Git commit SHA")
    end

    Mix.Task.run("app.start")
    started_at = System.monotonic_time(:millisecond)

    report =
      Harness.run(
        cwd: opts[:cwd] || File.cwd!(),
        iterations: iterations,
        live_model: opts[:live_model] || false,
        live_timeout_ms: live_timeout_ms
      )

    duration_ms = System.monotonic_time(:millisecond) - started_at
    persist_report(report, opts, iterations, live_timeout_ms, duration_ms)

    if opts[:json] do
      Mix.shell().info(Jason.encode!(report, pretty: true))
    else
      print_report(report)
    end

    if report.summary.failed > 0 do
      Mix.raise("Eval harness failed (#{report.summary.failed} failing checks).")
    end
  end

  defp persist_report(report, opts, iterations, live_timeout_ms, duration_ms) do
    if path = opts[:output] do
      artifact =
        Report.build(report,
          iterations: iterations,
          live_model: opts[:live_model] || false,
          live_timeout_ms: live_timeout_ms,
          duration_ms: duration_ms,
          revision: opts[:revision]
        )

      case Report.write(path, artifact) do
        :ok -> :ok
        {:error, _reason} -> Mix.raise("Could not write eval report artifact")
      end
    end
  end

  defp print_report(report) do
    Mix.shell().info(
      "Eval summary: #{report.summary.passed} passed, #{report.summary.failed} failed"
    )

    Enum.each(report.results, fn result ->
      Mix.shell().info("- #{result.name}: #{result.status}")

      if result.status == :fail do
        Mix.shell().error("  details: #{inspect(result.details, pretty: true)}")
      end
    end)
  end
end
