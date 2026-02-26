defmodule Mix.Tasks.Lemon.Cleanup do
  use Mix.Task

  alias LemonCore.Quality.Cleanup

  @shortdoc "Scan or prune stale docs/agent-loop run artifacts"
  @moduledoc """
  Scan cleanup candidates and optionally prune old run artifacts.

  Usage:
    mix lemon.cleanup
    mix lemon.cleanup --retention-days 21
    mix lemon.cleanup --apply
    mix lemon.cleanup --apply --retention-days 30
  """

  @impl true
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        switches: [apply: :boolean, retention_days: :integer, root: :string],
        aliases: [a: :apply, d: :retention_days, r: :root]
      )

    root = opts[:root] || File.cwd!()
    apply_changes = opts[:apply] || false
    retention_days = opts[:retention_days] || 14

    report =
      Cleanup.prune(
        root: root,
        apply: apply_changes,
        retention_days: retention_days
      )

    Mix.shell().info("Cleanup scan complete")
    Mix.shell().info("- root: #{report.root}")
    Mix.shell().info("- retention_days: #{report.retention_days}")
    Mix.shell().info("- old_run_files: #{length(report.old_run_files)}")
    Mix.shell().info("- stale_docs: #{length(report.stale_docs)}")

    if apply_changes do
      Mix.shell().info("- deleted_files: #{length(report.deleted_files)}")
    else
      Mix.shell().info("- mode: dry-run (use --apply to delete old run files)")
    end

    print_sample("Old run files", report.old_run_files)
    print_sample("Stale docs", Enum.map(report.stale_docs, &format_stale_doc/1))
  end

  defp print_sample(_label, []), do: :ok

  defp print_sample(label, values) do
    Mix.shell().info("#{label} (showing up to 10):")

    values
    |> Enum.take(10)
    |> Enum.each(fn value -> Mix.shell().info("  - #{value}") end)
  end

  defp format_stale_doc(issue) do
    "#{issue.path}: #{issue.message}"
  end
end
