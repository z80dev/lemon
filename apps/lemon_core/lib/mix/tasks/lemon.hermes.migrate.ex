defmodule Mix.Tasks.Lemon.Hermes.Migrate do
  use Mix.Task

  alias LemonCore.HermesMigration

  @shortdoc "Migrate compatible Hermes data into Lemon"
  @moduledoc """
  Migrate a Hermes home directory into Lemon.

      mix lemon.hermes.migrate --dry-run
      mix lemon.hermes.migrate --yes
      mix lemon.hermes.migrate --preset full --migrate-secrets --yes

  The task previews first, refuses conflicts unless `--overwrite` is set, and
  only imports secrets when `--migrate-secrets` is provided.
  """

  @impl true
  def run(args) do
    start_apps!()

    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        switches: [
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
      )

    migration_opts = [
      source: opts[:source],
      target: opts[:target],
      workspace_dir: opts[:workspace_dir],
      preset: opts[:preset] || "user-data",
      overwrite: opts[:overwrite] || false,
      migrate_secrets: opts[:migrate_secrets] || false,
      skill_conflict: opts[:skill_conflict] || "skip"
    ]

    preview = HermesMigration.preview(migration_opts)
    print_report(preview, "Migration Preview")

    cond do
      opts[:dry_run] ->
        :ok

      HermesMigration.has_conflicts?(preview) and not opts[:overwrite] ->
        Mix.raise("Migration has conflicts. Re-run with --overwrite or resolve them first.")

      not opts[:yes] and not confirm?("Proceed with migration?") ->
        Mix.shell().info("Migration cancelled.")

      true ->
        unless opts[:no_backup] do
          case HermesMigration.create_backup(preview["target"]) do
            {:ok, path} ->
              Mix.shell().info("Pre-migration backup: #{path}")

            :none ->
              Mix.shell().info("Pre-migration backup skipped: Lemon target does not exist yet")

            {:error, reason} ->
              Mix.raise("Could not create pre-migration backup: #{inspect(reason)}")
          end
        end

        report = HermesMigration.apply(migration_opts)
        print_report(report, "Migration Complete")
        Mix.shell().info("Report: #{report["output_dir"]}")
    end
  end

  defp print_report(report, title) do
    summary = report["summary"]
    Mix.shell().info("")
    Mix.shell().info(title)
    Mix.shell().info(String.duplicate("=", String.length(title)))
    Mix.shell().info("Source: #{report["source"]}")
    Mix.shell().info("Target: #{report["target"]}")
    Mix.shell().info("")
    Mix.shell().info("  planned   : #{summary["planned"]}")
    Mix.shell().info("  migrated  : #{summary["migrated"]}")
    Mix.shell().info("  archived  : #{summary["archived"]}")
    Mix.shell().info("  skipped   : #{summary["skipped"]}")
    Mix.shell().info("  conflicts : #{summary["conflict"]}")
    Mix.shell().info("  errors    : #{summary["error"]}")

    report["items"]
    |> Enum.filter(&(&1["status"] in ["conflict", "error"]))
    |> Enum.each(fn item ->
      Mix.shell().info(
        "  #{item["status"]}: #{item["kind"]} #{item["source"]} -> #{item["reason"]}"
      )
    end)
  end

  defp confirm?(question) do
    if IO.ANSI.enabled?() and function_exported?(Mix.shell(), :yes?, 1) do
      Mix.shell().yes?(question)
    else
      answer = Mix.shell().prompt("#{question} [y/N] ") |> String.trim() |> String.downcase()
      answer in ["y", "yes"]
    end
  rescue
    _ -> false
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
