defmodule LemonCli.MigrateCommand do
  @moduledoc """
  Mix-free `lemon migrate hermes` command over `LemonCli.HermesMigration`.

      lemon migrate hermes audit [--source DIR] [--target DIR] [--json]
      lemon migrate hermes [--dry-run] [--yes] [--preset user-data|full] ...
      lemon migrate hermes rollback REPORT_DIR

  Audit is read-only. Migration always builds a preview first, refuses
  conflicts unless `--overwrite` is set, and asks before writing unless `--yes`
  is set. Apply and rollback run offline: they refuse while a Lemon runtime
  uses the target and hold the restore lifecycle locks throughout. Apply first
  takes a `LemonCore.Backup` bundle of the Lemon home (credential material
  excluded) unless `--no-backup` is set.
  Omitted `--overwrite` and `--yes` flags are false: conflicts still fail
  closed, and declining confirmation leaves the destination untouched.
  """

  alias LemonCli.CommandRegistry
  alias LemonCli.HermesMigration

  @audit_switches [source: :string, target: :string, json: :boolean]

  @migrate_switches [
    source: :string,
    target: :string,
    workspace_dir: :string,
    preset: :string,
    dry_run: :boolean,
    yes: :boolean,
    overwrite: :boolean,
    migrate_secrets: :boolean,
    no_backup: :boolean,
    include_skill_assets: :boolean,
    skill_conflict: :string
  ]

  @presets ~w(user-data full)
  @skill_conflicts ~w(skip rename)

  @spec run([String.t()], keyword()) :: 0 | 1 | 2
  def run(args, opts \\ []) do
    confirm = Keyword.get(opts, :confirm, &confirm?/1)

    case args do
      ["hermes", "audit" | rest] -> with_options(rest, @audit_switches, &audit/1)
      ["hermes", "rollback", report_dir] -> rollback(report_dir)
      ["hermes", "rollback" | _] -> usage_error("Expected `lemon migrate hermes rollback DIR`.")
      ["hermes" | rest] -> with_options(rest, @migrate_switches, &migrate(&1, confirm))
      _other -> usage_error("Expected `lemon migrate hermes [audit|rollback DIR]`.")
    end
  end

  defp with_options(args, switches, fun) do
    case OptionParser.parse(args, strict: switches) do
      {parsed, [], []} ->
        with :ok <- validate(parsed), :ok <- start_apps() do
          fun.(parsed)
        end

      {_parsed, positional, []} ->
        usage_error("Unsupported arguments: #{Enum.join(positional, " ")}")

      {_parsed, _positional, invalid} ->
        usage_error("Invalid options: #{inspect(invalid)}")
    end
  end

  defp validate(parsed) do
    cond do
      parsed[:preset] && parsed[:preset] not in @presets ->
        usage_error("--preset must be one of: #{Enum.join(@presets, ", ")}")

      parsed[:skill_conflict] && parsed[:skill_conflict] not in @skill_conflicts ->
        usage_error("--skill-conflict must be one of: #{Enum.join(@skill_conflicts, ", ")}")

      true ->
        :ok
    end
  end

  defp start_apps do
    Enum.reduce_while([:yaml_elixir, :lemon_core], :ok, fn app, :ok ->
      case LemonCore.CLI.start(app) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          IO.puts(:stderr, "Error: failed to start #{inspect(app)}: #{inspect(reason)}")
          {:halt, 1}
      end
    end)
  end

  defp audit(parsed) do
    report = HermesMigration.audit(source: parsed[:source], target: parsed[:target])

    if parsed[:json] do
      IO.puts(Jason.encode!(report, pretty: true))
    else
      print_audit(report)
    end

    0
  end

  defp migrate(parsed, confirm) do
    migration_opts = [
      source: parsed[:source],
      target: parsed[:target],
      workspace_dir: parsed[:workspace_dir],
      preset: parsed[:preset] || "user-data",
      overwrite: parsed[:overwrite] || false,
      migrate_secrets: parsed[:migrate_secrets] || false,
      include_skill_assets: parsed[:include_skill_assets] || false,
      skill_conflict: parsed[:skill_conflict] || "skip"
    ]

    preview = HermesMigration.preview(migration_opts)
    print_report(preview, "Migration Preview")

    cond do
      parsed[:dry_run] ->
        0

      HermesMigration.has_conflicts?(preview) and not Keyword.get(parsed, :overwrite, false) ->
        IO.puts(
          :stderr,
          "Migration has conflicts. Re-run with --overwrite or resolve them first."
        )

        1

      not Keyword.get(parsed, :yes, false) and not confirm.("Proceed with migration?") ->
        IO.puts("Migration cancelled.")
        0

      true ->
        report =
          HermesMigration.apply(
            migration_opts ++ [backup: not Keyword.get(parsed, :no_backup, false)]
          )

        print_apply(report, parsed[:no_backup])
    end
  end

  defp print_apply(%{"error" => error}, _no_backup) do
    IO.puts(:stderr, error)
    1
  end

  defp print_apply(report, no_backup) do
    cond do
      report["backup"] -> IO.puts("Pre-migration backup: #{report["backup"]}")
      no_backup -> :ok
      true -> IO.puts("Pre-migration backup skipped: Lemon target does not exist yet")
    end

    print_report(report, "Migration Complete")
    IO.puts("Report: #{report["output_dir"]}")
    0
  end

  defp print_audit(report) do
    summary = report["summary"]

    IO.puts("""

    Hermes Compatibility Audit
    ==========================
    Source: #{report["source"]}
    Target: #{report["target"]}

      compatible  : #{summary["compatible"]}
      gated       : #{summary["gated"]}
      partial     : #{summary["partial"]}
      unsupported : #{summary["unsupported"]}
      missing     : #{summary["missing"]}
      errors      : #{summary["error"]}\
    """)

    report["items"]
    |> Enum.reject(&(&1["status"] == "missing"))
    |> Enum.each(&IO.puts("  #{&1["status"]}: #{&1["kind"]} - #{&1["reason"]}"))
  end

  defp print_report(report, title) do
    summary = report["summary"]

    IO.puts("""

    #{title}
    #{String.duplicate("=", String.length(title))}
    Source: #{report["source"]}
    Target: #{report["target"]}

      planned   : #{summary["planned"]}
      migrated  : #{summary["migrated"]}
      archived  : #{summary["archived"]}
      skipped   : #{summary["skipped"]}
      conflicts : #{summary["conflict"]}
      unsupported : #{summary["unsupported"]}
      gated       : #{summary["gated"]}
      errors    : #{summary["error"]}
      warnings  : #{summary["warning"]}\
    """)

    report["items"]
    |> Enum.filter(&(&1["status"] in ["conflict", "error", "unsupported", "gated", "warning"]))
    |> Enum.each(fn item ->
      key = if item["details"]["key"], do: " (#{item["details"]["key"]})", else: ""
      IO.puts("  #{item["status"]}: #{item["kind"]}#{key} #{item["source"]} -> #{item["reason"]}")
    end)
  end

  defp rollback(report_dir) do
    with :ok <- start_apps() do
      report = HermesMigration.rollback(report_dir)

      IO.puts("""

      Migration Rollback
      ==================
      Report: #{report["report_dir"]}\
      """)

      report["items"]
      |> Enum.each(&IO.puts("  #{&1["status"]}: #{&1["source"]} -> #{&1["reason"]}"))

      if report["complete"] do
        0
      else
        IO.puts(:stderr, "Rollback incomplete: resolve the error and manual items above.")
        1
      end
    end
  end

  defp confirm?(question) do
    case IO.gets("#{question} [y/N] ") do
      answer when is_binary(answer) -> String.downcase(String.trim(answer)) in ["y", "yes"]
      _eof -> false
    end
  end

  defp usage_error(message) do
    IO.puts(:stderr, message)
    IO.puts(:stderr, "")
    IO.write(:stderr, CommandRegistry.help("migrate"))
    2
  end
end
