defmodule Mix.Tasks.Lemon.Doctor do
  use Mix.Task

  alias LemonCore.Doctor
  alias LemonCore.Doctor.{Report, SupportBundle}

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
      mix lemon.doctor --bundle

  ## Options

      --verbose, -v       Show all checks including passing and skipped ones.
      --json              Output results as a JSON document (CI-friendly).
      --project-dir PATH  Use a specific project directory for project-config checks.
      --bundle            Write a redacted support bundle zip.
      --bundle-path PATH  Write the support bundle to a specific path.

  ## Exit codes

      0  All checks passed or warned (no failures).
      1  One or more checks failed.
  """

  @impl true
  def run(args) do
    start_apps!()

    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        switches: [
          verbose: :boolean,
          json: :boolean,
          project_dir: :string,
          bundle: :boolean,
          bundle_path: :string
        ],
        aliases: [v: :verbose]
      )

    check_opts = Keyword.take(opts, [:project_dir])
    report = Doctor.report(check_opts)

    if opts[:json] do
      Mix.shell().info(Report.to_json(report))
    else
      Report.print(report, verbose: opts[:verbose] || false)
    end

    if opts[:bundle] do
      case SupportBundle.write(report, bundle_opts(opts)) do
        {:ok, path} ->
          bundle_message = "Support bundle written: #{path}"

          if opts[:json] do
            Mix.shell().error(bundle_message)
          else
            Mix.shell().info(bundle_message)
          end

        {:error, reason} ->
          Mix.raise("Failed to write support bundle: #{inspect(reason)}")
      end
    end

    unless Report.ok?(report) do
      Mix.raise("Diagnostics failed: #{report.fail} check(s) failed.")
    end
  end

  defp bundle_opts(opts) do
    opts
    |> Keyword.take([:project_dir, :bundle_path])
    |> Keyword.new(fn
      {:bundle_path, value} -> {:bundle_path, value}
      other -> other
    end)
  end

  defp start_apps! do
    Mix.Task.run("loadpaths")

    case Application.ensure_all_started(:lemon_core) do
      {:ok, _} -> :ok
      {:error, {app, reason}} -> Mix.raise("Failed to start #{app}: #{inspect(reason)}")
    end
  end
end
