defmodule Mix.Tasks.Lemon.Quality do
  use Mix.Task

  alias LemonCore.Quality.{ArchitectureCheck, DocsCheck}

  @shortdoc "Run docs and architecture quality checks"
  @moduledoc """
  Run quality checks that keep harness docs and architecture boundaries healthy.

  Usage:
    mix lemon.quality
    mix lemon.quality --root /path/to/repo
  """

  @impl true
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        switches: [root: :string],
        aliases: [r: :root]
      )

    root = opts[:root] || File.cwd!()

    checks = [
      {:docs, fn -> DocsCheck.run(root: root) end},
      {:architecture, fn -> ArchitectureCheck.run(root: root) end}
    ]

    failures =
      Enum.reduce(checks, [], fn {name, check_fun}, acc ->
        case check_fun.() do
          {:ok, report} ->
            Mix.shell().info("[ok] #{name} check passed (#{report.issue_count} issues)")
            acc

          {:error, report} ->
            print_report(name, report)
            [{name, report} | acc]
        end
      end)

    if failures == [] do
      Mix.shell().info("All quality checks passed.")
    else
      Mix.raise("Quality checks failed (#{length(failures)} failing checks).")
    end
  end

  defp print_report(name, report) do
    Mix.shell().error("[error] #{name} check failed (#{report.issue_count} issues)")

    Enum.each(report.issues, fn issue ->
      label = issue.path || issue.app || "n/a"
      Mix.shell().error("  - [#{issue.code}] #{label}: #{issue.message}")
    end)
  end
end
