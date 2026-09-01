defmodule LemonCore.RunHistoryStore do
  @moduledoc """
  Dedicated store for run history, isolated from the main Store GenServer.

  Uses its own SQLite database (`run_history.sqlite3`) so that large
  conversation payloads never block secrets lookups, chat-state reads,
  or other latency-sensitive operations in the main store.

  Includes built-in retention: entries older than the configured TTL
  are swept periodically.

  ## Configuration

      config :lemon_core, LemonCore.RunHistoryStore,
        path: "~/.lemon/store",            # directory — run_history.sqlite3 created inside
        retention_ms: 7 * 24 * 3600_000,   # 7 days (default)
        max_per_session: 50                 # keep at most N entries per session_key

  ## Instances

  The store is named (default `LemonCore.RunHistoryStore`) and every public
  function takes an optional leading server argument, so additional instances
  can run alongside the default one:

      {LemonCore.RunHistoryStore, name: :scratch_history, path: "/tmp/scratch"}

  `start_link/1` opts win over the application env, which is read under the
  instance's name (`config :lemon_core, LemonCore.RunHistoryStore` for the
  default).
  """

  use GenServer
  require Logger

  alias Exqlite.Sqlite3

  # :exqlite is an optional dependency; LemonCore.Application only starts this
  # store when it is present. Without this, every project that depends on
  # lemon_core without exqlite gets seven undefined-function warnings from a
  # module it never uses — the first thing a new user sees. (LemonMemory.Store
  # carries the same attribute for the same reason.)
  @compile {:no_warn_undefined, Exqlite.Sqlite3}

  @default_retention_ms 7 * 24 * 60 * 60 * 1000
  @default_max_per_session 50
  @sweep_interval_ms 10 * 60 * 1000
  @filename "run_history.sqlite3"
  @compact_history_answer_bytes 16_000
  @compact_history_prompt_bytes 8_000

  @schema_sql """
  CREATE TABLE IF NOT EXISTS run_history (
    session_key TEXT NOT NULL,
    started_at_ms INTEGER NOT NULL,
    run_id TEXT NOT NULL,
    value_blob BLOB NOT NULL,
    PRIMARY KEY (session_key, started_at_ms, run_id)
  );
  """

  @index_sql """
  CREATE INDEX IF NOT EXISTS idx_run_history_session_recent
  ON run_history (session_key, started_at_ms DESC);
  """

  @put_sql """
  INSERT INTO run_history (session_key, started_at_ms, run_id, value_blob)
  VALUES (?1, ?2, ?3, ?4)
  ON CONFLICT(session_key, started_at_ms, run_id) DO UPDATE SET
    value_blob = excluded.value_blob
  """

  @get_by_session_sql """
  SELECT run_id, value_blob
  FROM run_history
  WHERE session_key = ?1
  ORDER BY started_at_ms DESC
  LIMIT ?2
  """

  @delete_sql """
  DELETE FROM run_history
  WHERE session_key = ?1 AND started_at_ms = ?2 AND run_id = ?3
  """

  @delete_by_session_sql """
  DELETE FROM run_history WHERE session_key = ?1
  """

  @sweep_sql """
  DELETE FROM run_history WHERE started_at_ms < ?1
  """

  @count_by_session_sql """
  SELECT COUNT(*) FROM run_history WHERE session_key = ?1
  """

  @trim_session_sql """
  DELETE FROM run_history
  WHERE rowid IN (
    SELECT rowid FROM run_history
    WHERE session_key = ?1
    ORDER BY started_at_ms ASC
    LIMIT ?2
  )
  """

  # -- Public API ----------------------------------------------------------

  @typedoc "A running run-history store: its registered name or its pid."
  @type server :: atom() | pid()

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    unless is_atom(name) and not is_nil(name) do
      raise ArgumentError,
            "LemonCore.RunHistoryStore :name must be an atom, got: #{inspect(name)}"
    end

    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc """
  Store a run history entry.
  """
  @spec put(server(), String.t(), integer(), String.t() | reference(), map()) :: :ok
  def put(server \\ __MODULE__, session_key, started_at_ms, run_id, data) do
    GenServer.cast(server, {:put, session_key, started_at_ms, run_id, data})
  end

  @doc """
  `LemonCore.RunStore` finalize hook: persist the finalized run's history.

  Wired by the runtime, not by the run store:

      config :lemon_core, LemonCore.RunStore,
        finalize_hooks: [{LemonCore.RunHistoryStore, :handle_finalize_run}]

  Pass a store instance name as a leading argument to target a non-default
  history store: `{LemonCore.RunHistoryStore, :handle_finalize_run, [:my_history]}`.
  """
  @spec handle_finalize_run(map()) :: :ok
  def handle_finalize_run(event), do: handle_finalize_run(__MODULE__, event)

  @spec handle_finalize_run(server(), map()) :: :ok
  def handle_finalize_run(server, %{
        run_id: run_id,
        session_key: session_key,
        started_at: started_at,
        record: record,
        summary: summary
      }) do
    put(server, session_key, started_at, run_id, %{
      events: Map.get(record, :events, []),
      summary: summary,
      session_key: session_key,
      run_id: run_id,
      started_at: started_at
    })
  end

  @doc """
  Fetch the most recent `limit` history entries for a session.

  Returns `[{run_id, data}, ...]` sorted by recency (newest first).
  """
  @spec get(String.t(), keyword()) :: [{term(), map()}]
  def get(session_key, opts \\ []), do: get(__MODULE__, session_key, opts)

  @doc """
  Fetch history for a session from a specific store instance.
  """
  @spec get(server(), String.t(), keyword()) :: [{term(), map()}]
  def get(server, session_key, opts) do
    limit = Keyword.get(opts, :limit, 10)

    GenServer.call(server, {:get, session_key, limit}, 5_000)
  catch
    :exit, _ -> []
  end

  @doc """
  Delete all history for a session.
  """
  @spec delete_session(server(), String.t()) :: :ok
  def delete_session(server \\ __MODULE__, session_key) do
    GenServer.cast(server, {:delete_session, session_key})
  end

  @doc """
  List all entries (for migration/debug). Expensive — avoid in production hot paths.
  """
  @spec list_all(server()) :: [{term(), map()}]
  def list_all(server \\ __MODULE__) do
    GenServer.call(server, :list_all, 30_000)
  catch
    :exit, _ -> []
  end

  # -- GenServer callbacks -------------------------------------------------

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    config =
      :lemon_core
      |> Application.get_env(name, [])
      |> Keyword.merge(Keyword.take(opts, [:path, :retention_ms, :max_per_session]))

    path = resolve_path(config, name)
    retention_ms = Keyword.get(config, :retention_ms, @default_retention_ms)
    max_per_session = Keyword.get(config, :max_per_session, @default_max_per_session)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, conn} <- Sqlite3.open(path),
         :ok <- init_db(conn),
         {:ok, stmts} <- prepare_statements(conn) do
      schedule_sweep()

      {:ok,
       %{
         conn: conn,
         stmts: stmts,
         path: path,
         retention_ms: retention_ms,
         max_per_session: max_per_session
       }}
    else
      {:error, reason} ->
        Logger.error("[RunHistoryStore] init failed: #{inspect(reason)}")
        {:stop, {:init_failed, reason}}
    end
  end

  @impl true
  def handle_cast({:put, session_key, started_at_ms, run_id, data}, state) do
    run_id_str = normalize_run_id(run_id)
    encoded = encode(data)

    case do_put(state, session_key, started_at_ms, run_id_str, encoded) do
      :ok ->
        maybe_trim_session(state, session_key)

      {:error, reason} ->
        if blob_too_big?(reason) do
          compact = compact_history_payload(data)
          compact_encoded = encode(compact)

          Logger.warning("[RunHistoryStore] payload too large, retrying compact write")

          case do_put(state, session_key, started_at_ms, run_id_str, compact_encoded) do
            :ok -> :ok
            {:error, r} -> Logger.error("[RunHistoryStore] compact put failed: #{inspect(r)}")
          end
        else
          Logger.error("[RunHistoryStore] put failed: #{inspect(reason)}")
        end
    end

    {:noreply, state}
  end

  def handle_cast({:delete_session, session_key}, state) do
    with :ok <- reset_and_bind(state.stmts.delete_by_session, [session_key]),
         :done <- Sqlite3.step(state.conn, state.stmts.delete_by_session) do
      :ok
    else
      err -> Logger.warning("[RunHistoryStore] delete_session failed: #{inspect(err)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({:get, session_key, limit}, _from, state) do
    result =
      with :ok <- reset_and_bind(state.stmts.get_by_session, [session_key, limit]),
           {:ok, rows} <- Sqlite3.fetch_all(state.conn, state.stmts.get_by_session) do
        Enum.reduce(rows, [], fn [run_id, value_blob], acc ->
          case decode(value_blob) do
            {:ok, data} -> [{run_id, data} | acc]
            {:error, _} -> acc
          end
        end)
        |> Enum.reverse()
      else
        err ->
          Logger.warning("[RunHistoryStore] get failed: #{inspect(err)}")
          []
      end

    {:reply, result, state}
  end

  def handle_call(:list_all, _from, state) do
    result =
      case Sqlite3.execute(
             state.conn,
             "SELECT session_key, started_at_ms, run_id, value_blob FROM run_history"
           ) do
        :ok ->
          []

        other ->
          Logger.warning("[RunHistoryStore] list_all unexpected: #{inspect(other)}")
          []
      end

    {:reply, result, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep_old_entries(state)
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private helpers -----------------------------------------------------

  defp resolve_path(config, name) do
    raw =
      Keyword.get(config, :path) ||
        Application.get_env(:lemon_core, LemonCore.Store, [])
        |> Keyword.get(:backend_opts, [])
        |> Keyword.get(:path, LemonCore.Paths.home_path("store"))

    dir = Path.expand(raw)
    Path.join(dir, filename(name))
  end

  # Instances keep their own database file so two of them can share a directory.
  defp filename(__MODULE__), do: @filename

  defp filename(name) do
    suffix =
      case Atom.to_string(name) do
        "Elixir." <> rest -> rest |> String.replace(".", "_") |> Macro.underscore()
        other -> other
      end

    "run_history_#{suffix}.sqlite3"
  end

  defp init_db(conn) do
    with :ok <- Sqlite3.execute(conn, "PRAGMA journal_mode=WAL"),
         :ok <- Sqlite3.execute(conn, "PRAGMA synchronous=NORMAL"),
         :ok <- Sqlite3.execute(conn, "PRAGMA temp_store=MEMORY"),
         :ok <- Sqlite3.execute(conn, "PRAGMA busy_timeout=5000"),
         :ok <- Sqlite3.execute(conn, @schema_sql),
         :ok <- Sqlite3.execute(conn, @index_sql) do
      :ok
    end
  end

  defp prepare_statements(conn) do
    with {:ok, put} <- Sqlite3.prepare(conn, @put_sql),
         {:ok, get_by_session} <- Sqlite3.prepare(conn, @get_by_session_sql),
         {:ok, delete} <- Sqlite3.prepare(conn, @delete_sql),
         {:ok, delete_by_session} <- Sqlite3.prepare(conn, @delete_by_session_sql),
         {:ok, sweep} <- Sqlite3.prepare(conn, @sweep_sql),
         {:ok, count} <- Sqlite3.prepare(conn, @count_by_session_sql),
         {:ok, trim} <- Sqlite3.prepare(conn, @trim_session_sql) do
      {:ok,
       %{
         put: put,
         get_by_session: get_by_session,
         delete: delete,
         delete_by_session: delete_by_session,
         sweep: sweep,
         count: count,
         trim: trim
       }}
    else
      {:error, reason} -> {:error, {:prepare_failed, reason}}
    end
  end

  defp do_put(state, session_key, started_at_ms, run_id_str, encoded_blob) do
    with :ok <-
           reset_and_bind(state.stmts.put, [
             session_key,
             started_at_ms,
             run_id_str,
             {:blob, encoded_blob}
           ]),
         :done <- Sqlite3.step(state.conn, state.stmts.put) do
      :ok
    else
      :busy -> {:error, :sqlite_busy}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:put_failed, other}}
    end
  end

  defp maybe_trim_session(state, session_key) do
    with :ok <- reset_and_bind(state.stmts.count, [session_key]),
         {:row, [count]} <- Sqlite3.step(state.conn, state.stmts.count) do
      excess = count - state.max_per_session

      if excess > 0 do
        with :ok <- reset_and_bind(state.stmts.trim, [session_key, excess]),
             :done <- Sqlite3.step(state.conn, state.stmts.trim) do
          :ok
        else
          err -> Logger.warning("[RunHistoryStore] trim failed: #{inspect(err)}")
        end
      end
    else
      _ -> :ok
    end
  end

  defp sweep_old_entries(state) do
    cutoff = System.system_time(:millisecond) - state.retention_ms

    with :ok <- reset_and_bind(state.stmts.sweep, [cutoff]),
         :done <- Sqlite3.step(state.conn, state.stmts.sweep) do
      :ok
    else
      err -> Logger.warning("[RunHistoryStore] sweep failed: #{inspect(err)}")
    end
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp reset_and_bind(stmt, params) do
    with :ok <- Sqlite3.reset(stmt),
         :ok <- Sqlite3.bind(stmt, params) do
      :ok
    end
  rescue
    e -> {:error, {:bind_failed, Exception.message(e)}}
  end

  defp encode(term), do: :erlang.term_to_binary(term)

  defp decode(binary) do
    {:ok, :erlang.binary_to_term(binary)}
  rescue
    _ -> {:error, :corrupt_data}
  end

  defp normalize_run_id(ref) when is_reference(ref), do: inspect(ref)
  defp normalize_run_id(id) when is_binary(id), do: id
  defp normalize_run_id(id), do: inspect(id)

  defp blob_too_big?({:sqlite_bind_failed, :blob_too_big}), do: true

  defp blob_too_big?(reason) when is_binary(reason),
    do: String.contains?(String.downcase(reason), "too big")

  defp blob_too_big?(_), do: false

  defp compact_history_payload(%{} = data) do
    summary = Map.get(data, :summary)

    data
    |> Map.put(:events, [])
    |> Map.put(:summary, compact_summary(summary))
  end

  defp compact_history_payload(other), do: other

  defp compact_summary(nil), do: nil

  defp compact_summary(summary) when is_map(summary) do
    completed =
      (Map.get(summary, :completed) || Map.get(summary, "completed"))
      |> compact_completed()

    summary
    |> put_any([:completed, "completed"], completed)
    |> truncate_any([:prompt, "prompt"], @compact_history_prompt_bytes)
  end

  defp compact_summary(other), do: other

  defp compact_completed(nil), do: nil

  defp compact_completed(completed) when is_map(completed) do
    completed
    |> truncate_any([:answer, "answer"], @compact_history_answer_bytes)
    |> truncate_any([:error, "error"], @compact_history_prompt_bytes)
  end

  defp compact_completed(other), do: other

  defp put_any(map, keys, value) when is_map(map) do
    case Enum.find(keys, &Map.has_key?(map, &1)) do
      nil -> Map.put(map, hd(keys), value)
      key -> Map.put(map, key, value)
    end
  end

  defp truncate_any(map, keys, max) when is_map(map) do
    Enum.reduce(keys, map, fn key, acc ->
      case Map.get(acc, key) do
        val when is_binary(val) and byte_size(val) > max ->
          Map.put(acc, key, binary_part(val, 0, max) <> "...[truncated]")

        _ ->
          acc
      end
    end)
  end
end
