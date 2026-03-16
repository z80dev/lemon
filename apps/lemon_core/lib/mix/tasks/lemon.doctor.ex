defmodule Mix.Tasks.Lemon.Doctor do
  use Mix.Task

  alias LemonCore.Doctor.{Report}
  alias LemonCore.Doctor.Checks.{Config, NodeTools, Providers, Runtime, Secrets, Skills}

  @shortdoc "Run Lemon diagnostics and report health"

  @moduledoc """
  Runs structured diagnostics across Lemon's configuration, secrets,
  runtime, providers, system tools, and skills store.

  Each check produces a pass / warn / fail / skip result with a
  remediation hint for anything that needs attention.

  ## Usage

      mix lemon.doctor
      mix lemon.doctor --verbose
      mix lemon.doctor --json

  ## Options

      --verbose, -v       Show all checks including passing and skipped ones.
      --json              Output results as a JSON document (CI-friendly).
      --project-dir PATH  Use a specific project directory for project-config checks.

  ## Exit codes

      0  All checks passed or warned (no failures).
      1  One or more checks failed.
  """

  @impl true
  def run(args) do
    start_apps!()

    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        switches: [verbose: :boolean, json: :boolean, project_dir: :string],
        aliases: [v: :verbose]
      )

    check_opts = Keyword.take(opts, [:project_dir])

    checks =
      []
      |> append_checks(Config.run(check_opts))
      |> append_checks(Secrets.run(check_opts))
      |> append_checks(Runtime.run(check_opts))
      |> append_checks(Providers.run(check_opts))
      |> append_checks(NodeTools.run(check_opts))
      |> append_checks(Skills.run(check_opts))

    report = Report.from_checks(checks)

    if opts[:json] do
      Mix.shell().info(Report.to_json(report))
    else
      Report.print(report, verbose: opts[:verbose] || false)
    end

    unless Report.ok?(report) do
      Mix.raise("Diagnostics failed: #{report.fail} check(s) failed.")
    end
  end

  defp append_checks(acc, checks), do: acc ++ checks

  defp start_apps! do
    Mix.Task.run("loadpaths")

    case Application.ensure_all_started(:lemon_core) do
      {:ok, _} -> :ok
      {:error, {app, reason}} -> Mix.raise("Failed to start #{app}: #{inspect(reason)}")
    end
  end
end
