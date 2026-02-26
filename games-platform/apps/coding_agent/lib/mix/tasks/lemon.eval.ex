defmodule Mix.Tasks.Lemon.Eval do
  use Mix.Task

  alias CodingAgent.Evals.Harness

  @shortdoc "Run coding quality eval harness"
  @moduledoc """
  Run the coding eval harness with deterministic, statistical, and workflow checks.

  Usage:
    mix lemon.eval
    mix lemon.eval --iterations 50
    mix lemon.eval --json
  """

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        switches: [iterations: :integer, json: :boolean, cwd: :string],
        aliases: [n: :iterations]
      )

    report =
      Harness.run(
        cwd: opts[:cwd] || File.cwd!(),
        iterations: opts[:iterations] || 25
      )

    if opts[:json] do
      Mix.shell().info(Jason.encode!(report, pretty: true))
    else
      print_report(report)
    end

    if report.summary.failed > 0 do
      Mix.raise("Eval harness failed (#{report.summary.failed} failing checks).")
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
