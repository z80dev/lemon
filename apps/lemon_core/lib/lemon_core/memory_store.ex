defmodule LemonCore.MemoryStore do
  @moduledoc """
  Durable store for normalized memory documents, isolated from `RunHistoryStore`.

  Uses its own SQLite database (`memory.sqlite3`) so that large conversation
  payloads in run history never block memory reads, and so that memory can be
  managed independently (retention, erasure by scope).

  Memory documents are compact, indexed summaries of finalized runs.  They are
  intended to support full-text search (M5-02) and routing feedback analytics
  (M6).

  ## Configuration

      config :lemon_core, LemonCore.MemoryStore,
        path: "~/.lemon/store",          # directory — memory.sqlite3 created inside
        retention_ms: 30 * 24 * 3600_000, # 30 days (default)
        max_per_scope: 500               # max documents per scope key

  ## Schema

  The `memory_documents` table stores one row per memory document.  FTS support
  (M5-02) will add a virtual `memory_fts` table over `prompt_summary` and
  `answer_summary`.
  """

  use GenServer
  require Logger

  alias Exqlite.Sqlite3
  alias LemonCore.MemoryDocument

  @default_retention_ms 30 * 24 * 60 * 60 * 1000
  @default_max_per_scope 500
  @sweep_interval_ms 15 * 60 * 1000
  @filename "memory.sqlite3"

  @schema_sql """
  CREATE TABLE IF NOT EXISTS memory_documents (
    doc_id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL,
    session_key TEXT NOT NULL,
    agent_id TEXT NOT NULL,
    workspace_key TEXT,
    scope TEXT NOT NULL DEFAULT 'session',
    started_at_ms INTEGER NOT NULL,
    ingested_at_ms INTEGER NOT NULL,
    prompt_summary TEXT NOT NULL DEFAULT '',
    answer_summary TEXT NOT NULL DEFAULT '',
    tools_used_blob BLOB NOT NULL,
    provider TEXT,
    model TEXT,
    outcome TEXT NOT NULL DEFAULT 'unknown',
    meta_blob BLOB NOT NULL
  );
  """

  @fts_schema_sql """
  CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(
    doc_id UNINDEXED,
    prompt_summary,
    answer_summary
  );
  """

  @index_sqls [
    """
    CREATE INDEX IF NOT EXISTS idx_mem_session
    ON memory_documents (session_key, ingested_at_ms DESC);
    """,
    """
    CREATE INDEX IF NOT EXISTS idx_mem_agent
    ON memory_documents (agent_id, ingested_at_ms DESC);
    """,
    """
    CREATE INDEX IF NOT EXISTS idx_mem_workspace
    ON memory_documents (workspace_key, ingested_at_ms DESC)
    WHERE workspace_key IS NOT NULL;
    """,
    """
    CREATE INDEX IF NOT EXISTS idx_mem_ingested
    ON memory_documents (ingested_at_ms DESC);
    """
  ]

  @put_sql """
  INSERT INTO memory_documents (
    doc_id, run_id, session_key, agent_id, workspace_key, scope,
    started_at_ms, ingested_at_ms,
    prompt_summary, answer_summary,
    tools_used_blob, provider, model, outcome, meta_blob
  )
  VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
  ON CONFLICT(doc_id) DO UPDATE SET
    ingested_at_ms = excluded.ingested_at_ms,
    prompt_summary = excluded.prompt_summary,
    answer_summary = excluded.answer_summary,
    tools_used_blob = excluded.tools_used_blob,
    provider = excluded.provider,
    model = excluded.model,
    outcome = excluded.outcome,
    meta_blob = excluded.meta_blob
  """

  @get_by_session_sql """
  SELECT doc_id, run_id, session_key, agent_id, workspace_key, scope,
         started_at_ms, ingested_at_ms,
         prompt_summary, answer_summary,
         tools_used_blob, provider, model, outcome, meta_blob
  FROM memory_documents
  WHERE session_key = ?1
  ORDER BY ingested_at_ms DESC
  LIMIT ?2
  """

  @get_by_agent_sql """
  SELECT doc_id, run_id, session_key, agent_id, workspace_key, scope,
         started_at_ms, ingested_at_ms,
         prompt_summary, answer_summary,
         tools_used_blob, provider, model, outcome, meta_blob
  FROM memory_documents
  WHERE agent_id = ?1
  ORDER BY ingested_at_ms DESC
  LIMIT ?2
  """

  @get_by_workspace_sql """
  SELECT doc_id, run_id, session_key, agent_id, workspace_key, scope,
         started_at_ms, ingested_at_ms,
         prompt_summary, answer_summary,
         tools_used_blob, provider, model, outcome, meta_blob
  FROM memory_documents
  WHERE workspace_key = ?1
  ORDER BY ingested_at_ms DESC
  LIMIT ?2
  """

  @delete_by_session_sql """
  DELETE FROM memory_documents WHERE session_key = ?1
  """

  @delete_by_agent_sql """
  DELETE FROM memory_documents WHERE agent_id = ?1
  """

  @delete_by_workspace_sql """
  DELETE FROM memory_documents WHERE workspace_key = ?1
  """

  @sweep_sql """
  DELETE FROM memory_documents WHERE ingested_at_ms < ?1
  """

  @stats_sql """
  SELECT COUNT(*) as total, MIN(ingested_at_ms) as oldest_ms, MAX(ingested_at_ms) as newest_ms
  FROM memory_documents
  """

  # FTS SQL (M5-02)
  @fts_put_sql """
  INSERT OR REPLACE INTO memory_fts(doc_id, prompt_summary, answer_summary)
  VALUES (?1, ?2, ?3)
  """

  @fts_delete_by_session_sql """
  DELETE FROM memory_fts WHERE doc_id IN (
    SELECT doc_id FROM memory_documents WHERE session_key = ?1
  )
  """

  @fts_delete_by_agent_sql """
  DELETE FROM memory_fts WHERE doc_id IN (
    SELECT doc_id FROM memory_documents WHERE agent_id = ?1
  )
  """

  @fts_delete_by_workspace_sql """
  DELETE FROM memory_fts WHERE doc_id IN (
    SELECT doc_id FROM memory_documents WHERE workspace_key = ?1
  )
  """

  @fts_sweep_sql """
  DELETE FROM memory_fts WHERE doc_id NOT IN (SELECT doc_id FROM memory_documents)
  """

  @search_session_sql """
  SELECT md.doc_id, md.run_id, md.session_key, md.agent_id, md.workspace_key, md.scope,
         md.started_at_ms, md.ingested_at_ms,
         md.prompt_summary, md.answer_summary,
         md.tools_used_blob, md.provider, md.model, md.outcome, md.meta_blob
  FROM memory_fts
  JOIN memory_documents md ON md.doc_id = memory_fts.doc_id
  WHERE memory_fts MATCH ?1 AND md.session_key = ?2
  ORDER BY memory_fts.rank
  LIMIT ?3
  """

  @search_agent_sql """
  SELECT md.doc_id, md.run_id, md.session_key, md.agent_id, md.workspace_key, md.scope,
         md.started_at_ms, md.ingested_at_ms,
         md.prompt_summary, md.answer_summary,
         md.tools_used_blob, md.provider, md.model, md.outcome, md.meta_blob
  FROM memory_fts
  JOIN memory_documents md ON md.doc_id = memory_fts.doc_id
  WHERE memory_fts MATCH ?1 AND md.agent_id = ?2
  ORDER BY memory_fts.rank
  LIMIT ?3
  """

  @search_workspace_sql """
  SELECT md.doc_id, md.run_id, md.session_key, md.agent_id, md.workspace_key, md.scope,
         md.started_at_ms, md.ingested_at_ms,
         md.prompt_summary, md.answer_summary,
         md.tools_used_blob, md.provider, md.model, md.outcome, md.meta_blob
  FROM memory_fts
  JOIN memory_documents md ON md.doc_id = memory_fts.doc_id
  WHERE memory_fts MATCH ?1 AND md.workspace_key = ?2
  ORDER BY memory_fts.rank
  LIMIT ?3
  """

  @search_all_sql """
  SELECT md.doc_id, md.run_id, md.session_key, md.agent_id, md.workspace_key, md.scope,
         md.started_at_ms, md.ingested_at_ms,
         md.prompt_summary, md.answer_summary,
         md.tools_used_blob, md.provider, md.model, md.outcome, md.meta_blob
  FROM memory_fts
  JOIN memory_documents md ON md.doc_id = memory_fts.doc_id
  WHERE memory_fts MATCH ?1
  ORDER BY memory_fts.rank
  LIMIT ?2
  """

  # max_per_scope enforcement SQL (M5-03)
  @overflowing_sessions_sql """
  SELECT session_key FROM memory_documents
  GROUP BY session_key
  HAVING COUNT(*) > ?1
  """

  @prune_session_sql """
  DELETE FROM memory_documents
  WHERE session_key = ?1
    AND doc_id NOT IN (
      SELECT doc_id FROM memory_documents
      WHERE session_key = ?1
      ORDER BY ingested_at_ms DESC
      LIMIT ?2
    )
  """

  # ── Public API ────────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Persist a `MemoryDocument`. This is a cast — write failures are logged but
  do not propagate to the caller.
  """
  @spec put(MemoryDocument.t()) :: :ok
  def put(%MemoryDocument{} = doc), do: put(__MODULE__, doc)

  @spec put(GenServer.server(), MemoryDocument.t()) :: :ok
  def put(server, %MemoryDocument{} = doc) do
    GenServer.cast(server, {:put, doc})
  end

  @doc """
  Fetch the `limit` most recent documents for a session.
  """
  @spec get_by_session(binary(), keyword()) :: [MemoryDocument.t()]
  def get_by_session(session_key, opts \\ []) when is_binary(session_key) do
    get_by_session(__MODULE__, session_key, opts)
  end

  @spec get_by_session(GenServer.server(), binary(), keyword()) :: [MemoryDocument.t()]
  def get_by_session(server, session_key, opts) when is_binary(session_key) do
    limit = Keyword.get(opts, :limit, 20)
    GenServer.call(server, {:get_by_session, session_key, limit}, 5_000)
  catch
    :exit, _ -> []
  end

  @doc """
  Fetch the `limit` most recent documents for an agent across all sessions.
  """
  @spec get_by_agent(binary(), keyword()) :: [MemoryDocument.t()]
  def get_by_agent(agent_id, opts \\ []) when is_binary(agent_id) do
    get_by_agent(__MODULE__, agent_id, opts)
  end

  @spec get_by_agent(GenServer.server(), binary(), keyword()) :: [MemoryDocument.t()]
  def get_by_agent(server, agent_id, opts) when is_binary(agent_id) do
    limit = Keyword.get(opts, :limit, 20)
    GenServer.call(server, {:get_by_agent, agent_id, limit}, 5_000)
  catch
    :exit, _ -> []
  end

  @doc """
  Fetch the `limit` most recent documents for a workspace.
  """
  @spec get_by_workspace(binary(), keyword()) :: [MemoryDocument.t()]
  def get_by_workspace(workspace_key, opts \\ []) when is_binary(workspace_key) do
    get_by_workspace(__MODULE__, workspace_key, opts)
  end

  @spec get_by_workspace(GenServer.server(), binary(), keyword()) :: [MemoryDocument.t()]
  def get_by_workspace(server, workspace_key, opts) when is_binary(workspace_key) do
    limit = Keyword.get(opts, :limit, 20)
    GenServer.call(server, {:get_by_workspace, workspace_key, limit}, 5_000)
  catch
    :exit, _ -> []
  end

  @doc """
  Delete all documents for a session scope.
  """
  @spec delete_by_session(binary()) :: :ok
  def delete_by_session(session_key) when is_binary(session_key) do
    delete_by_session(__MODULE__, session_key)
  end

  @spec delete_by_session(GenServer.server(), binary()) :: :ok
  def delete_by_session(server, session_key) when is_binary(session_key) do
    GenServer.cast(server, {:delete_by_session, session_key})
  end

  @doc """
  Delete all documents for an agent scope.
  """
  @spec delete_by_agent(binary()) :: :ok
  def delete_by_agent(agent_id) when is_binary(agent_id) do
    delete_by_agent(__MODULE__, agent_id)
  end

  @spec delete_by_agent(GenServer.server(), binary()) :: :ok
  def delete_by_agent(server, agent_id) when is_binary(agent_id) do
    GenServer.cast(server, {:delete_by_agent, agent_id})
  end

  @doc """
  Delete all documents for a workspace scope.
  """
  @spec delete_by_workspace(binary()) :: :ok
  def delete_by_workspace(workspace_key) when is_binary(workspace_key) do
    delete_by_workspace(__MODULE__, workspace_key)
  end

  @spec delete_by_workspace(GenServer.server(), binary()) :: :ok
  def delete_by_workspace(server, workspace_key) when is_binary(workspace_key) do
    GenServer.cast(server, {:delete_by_workspace, workspace_key})
  end

  @doc """
  Returns aggregate stats: total count, oldest/newest ingestion timestamps.
  """
  @spec stats() :: map()
  def stats, do: stats(__MODULE__)

  @spec stats(GenServer.server()) :: map()
  def stats(server) do
    GenServer.call(server, :stats, 5_000)
  catch
    :exit, _ -> %{total: 0, oldest_ms: nil, newest_ms: nil}
  end

  @doc """
  Full-text search over `prompt_summary` and `answer_summary`.

  ## Options

  - `:scope` - `:session` (default), `:agent`, `:workspace`, `:all`
  - `:scope_key` - session_key / agent_id / workspace_key (required if scope != `:all`)
  - `:limit` - max results (default 5)
  """
  @spec search(binary(), keyword()) :: [MemoryDocument.t()]
  def search(query, opts \\ []) when is_binary(query) do
    search(__MODULE__, query, opts)
  end

  @spec search(GenServer.server(), binary(), keyword()) :: [MemoryDocument.t()]
  def search(server, query, opts) when is_binary(query) do
    scope = Keyword.get(opts, :scope, :session)
    scope_key = Keyword.get(opts, :scope_key)
    limit = Keyword.get(opts, :limit, 5)
    GenServer.call(server, {:search, query, scope, scope_key, limit}, 5_000)
  catch
    :exit, _ -> []
  end

  @doc """
  Synchronously enforce retention and max-per-scope limits.

  Deletes documents older than `retention_ms` and trims any session that
  exceeds `max_per_scope` documents (keeping the most recent ones).

  Returns `{:ok, %{swept: integer(), pruned: integer()}}`.
  """
  @spec prune() :: {:ok, map()} | {:error, term()}
  def prune, do: prune(__MODULE__)

  @spec prune(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def prune(server) do
    GenServer.call(server, :prune, 30_000)
  catch
    :exit, reason -> {:error, {:timeout_or_down, reason}}
  end

  # ── GenServer callbacks ────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    app_config = Application.get_env(:lemon_core, __MODULE__, [])
    # opts passed to start_link take precedence over application env
    config = Keyword.merge(app_config, Keyword.drop(opts, [:name]))

    path = resolve_path(config)
    retention_ms = Keyword.get(config, :retention_ms, @default_retention_ms)
    max_per_scope = Keyword.get(config, :max_per_scope, @default_max_per_scope)

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
         max_per_scope: max_per_scope
       }}
    else
      {:error, reason} ->
        Logger.error("[MemoryStore] init failed: #{inspect(reason)}")
        {:stop, {:init_failed, reason}}
    end
  end

  @impl true
  def handle_cast({:put, doc}, state) do
    case do_put(state, doc) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[MemoryStore] put failed doc_id=#{doc.doc_id}: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_cast({:delete_by_session, session_key}, state) do
    run_delete(state.conn, state.stmts.fts_delete_by_session, [session_key], "fts_delete_by_session")
    run_delete(state.conn, state.stmts.delete_by_session, [session_key], "delete_by_session")
    {:noreply, state}
  end

  def handle_cast({:delete_by_agent, agent_id}, state) do
    run_delete(state.conn, state.stmts.fts_delete_by_agent, [agent_id], "fts_delete_by_agent")
    run_delete(state.conn, state.stmts.delete_by_agent, [agent_id], "delete_by_agent")
    {:noreply, state}
  end

  def handle_cast({:delete_by_workspace, workspace_key}, state) do
    run_delete(state.conn, state.stmts.fts_delete_by_workspace, [workspace_key], "fts_delete_by_workspace")
    run_delete(state.conn, state.stmts.delete_by_workspace, [workspace_key], "delete_by_workspace")
    {:noreply, state}
  end

  @impl true
  def handle_call({:get_by_session, session_key, limit}, _from, state) do
    result = do_query(state, state.stmts.get_by_session, [session_key, limit])
    {:reply, result, state}
  end

  def handle_call({:get_by_agent, agent_id, limit}, _from, state) do
    result = do_query(state, state.stmts.get_by_agent, [agent_id, limit])
    {:reply, result, state}
  end

  def handle_call({:get_by_workspace, workspace_key, limit}, _from, state) do
    result = do_query(state, state.stmts.get_by_workspace, [workspace_key, limit])
    {:reply, result, state}
  end

  def handle_call({:search, query, scope, scope_key, limit}, _from, state) do
    result = do_search(state, query, scope, scope_key, limit)
    {:reply, result, state}
  end

  def handle_call(:prune, _from, state) do
    result = do_prune(state)
    {:reply, result, state}
  end

  def handle_call(:stats, _from, state) do
    result =
      with :ok <- Sqlite3.reset(state.stmts.stats),
           {:ok, rows} <- Sqlite3.fetch_all(state.conn, state.stmts.stats) do
        case rows do
          [[total, oldest_ms, newest_ms]] ->
            %{total: total || 0, oldest_ms: oldest_ms, newest_ms: newest_ms}

          _ ->
            %{total: 0, oldest_ms: nil, newest_ms: nil}
        end
      else
        err ->
          Logger.warning("[MemoryStore] stats failed: #{inspect(err)}")
          %{total: 0, oldest_ms: nil, newest_ms: nil}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep_old_documents(state)
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Sqlite3.close(state.conn)
    :ok
  rescue
    _ -> :ok
  end

  # ── Private helpers ────────────────────────────────────────────────────────────

  defp resolve_path(config) do
    raw =
      Keyword.get(config, :path) ||
        Application.get_env(:lemon_core, LemonCore.Store, [])
        |> Keyword.get(:backend_opts, [])
        |> Keyword.get(:path, "~/.lemon/store")

    dir = Path.expand(raw)
    Path.join(dir, @filename)
  end

  defp init_db(conn) do
    with :ok <- Sqlite3.execute(conn, "PRAGMA journal_mode=WAL"),
         :ok <- Sqlite3.execute(conn, "PRAGMA synchronous=NORMAL"),
         :ok <- Sqlite3.execute(conn, "PRAGMA temp_store=MEMORY"),
         :ok <- Sqlite3.execute(conn, "PRAGMA busy_timeout=5000"),
         :ok <- Sqlite3.execute(conn, @schema_sql),
         :ok <- Sqlite3.execute(conn, @fts_schema_sql) do
      Enum.reduce_while(@index_sqls, :ok, fn sql, :ok ->
        case Sqlite3.execute(conn, sql) do
          :ok -> {:cont, :ok}
          err -> {:halt, err}
        end
      end)
    end
  end

  defp prepare_statements(conn) do
    with {:ok, put} <- Sqlite3.prepare(conn, @put_sql),
         {:ok, get_by_session} <- Sqlite3.prepare(conn, @get_by_session_sql),
         {:ok, get_by_agent} <- Sqlite3.prepare(conn, @get_by_agent_sql),
         {:ok, get_by_workspace} <- Sqlite3.prepare(conn, @get_by_workspace_sql),
         {:ok, delete_by_session} <- Sqlite3.prepare(conn, @delete_by_session_sql),
         {:ok, delete_by_agent} <- Sqlite3.prepare(conn, @delete_by_agent_sql),
         {:ok, delete_by_workspace} <- Sqlite3.prepare(conn, @delete_by_workspace_sql),
         {:ok, sweep} <- Sqlite3.prepare(conn, @sweep_sql),
         {:ok, stats} <- Sqlite3.prepare(conn, @stats_sql),
         {:ok, fts_put} <- Sqlite3.prepare(conn, @fts_put_sql),
         {:ok, fts_delete_by_session} <- Sqlite3.prepare(conn, @fts_delete_by_session_sql),
         {:ok, fts_delete_by_agent} <- Sqlite3.prepare(conn, @fts_delete_by_agent_sql),
         {:ok, fts_delete_by_workspace} <- Sqlite3.prepare(conn, @fts_delete_by_workspace_sql),
         {:ok, fts_sweep} <- Sqlite3.prepare(conn, @fts_sweep_sql),
         {:ok, search_session} <- Sqlite3.prepare(conn, @search_session_sql),
         {:ok, search_agent} <- Sqlite3.prepare(conn, @search_agent_sql),
         {:ok, search_workspace} <- Sqlite3.prepare(conn, @search_workspace_sql),
         {:ok, search_all} <- Sqlite3.prepare(conn, @search_all_sql),
         {:ok, overflowing_sessions} <- Sqlite3.prepare(conn, @overflowing_sessions_sql),
         {:ok, prune_session} <- Sqlite3.prepare(conn, @prune_session_sql) do
      {:ok,
       %{
         put: put,
         get_by_session: get_by_session,
         get_by_agent: get_by_agent,
         get_by_workspace: get_by_workspace,
         delete_by_session: delete_by_session,
         delete_by_agent: delete_by_agent,
         delete_by_workspace: delete_by_workspace,
         sweep: sweep,
         stats: stats,
         fts_put: fts_put,
         fts_delete_by_session: fts_delete_by_session,
         fts_delete_by_agent: fts_delete_by_agent,
         fts_delete_by_workspace: fts_delete_by_workspace,
         fts_sweep: fts_sweep,
         search_session: search_session,
         search_agent: search_agent,
         search_workspace: search_workspace,
         search_all: search_all,
         overflowing_sessions: overflowing_sessions,
         prune_session: prune_session
       }}
    else
      {:error, reason} -> {:error, {:prepare_failed, reason}}
    end
  end

  defp do_put(state, %MemoryDocument{} = doc) do
    tools_blob = encode(doc.tools_used)
    meta_blob = encode(doc.meta)

    params = [
      doc.doc_id,
      doc.run_id,
      doc.session_key,
      doc.agent_id,
      doc.workspace_key,
      Atom.to_string(doc.scope),
      doc.started_at_ms,
      doc.ingested_at_ms,
      doc.prompt_summary,
      doc.answer_summary,
      {:blob, tools_blob},
      doc.provider,
      doc.model,
      Atom.to_string(doc.outcome),
      {:blob, meta_blob}
    ]

    :ok = Sqlite3.execute(state.conn, "BEGIN")

    with :ok <- Sqlite3.reset(state.stmts.put),
         :ok <- Sqlite3.bind(state.stmts.put, params),
         :done <- Sqlite3.step(state.conn, state.stmts.put),
         :ok <- Sqlite3.reset(state.stmts.fts_put),
         :ok <- Sqlite3.bind(state.stmts.fts_put, [doc.doc_id, doc.prompt_summary, doc.answer_summary]),
         :done <- Sqlite3.step(state.conn, state.stmts.fts_put) do
      :ok = Sqlite3.execute(state.conn, "COMMIT")
      :ok
    else
      err ->
        Sqlite3.execute(state.conn, "ROLLBACK")

        case err do
          :busy -> {:error, :sqlite_busy}
          {:error, reason} -> {:error, reason}
          other -> {:error, {:put_failed, other}}
        end
    end
  rescue
    e ->
      Sqlite3.execute(state.conn, "ROLLBACK")
      {:error, {:exception, Exception.message(e)}}
  end

  defp do_query(state, stmt, params) do
    with :ok <- Sqlite3.reset(stmt),
         :ok <- Sqlite3.bind(stmt, params),
         {:ok, rows} <- Sqlite3.fetch_all(state.conn, stmt) do
      Enum.flat_map(rows, fn row ->
        case decode_row(row) do
          {:ok, doc} -> [doc]
          {:error, _} -> []
        end
      end)
    else
      err ->
        Logger.warning("[MemoryStore] query failed: #{inspect(err)}")
        []
    end
  end

  defp decode_row([
         doc_id, run_id, session_key, agent_id, workspace_key, scope,
         started_at_ms, ingested_at_ms,
         prompt_summary, answer_summary,
         tools_used_blob, provider, model, outcome, meta_blob
       ]) do
    with {:ok, tools_used} <- decode(tools_used_blob),
         {:ok, meta} <- decode(meta_blob) do
      doc = %MemoryDocument{
        doc_id: doc_id,
        run_id: run_id,
        session_key: session_key,
        agent_id: agent_id,
        workspace_key: workspace_key,
        scope: safe_atom(scope, :session),
        started_at_ms: started_at_ms,
        ingested_at_ms: ingested_at_ms,
        prompt_summary: prompt_summary || "",
        answer_summary: answer_summary || "",
        tools_used: tools_used,
        provider: provider,
        model: model,
        outcome: safe_atom(outcome, :unknown),
        meta: meta
      }

      {:ok, doc}
    end
  end

  defp decode_row(_), do: {:error, :invalid_row}

  defp run_delete(conn, stmt, params, op) do
    with :ok <- Sqlite3.reset(stmt),
         :ok <- Sqlite3.bind(stmt, params),
         :done <- Sqlite3.step(conn, stmt) do
      :ok
    else
      err -> Logger.warning("[MemoryStore] #{op} failed: #{inspect(err)}")
    end
  rescue
    e -> Logger.warning("[MemoryStore] #{op} exception: #{Exception.message(e)}")
  end

  defp do_prune(state) do
    # Step 1: retention sweep
    swept = do_retention_sweep(state)

    # Step 2: max_per_scope enforcement — prune oldest per session_key
    pruned = do_max_per_scope_prune(state)

    {:ok, %{swept: swept, pruned: pruned}}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp do_retention_sweep(state) do
    cutoff = System.system_time(:millisecond) - state.retention_ms

    with :ok <- Sqlite3.reset(state.stmts.sweep),
         :ok <- Sqlite3.bind(state.stmts.sweep, [cutoff]),
         :done <- Sqlite3.step(state.conn, state.stmts.sweep) do
      # Count deletions from the main table before touching FTS.
      n =
        case Sqlite3.changes(state.conn) do
          {:ok, n} -> n
          _ -> 0
        end

      with :ok <- Sqlite3.reset(state.stmts.fts_sweep),
           :done <- Sqlite3.step(state.conn, state.stmts.fts_sweep) do
        :ok
      else
        err -> Logger.warning("[MemoryStore] fts sweep failed: #{inspect(err)}")
      end

      n
    else
      err ->
        Logger.warning("[MemoryStore] retention sweep in prune failed: #{inspect(err)}")
        0
    end
  end

  defp do_max_per_scope_prune(state) do
    max = state.max_per_scope

    sessions =
      with :ok <- Sqlite3.reset(state.stmts.overflowing_sessions),
           :ok <- Sqlite3.bind(state.stmts.overflowing_sessions, [max]),
           {:ok, rows} <- Sqlite3.fetch_all(state.conn, state.stmts.overflowing_sessions) do
        Enum.map(rows, fn [session_key] -> session_key end)
      else
        _ -> []
      end

    Enum.reduce(sessions, 0, fn session_key, count ->
      with :ok <- Sqlite3.reset(state.stmts.prune_session),
           :ok <- Sqlite3.bind(state.stmts.prune_session, [session_key, max]),
           :done <- Sqlite3.step(state.conn, state.stmts.prune_session) do
        # Count deletions from main table before touching FTS.
        n =
          case Sqlite3.changes(state.conn) do
            {:ok, n} -> n
            _ -> 0
          end

        # Sync FTS after pruning this session (reuses fts_sweep — same SQL).
        with :ok <- Sqlite3.reset(state.stmts.fts_sweep),
             :done <- Sqlite3.step(state.conn, state.stmts.fts_sweep) do
          :ok
        else
          err ->
            Logger.warning(
              "[MemoryStore] fts prune failed for '#{session_key}': #{inspect(err)}"
            )
        end

        count + n
      else
        _ -> count
      end
    end)
  end

  defp sweep_old_documents(state) do
    cutoff = System.system_time(:millisecond) - state.retention_ms

    with :ok <- Sqlite3.reset(state.stmts.sweep),
         :ok <- Sqlite3.bind(state.stmts.sweep, [cutoff]),
         :done <- Sqlite3.step(state.conn, state.stmts.sweep),
         :ok <- Sqlite3.reset(state.stmts.fts_sweep),
         :done <- Sqlite3.step(state.conn, state.stmts.fts_sweep) do
      :ok
    else
      err -> Logger.warning("[MemoryStore] sweep failed: #{inspect(err)}")
    end
  end

  defp do_search(state, query, scope, scope_key, limit) do
    safe_query = sanitize_fts_query(query)

    # Scoped searches with a nil scope_key must NOT fall back to :all
    if scope in [:session, :agent, :workspace] and not is_binary(scope_key) do
      []
    else
      {stmt, params} =
        case scope do
          :session ->
            {state.stmts.search_session, [safe_query, scope_key, limit]}

          :agent ->
            {state.stmts.search_agent, [safe_query, scope_key, limit]}

          :workspace ->
            {state.stmts.search_workspace, [safe_query, scope_key, limit]}

          _ ->
            {state.stmts.search_all, [safe_query, limit]}
        end

      do_query(state, stmt, params)
    end
  end

  # Strip FTS5 special characters and join tokens for AND-matching.
  # Individual words must all appear in the document; order doesn't matter.
  defp sanitize_fts_query(query) when is_binary(query) do
    query
    |> String.replace(~r/["*():.,!?;]+/, " ")
    |> String.split()
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp encode(term), do: :erlang.term_to_binary(term)

  defp decode(binary) when is_binary(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    _ -> {:error, :corrupt_data}
  end

  defp decode(nil), do: {:ok, %{}}

  defp safe_atom(str, default) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    _ -> default
  end

  defp safe_atom(_, default), do: default
end
