defmodule Mix.Tasks.Lemon.Hermes.Audit do
  use Mix.Task

  alias LemonCli.HermesMigration

  @shortdoc "Audit Hermes data compatibility without writing files"
  @moduledoc """
  Audit a Hermes home directory before migration.

      mix lemon.hermes.audit
      mix lemon.hermes.audit --source ~/.hermes --target ~/.lemon
      mix lemon.hermes.audit --json

  The audit is read-only. It reports compatible, gated, partial, unsupported,
  missing, and error surfaces so migration gaps are explicit before apply.
  """

  @impl true
  def run(args) do
    start_apps!()

    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        switches: [
          source: :string,
          target: :string,
          json: :boolean
        ]
      )

    report =
      HermesMigration.audit(
        source: opts[:source],
        target: opts[:target]
      )

    if opts[:json] do
      Mix.shell().info(Jason.encode!(report, pretty: true))
    else
      print_report(report)
    end
  end

  defp print_report(report) do
    summary = report["summary"]
    Mix.shell().info("")
    Mix.shell().info("Hermes Compatibility Audit")
    Mix.shell().info("===========================")
    Mix.shell().info("Source: #{report["source"]}")
    Mix.shell().info("Target: #{report["target"]}")
    Mix.shell().info("")
    Mix.shell().info("  compatible  : #{summary["compatible"]}")
    Mix.shell().info("  gated       : #{summary["gated"]}")
    Mix.shell().info("  partial     : #{summary["partial"]}")
    Mix.shell().info("  unsupported : #{summary["unsupported"]}")
    Mix.shell().info("  missing     : #{summary["missing"]}")
    Mix.shell().info("  errors      : #{summary["error"]}")

    report["items"]
    |> Enum.reject(&(&1["status"] == "missing"))
    |> Enum.each(fn item ->
      Mix.shell().info("  #{item["status"]}: #{item["kind"]} - #{item["reason"]}")
    end)
  end

  defp start_apps! do
    Mix.Task.run("loadpaths")

    with {:ok, _} <- Application.ensure_all_started(:yaml_elixir),
         {:ok, _} <- Application.ensure_all_started(:lemon_core) do
      :ok
    else
      {:error, {app, reason}} -> Mix.raise("Failed to start #{app}: #{inspect(reason)}")
    end
  end
end
