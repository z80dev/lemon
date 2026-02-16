defmodule Mix.Tasks.Lemon.Store.MigrateJsonlToSqlite do
  use Mix.Task

  alias LemonCore.Store.JsonlBackend
  alias LemonCore.Store.SqliteBackend

  @shortdoc "Migrate Lemon store data from JSONL files to SQLite"
  @moduledoc """
  One-time migration tool from JSONL-backed Lemon store data to SQLite.

  By default this migrates all tables except `:runs` (which is typically configured
  as ephemeral for SQLite).

  Usage:
    mix lemon.store.migrate_jsonl_to_sqlite
    mix lemon.store.migrate_jsonl_to_sqlite --jsonl-path ~/.lemon/store --sqlite-path ~/.lemon/store/store.sqlite3
    mix lemon.store.migrate_jsonl_to_sqlite --dry-run
    mix lemon.store.migrate_jsonl_to_sqlite --include-runs
    mix lemon.store.migrate_jsonl_to_sqlite --replace
  """

  @impl true
  def run(args) do
    Mix.Task.run("loadpaths")

    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        switches: [
          jsonl_path: :string,
          sqlite_path: :string,
          dry_run: :boolean,
          include_runs: :boolean,
          replace: :boolean
        ]
      )

    jsonl_path =
      opts[:jsonl_path] ||
        System.get_env("LEMON_STORE_PATH") ||
        Path.expand("~/.lemon/store")

    sqlite_path = opts[:sqlite_path] || default_sqlite_path(jsonl_path)
    dry_run? = opts[:dry_run] || false
    include_runs? = opts[:include_runs] || false
    replace? = opts[:replace] || false

    unless File.dir?(jsonl_path) do
      Mix.raise("JSONL store directory not found: #{jsonl_path}")
    end

    if replace? and File.exists?(sqlite_path) and not dry_run? do
      File.rm!(sqlite_path)
      Mix.shell().info("Removed existing SQLite DB: #{sqlite_path}")
    end

    Mix.shell().info("JSONL path: #{jsonl_path}")
    Mix.shell().info("SQLite path: #{sqlite_path}")
    Mix.shell().info("Mode: #{if(dry_run?, do: "dry-run", else: "migrate")}")

    skipped_tables =
      if include_runs? do
        []
      else
        [:runs]
      end

    with {:ok, jsonl_state} <- JsonlBackend.init(path: jsonl_path, skip_tables: skipped_tables) do
      tables =
        jsonl_state
        |> JsonlBackend.list_tables()
        |> Enum.sort()

      tables_to_migrate = Enum.reject(tables, &(&1 in skipped_tables))

      if tables_to_migrate == [] do
        Mix.shell().info("No tables to migrate.")
        :ok
      else
        Mix.shell().info(
          "Tables to migrate: #{Enum.map_join(tables_to_migrate, ", ", &to_string/1)}"
        )

        if skipped_tables != [] do
          Mix.shell().info("Skipped tables: #{Enum.map_join(skipped_tables, ", ", &to_string/1)}")
        end

        if dry_run? do
          run_dry(jsonl_state, tables_to_migrate)
        else
          run_migration(jsonl_state, tables_to_migrate, sqlite_path)
        end
      end
    else
      {:error, reason} ->
        Mix.raise("Failed to initialize JSONL backend: #{inspect(reason)}")
    end
  end

  defp run_dry(jsonl_state, tables) do
    {_jsonl_state, total_rows} =
      Enum.reduce(tables, {jsonl_state, 0}, fn table, {state, total} ->
        {:ok, entries, state} = JsonlBackend.list(state, table)
        count = length(entries)
        Mix.shell().info("  #{table}: #{count} rows")
        {state, total + count}
      end)

    Mix.shell().info("Dry run complete. Total rows: #{total_rows}")
    :ok
  end

  defp run_migration(jsonl_state, tables, sqlite_path) do
    {:ok, sqlite_state} = SqliteBackend.init(path: sqlite_path, ephemeral_tables: [])

    try do
      {_jsonl_state, _sqlite_state, total_rows} =
        Enum.reduce(tables, {jsonl_state, sqlite_state, 0}, fn table,
                                                               {src_state, dst_state, total} ->
          {:ok, entries, src_state} = JsonlBackend.list(src_state, table)

          {dst_state, copied} =
            Enum.reduce(entries, {dst_state, 0}, fn {key, value}, {acc_state, count} ->
              case SqliteBackend.put(acc_state, table, key, value) do
                {:ok, new_state} -> {new_state, count + 1}
                {:error, reason} -> Mix.raise("Failed migrating #{table}: #{inspect(reason)}")
              end
            end)

          Mix.shell().info("  #{table}: copied #{copied} rows")
          {src_state, dst_state, total + copied}
        end)

      Mix.shell().info("Migration complete. Total rows copied: #{total_rows}")
      :ok
    after
      SqliteBackend.close(sqlite_state)
    end
  end

  defp default_sqlite_path(jsonl_path) do
    db_env = System.get_env("LEMON_STORE_DB_PATH")

    cond do
      is_binary(db_env) and db_env != "" ->
        Path.expand(db_env)

      File.dir?(jsonl_path) ->
        Path.join(Path.expand(jsonl_path), "store.sqlite3")

      true ->
        Path.expand(jsonl_path)
    end
  end
end
