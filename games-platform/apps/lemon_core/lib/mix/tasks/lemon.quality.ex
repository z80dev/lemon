defmodule Mix.Tasks.Lemon.Quality do
  use Mix.Task

  alias LemonCore.Config.Modular
  alias LemonCore.Quality.{ArchitectureCheck, DocsCheck}

  @shortdoc "Run docs and architecture quality checks"
  @moduledoc """
  Run quality checks that keep harness docs and architecture boundaries healthy.

  Usage:
    mix lemon.quality
    mix lemon.quality --root /path/to/repo
    mix lemon.quality --validate-config

  Options:
    --root PATH          Root directory to run checks from (default: current directory)
    --validate-config    Also validate Lemon configuration before running checks
  """

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        switches: [root: :string, validate_config: :boolean],
        aliases: [r: :root]
      )

    root = opts[:root] || File.cwd!()

    # Optionally validate config first
    config_valid? =
      if opts[:validate_config] do
        validate_config()
      else
        true
      end

    # Run duplicate test module guard
    duplicate_test_result = run_duplicate_test_check()

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

    # Add duplicate test check to failures if it failed
    failures =
      if duplicate_test_result == :error do
        [{:duplicate_tests, %{issue_count: 1, issues: []}} | failures]
      else
        failures
      end

    # Add config validation to failures if it failed
    failures =
      if opts[:validate_config] && !config_valid? do
        [{:config, %{issue_count: 1, issues: []}} | failures]
      else
        failures
      end

    if failures == [] do
      Mix.shell().info("All quality checks passed.")
    else
      Mix.raise("Quality checks failed (#{length(failures)} failing checks).")
    end
  end

  defp run_duplicate_test_check do
    Mix.shell().info("Running duplicate test module check...")
    try do
      Mix.Task.rerun("lemon.check_duplicate_tests")
      Mix.shell().info("[ok] duplicate test module check passed")
      :ok
    rescue
      e in Mix.Error ->
        Mix.shell().error("[error] duplicate test module check failed: #{Exception.message(e)}")
        :error
    end
  end

  defp validate_config do
    Mix.shell().info("Validating Lemon configuration...")

    case Modular.load_with_validation([]) do
      {:ok, _config} ->
        Mix.shell().info("[ok] config validation passed")
        true

      {:error, errors} ->
        Mix.shell().info("[error] config validation failed")

        Enum.each(errors, fn error ->
          Mix.shell().info("  • #{error}")
        end)

        false
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
