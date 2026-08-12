defmodule LemonCore.Doctor.Checks.Memory do
  @moduledoc """
  Checks the session_search feature state against durable memory store health.

  `session_search` is `"default-on"`, so a stock install expects the SQLite
  memory store (`memory.sqlite3`) to be reachable. This check reports the
  resolved feature state, whether the store is actually available (exqlite NIF
  loaded, store process running), the document count and database file size,
  and how recently a run was ingested. It warns — never fails — when the
  feature is active but the store is unavailable, since agents still run fine
  with memory disabled.
  """

  alias LemonCore.Config.Features
  alias LemonCore.Config.Modular
  alias LemonCore.Doctor.Check
  alias LemonCore.Doctor.RuntimeModules

  # lemon_memory depends on lemon_core, so the store module is looked up via
  # the :doctor_runtime registry (see RuntimeModules) and only called through
  # apply/3. The optional exqlite NIF is probed by name.
  @sqlite_module Exqlite.Sqlite3

  @kill_switch_hint "To turn durable memory off entirely, set LEMON_FEATURE_SESSION_SEARCH=off (or `[features] session_search = \"off\"` in config.toml)."

  @spec run(keyword()) :: [Check.t()]
  def run(opts \\ []) do
    features = Keyword.get_lazy(opts, :features, fn -> load_features(opts) end)
    state = Map.get(features, :session_search, :off)
    enabled? = Features.enabled?(features, :session_search)

    [
      session_search_check(state, enabled?, store_status(opts), opts)
    ]
  end

  defp session_search_check(state, false, _store, _opts) do
    Check.pass(
      "memory.session_search",
      "session_search is #{state} — durable memory ingest and search are inactive."
    )
  end

  defp session_search_check(state, true, {:ok, stats}, opts) do
    Check.pass(
      "memory.session_search",
      "session_search is #{state}: memory store available, #{stats_summary(stats, opts)}."
    )
  end

  defp session_search_check(state, true, {:unavailable, reason}, _opts) do
    Check.warn(
      "memory.session_search",
      "session_search is #{state} but the memory store is unavailable (#{reason_text(reason)}). " <>
        "Runs are not being recorded and memory search returns no results.",
      remediation(reason)
    )
  end

  # ── Store status ───────────────────────────────────────────────────────────

  defp store_status(opts) do
    store = Keyword.get_lazy(opts, :store_module, fn -> RuntimeModules.fetch(:memory_store) end)

    cond do
      not exqlite_loaded?(opts) ->
        {:unavailable, :exqlite_not_loaded}

      is_nil(store) or
          not (Code.ensure_loaded?(store) and function_exported?(store, :stats, 0)) ->
        {:unavailable, :store_module_missing}

      not store_process_alive?(store) ->
        {:unavailable, :store_not_running}

      true ->
        {:ok, apply(store, :stats, [])}
    end
  end

  defp exqlite_loaded?(opts) do
    Keyword.get_lazy(opts, :exqlite_loaded, fn -> Code.ensure_loaded?(@sqlite_module) end)
  end

  defp store_process_alive?(store) do
    case GenServer.whereis(store) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  # ── Message parts ──────────────────────────────────────────────────────────

  defp stats_summary(stats, opts) do
    total = Map.get(stats, :total, 0)

    [
      "#{total} document(s)",
      db_size_part(opts),
      last_ingest_part(Map.get(stats, :newest_ms))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  defp db_size_part(opts) do
    path = Keyword.get_lazy(opts, :store_path, &default_store_path/0)

    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> "db #{format_bytes(size)}"
      {:error, _} -> nil
    end
  end

  # Mirrors the memory store's path resolution: an explicit store path wins,
  # otherwise memory.sqlite3 lands next to the main store's data.
  defp default_store_path do
    raw = configured_store_dir() || fallback_store_dir()
    Path.join(Path.expand(raw), "memory.sqlite3")
  end

  defp configured_store_dir do
    case RuntimeModules.fetch(:memory_store) do
      nil ->
        nil

      store ->
        :lemon_memory
        |> Application.get_env(store, [])
        |> Keyword.get(:path)
    end
  end

  defp fallback_store_dir do
    Application.get_env(:lemon_core, LemonCore.Store, [])
    |> Keyword.get(:backend_opts, [])
    |> Keyword.get(:path, "~/.lemon/store")
  end

  defp last_ingest_part(newest_ms) when is_integer(newest_ms) do
    age_ms = max(System.system_time(:millisecond) - newest_ms, 0)
    "last ingest #{format_age(age_ms)} ago"
  end

  defp last_ingest_part(_), do: "no runs ingested yet"

  defp reason_text(:exqlite_not_loaded), do: "the exqlite SQLite NIF is not loaded"
  defp reason_text(:store_module_missing), do: "the lemon_memory store module is not loaded"
  defp reason_text(:store_not_running), do: "the memory store process is not running"

  defp remediation(:exqlite_not_loaded) do
    "Ensure the :exqlite dependency compiles and its NIF loads in this build. " <>
      @kill_switch_hint
  end

  defp remediation(:store_module_missing) do
    "Include the :lemon_memory application in this release. " <> @kill_switch_hint
  end

  defp remediation(:store_not_running) do
    "Check startup logs for memory store init failures (store directory permissions, corrupt memory.sqlite3). " <>
      @kill_switch_hint
  end

  defp load_features(opts) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())
    Modular.load(project_dir: project_dir).features
  rescue
    _ -> %Features{}
  end

  defp format_bytes(size) when is_integer(size) and size >= 1_048_576,
    do: "#{Float.round(size / 1_048_576, 1)} MB"

  defp format_bytes(size) when is_integer(size) and size >= 1024,
    do: "#{Float.round(size / 1024, 1)} KB"

  defp format_bytes(size), do: "#{size} B"

  defp format_age(ms) when ms < 60_000, do: "#{div(ms, 1000)}s"
  defp format_age(ms) when ms < 3_600_000, do: "#{div(ms, 60_000)}m"
  defp format_age(ms) when ms < 86_400_000, do: "#{div(ms, 3_600_000)}h"
  defp format_age(ms), do: "#{div(ms, 86_400_000)}d"
end
