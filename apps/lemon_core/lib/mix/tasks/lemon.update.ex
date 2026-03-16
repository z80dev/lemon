defmodule Mix.Tasks.Lemon.Update do
  use Mix.Task

  alias LemonCore.Config.Modular
  alias LemonCore.Update.{ConfigMigrator, Version}

  @shortdoc "Update Lemon: config migration and bundled-skill sync"

  @moduledoc """
  Stage-1 Lemon update: config migration and bundled-skill sync.

  Runs three idempotent stages:

  1. **Version check** — reports the current version.
     (Remote update download arrives in a later milestone.)
  2. **Config migration** — detects and migrates deprecated TOML sections.
  3. **Bundled-skill sync** — ensures all repository-bundled skills are present.

  ## Usage

      mix lemon.update
      mix lemon.update --check
      mix lemon.update --migrate-config
      mix lemon.update --config-path ~/.lemon/config.toml

  ## Options

      --check, -c             Dry run: report what would change, make no changes.
      --migrate-config        Run only the config migration stage, then exit.
      --config-path PATH      Config file to check/migrate (default: global config).
      --verbose, -v           Print details for each stage.
      --no-skill-sync         Skip the bundled-skill sync stage.

  ## Exit codes

      0  All stages completed (or dry run succeeded).
      1  One or more stages failed.
  """

  @impl true
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        switches: [
          check: :boolean,
          migrate_config: :boolean,
          config_path: :string,
          verbose: :boolean,
          no_skill_sync: :boolean
        ],
        aliases: [c: :check, v: :verbose]
      )

    start_apps!(opts)

    check_only? = opts[:check] || false
    verbose? = opts[:verbose] || false
    config_path = opts[:config_path] || Modular.global_path()

    results =
      if opts[:migrate_config] do
        [run_config_migration(config_path, check_only?, verbose?)]
      else
        [
          run_version_check(verbose?),
          run_config_migration(config_path, check_only?, verbose?),
          (unless opts[:no_skill_sync], do: run_skill_sync(check_only?, verbose?))
        ]
        |> Enum.reject(&is_nil/1)
      end

    failed? = Enum.any?(results, &(&1 == :error))

    if failed? do
      Mix.raise("lemon.update encountered failures. Review output above.")
    end

    :ok
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Stage runners
  # ──────────────────────────────────────────────────────────────────────────

  defp run_version_check(verbose?) do
    version = Version.current()
    shell = Mix.shell()

    shell.info("Version: #{version}")

    if verbose? do
      if Version.valid?(version) do
        shell.info("  Format: CalVer (YYYY.MM.PATCH) — valid")
      else
        shell.info("  Format: non-CalVer (running from source checkout)")
      end

      shell.info("  Remote update check: not yet available (see docs/release/versioning_and_channels.md)")
    end

    :ok
  end

  defp run_config_migration(config_path, check_only?, verbose?) do
    shell = Mix.shell()
    expanded = Path.expand(config_path)

    if not File.exists?(expanded) do
      if verbose?, do: shell.info("Config migration: no config file at #{expanded} — skipping.")
      :ok
    else
      case ConfigMigrator.check(config_path) do
        :ok ->
          shell.info("Config: no deprecated sections found.")
          :ok

        {:needs_migration, issues} ->
          shell.info("Config: #{length(issues)} deprecated section(s) found:")
          Enum.each(issues, &shell.info("  • #{&1}"))

          if check_only? do
            shell.info("  (--check mode: no changes made)")
            :ok
          else
            shell.info("  Migrating #{expanded} ...")
            bak = ConfigMigrator.backup_path(config_path)

            case ConfigMigrator.migrate!(config_path) do
              :ok ->
                shell.info("  Migration complete. Backup: #{bak}")
                :ok

              {:error, reason} ->
                shell.error("  Migration failed: #{inspect(reason)}")
                :error
            end
          end

        {:error, reason} ->
          shell.error("Config: could not check #{expanded}: #{inspect(reason)}")
          :error
      end
    end
  end

  defp run_skill_sync(check_only?, verbose?) do
    shell = Mix.shell()

    cond do
      check_only? ->
        if verbose?, do: shell.info("Skill sync: --check mode, skipping.")
        :ok

      Code.ensure_loaded?(LemonSkills.BuiltinSeeder) ->
        shell.info("Skill sync: refreshing bundled skills ...")
        LemonSkills.BuiltinSeeder.seed!()

        if Code.ensure_loaded?(LemonSkills.Migrator) do
          case LemonSkills.Migrator.migrate() do
            {:ok, %{classified: n}} when n > 0 ->
              shell.info("Skill sync: classified #{n} existing skill(s) with provenance.")

            _ ->
              :ok
          end
        end

        shell.info("Skill sync: complete.")
        :ok

      true ->
        if verbose?, do: shell.info("Skill sync: lemon_skills not available, skipping.")
        :ok
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Private helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp start_apps!(opts) do
    check_only? = opts[:check] || false

    Mix.Task.run("loadpaths")

    case Application.ensure_all_started(:lemon_core) do
      {:ok, _} ->
        :ok

      {:error, {app, reason}} ->
        unless check_only? do
          Mix.raise("Failed to start #{app}: #{inspect(reason)}")
        end
    end
  end
end
