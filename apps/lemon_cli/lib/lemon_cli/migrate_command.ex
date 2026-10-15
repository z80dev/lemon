defmodule LemonCli.MigrateCommand do
  @moduledoc """
  Mix-free `lemon migrate hermes` command over `LemonCli.HermesMigration`.

      lemon migrate hermes audit [--source DIR] [--target DIR] [--json]
      lemon migrate hermes [--dry-run] [--yes] [--preset user-data|full] ...

  Audit is read-only. Migration always builds a preview first, refuses
  conflicts unless `--overwrite` is set, asks before writing unless `--yes`
  is set, and backs up the Lemon home first unless `--no-backup` is set.
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
    skill_conflict: :string
  ]

  @presets ~w(user-data full)
  @skill_conflicts ~w(skip rename)

  @spec run([String.t()], keyword()) :: 0 | 1 | 2
  def run(args, opts \\ []) do
    confirm = Keyword.get(opts, :confirm, &confirm?/1)

    case args do
      ["hermes", "audit" | rest] -> with_options(rest, @audit_switches, &audit/1)
      ["hermes" | rest] -> with_options(rest, @migrate_switches, &migrate(&1, confirm))
      _other -> usage_error("Expected `lemon migrate hermes [audit]`.")
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
      case Application.ensure_all_started(app) do
        {:ok, _started} ->
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
        with :ok <- maybe_backup(preview["target"], parsed[:no_backup]) do
          report = HermesMigration.apply(migration_opts)
          print_report(report, "Migration Complete")
          IO.puts("Report: #{report["output_dir"]}")
          0
        end
    end
  end

  defp maybe_backup(_target, true), do: :ok

  defp maybe_backup(target, _no_backup) do
    case HermesMigration.create_backup(target) do
      {:ok, path} ->
        IO.puts("Pre-migration backup: #{path}")
        :ok

      :none ->
        IO.puts("Pre-migration backup skipped: Lemon target does not exist yet")
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "Could not create pre-migration backup: #{inspect(reason)}")
        1
    end
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
      errors    : #{summary["error"]}\
    """)

    report["items"]
    |> Enum.filter(&(&1["status"] in ["conflict", "error", "unsupported", "gated"]))
    |> Enum.each(fn item ->
      key = if item["details"]["key"], do: " (#{item["details"]["key"]})", else: ""
      IO.puts("  #{item["status"]}: #{item["kind"]}#{key} #{item["source"]} -> #{item["reason"]}")
    end)
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
