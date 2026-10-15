defmodule LemonMemory.Store do
  @moduledoc """
  Durable store for normalized memory documents, isolated from `RunHistoryStore`.

  Uses its own SQLite database (`memory.sqlite3`) so that large conversation
  payloads in run history never block memory reads, and so that memory can be
  managed independently (retention, erasure by scope).

  Memory documents are compact, indexed summaries of finalized runs. They back
  full-text recall (the `recall` tool and automatic per-turn recall) and routing
  feedback analytics.

  ## Configuration

      config :lemon_memory, LemonMemory.Store,
        path: "~/.lemon/store",          # directory — memory.sqlite3 created inside
        retention_ms: 30 * 24 * 3600_000, # 30 days (default)
        max_per_scope: 500               # max documents per scope key

  ## Schema

  The `memory_documents` table stores one row per memory document, mirrored into
  the FTS5 virtual table `memory_fts` over `prompt_summary` and `answer_summary`.

  ## Search

  `search/3` builds its `MATCH` expression with `LemonMemory.Query.fts_match/1`:
  stopwords are dropped, the remaining terms are quoted and `OR`-joined (terms of
  four or more characters as prefixes), and results are ordered by
  `bm25(memory_fts)`. A query with no search terms returns `[]` without touching
  SQLite.
  """

  use GenServer
  require Logger

  alias Exqlite.Sqlite3
  alias LemonMemory.{ContextScope, Document, Query}

  # :exqlite is an optional dependency of lemon_core; LemonCore.Application only
  # starts this store when it is present.
  @compile {:no_warn_undefined, Exqlite.Sqlite3}

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
    meta_blob BLOB NOT NULL,
    memory_scope TEXT,
    memory_context_key TEXT,
    home_digest TEXT,
    memory_kind TEXT,
    repository_root TEXT
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
    """,
    """
    CREATE INDEX IF NOT EXISTS idx_mem_owner
    ON memory_documents (agent_id, home_digest, memory_scope, memory_context_key, repository_root, ingested_at_ms DESC);
    """
  ]

  @put_sql """
  INSERT INTO memory_documents (
    doc_id, run_id, session_key, agent_id, workspace_key, scope,
    started_at_ms, ingested_at_ms,
    prompt_summary, answer_summary,
    tools_used_blob, provider, model, outcome, meta_blob,
    memory_scope, memory_context_key, home_digest, memory_kind, repository_root
  )
  VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20)
  ON CONFLICT(doc_id) DO UPDATE SET
    ingested_at_ms = excluded.ingested_at_ms,
    prompt_summary = excluded.prompt_summary,
    answer_summary = excluded.answer_summary,
    tools_used_blob = excluded.tools_used_blob,
    provider = excluded.provider,
    model = excluded.model,
    outcome = excluded.outcome,
    meta_blob = excluded.meta_blob,
    memory_scope = excluded.memory_scope,
    memory_context_key = excluded.memory_context_key,
    home_digest = excluded.home_digest,
    memory_kind = excluded.memory_kind,
    repository_root = excluded.repository_root
  """

  @put_new_sql """
  INSERT INTO memory_documents (
    doc_id, run_id, session_key, agent_id, workspace_key, scope,
    started_at_ms, ingested_at_ms,
    prompt_summary, answer_summary,
    tools_used_blob, provider, model, outcome, meta_blob,
    memory_scope, memory_context_key, home_digest, memory_kind, repository_root
  )
  VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20)
  ON CONFLICT(doc_id) DO NOTHING
  """

  @get_document_sql """
  SELECT doc_id, run_id, session_key, agent_id, workspace_key, scope,
         started_at_ms, ingested_at_ms,
         prompt_summary, answer_summary,
         tools_used_blob, provider, model, outcome, meta_blob,
         memory_scope, memory_context_key, home_digest, memory_kind, repository_root
  FROM memory_documents
  WHERE doc_id = ?1
  LIMIT 1
  """

  @get_owned_document_sql """
  SELECT doc_id, run_id, session_key, agent_id, workspace_key, scope,
         started_at_ms, ingested_at_ms, prompt_summary, answer_summary,
         tools_used_blob, provider, model, outcome, meta_blob,
         memory_scope, memory_context_key, home_digest, memory_kind, repository_root
  FROM memory_documents
  WHERE doc_id = ?1 AND agent_id = ?2 AND home_digest = ?3 AND memory_scope = ?4
    AND (memory_context_key = ?5 OR (?5 IS NULL AND memory_context_key IS NULL))
  """

  @get_by_session_sql """
  SELECT doc_id, run_id, session_key, agent_id, workspace_key, scope,
         started_at_ms, ingested_at_ms,
         prompt_summary, answer_summary,
         tools_used_blob, provider, model, outcome, meta_blob,
         memory_scope, memory_context_key, home_digest, memory_kind, repository_root
  FROM memory_documents
  WHERE session_key = ?1
  ORDER BY ingested_at_ms DESC, doc_id DESC
  LIMIT ?2
  """

  @get_by_agent_sql """
  SELECT doc_id, run_id, session_key, agent_id, workspace_key, scope,
         started_at_ms, ingested_at_ms,
         prompt_summary, answer_summary,
         tools_used_blob, provider, model, outcome, meta_blob,
         memory_scope, memory_context_key, home_digest, memory_kind, repository_root
  FROM memory_documents
  WHERE agent_id = ?1
  ORDER BY ingested_at_ms DESC, doc_id DESC
  LIMIT ?2
  """

  @owned_recent_sql """
  SELECT doc_id, run_id, session_key, agent_id, workspace_key, scope,
         started_at_ms, ingested_at_ms, prompt_summary, answer_summary,
         tools_used_blob, provider, model, outcome, meta_blob,
         memory_scope, memory_context_key, home_digest, memory_kind, repository_root
  FROM memory_documents
  WHERE agent_id = ?1 AND home_digest = ?2
    AND (memory_scope = ?3 OR (?3 = 'legacy' AND memory_scope IS NULL))
    AND (memory_context_key = ?4 OR (?4 IS NULL AND memory_context_key IS NULL))
    AND (?5 = 0 OR memory_kind IN ('user', 'memory'))
  ORDER BY ingested_at_ms DESC, doc_id DESC
  LIMIT ?6
  """

  @get_by_workspace_sql """
  SELECT doc_id, run_id, session_key, agent_id, workspace_key, scope,
         started_at_ms, ingested_at_ms,
         prompt_summary, answer_summary,
         tools_used_blob, provider, model, outcome, meta_blob,
         memory_scope, memory_context_key, home_digest, memory_kind, repository_root
  FROM memory_documents
  WHERE workspace_key = ?1
  ORDER BY ingested_at_ms DESC, doc_id DESC
  LIMIT ?2
  """

  # Watermark variants. These order ASC on purpose: a caller draining a backlog
  # with a `since_ms` cursor must receive the OLDEST unseen window, so the
  # cursor only ever advances over a contiguous prefix. Pairing `since_ms` with
  # a DESC limit would let a backlog larger than `limit` be skipped forever
  # (the cursor jumps to the newest row, and the rows below the limit can never
  # satisfy `ingested_at_ms > since_ms` again).
  @get_by_session_since_sql """
  SELECT doc_id, run_id, session_key, agent_id, workspace_key, scope,
         started_at_ms, ingested_at_ms,
         prompt_summary, answer_summary,
         tools_used_blob, provider, model, outcome, meta_blob,
         memory_scope, memory_context_key, home_digest, memory_kind, repository_root
  FROM memory_documents
  WHERE session_key = ?1 AND ingested_at_ms > ?2
  ORDER BY ingested_at_ms ASC, doc_id ASC
  LIMIT ?3
  """

  @get_by_agent_since_sql """
  SELECT doc_id, run_id, session_key, agent_id, workspace_key, scope,
         started_at_ms, ingested_at_ms,
         prompt_summary, answer_summary,
         tools_used_blob, provider, model, outcome, meta_blob,
         memory_scope, memory_context_key, home_digest, memory_kind, repository_root
  FROM memory_documents
  WHERE agent_id = ?1 AND ingested_at_ms > ?2
  ORDER BY ingested_at_ms ASC, doc_id ASC
  LIMIT ?3
  """

  @get_by_workspace_since_sql """
  SELECT doc_id, run_id, session_key, agent_id, workspace_key, scope,
         started_at_ms, ingested_at_ms,
         prompt_summary, answer_summary,
         tools_used_blob, provider, model, outcome, meta_blob,
         memory_scope, memory_context_key, home_digest, memory_kind, repository_root
  FROM memory_documents
  WHERE workspace_key = ?1 AND ingested_at_ms > ?2
  ORDER BY ingested_at_ms ASC, doc_id ASC
  LIMIT ?3
  """

  @list_recent_sql """
  SELECT doc_id, run_id, session_key, agent_id, workspace_key, scope,
         started_at_ms, ingested_at_ms,
         prompt_summary, answer_summary,
         tools_used_blob, provider, model, outcome, meta_blob,
         memory_scope, memory_context_key, home_digest, memory_kind, repository_root
  FROM memory_documents
  ORDER BY ingested_at_ms DESC, doc_id DESC
  LIMIT ?1
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

  @delete_document_sql """
  DELETE FROM memory_documents WHERE doc_id = ?1
  """

  @fts_delete_document_sql """
  DELETE FROM memory_fts WHERE doc_id = ?1
  """

  @sweep_sql """
  DELETE FROM memory_documents WHERE ingested_at_ms < ?1
    AND COALESCE(memory_kind, 'run') NOT IN ('user', 'memory', 'project_learning')
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
         md.tools_used_blob, md.provider, md.model, md.outcome, md.meta_blob,
         md.memory_scope, md.memory_context_key, md.home_digest, md.memory_kind, md.repository_root
  FROM memory_fts
  JOIN memory_documents md ON md.doc_id = memory_fts.doc_id
  WHERE memory_fts MATCH ?1 AND md.session_key = ?2
  ORDER BY bm25(memory_fts)
  LIMIT ?3
  """

  @search_agent_sql """
  SELECT md.doc_id, md.run_id, md.session_key, md.agent_id, md.workspace_key, md.scope,
         md.started_at_ms, md.ingested_at_ms,
         md.prompt_summary, md.answer_summary,
         md.tools_used_blob, md.provider, md.model, md.outcome, md.meta_blob,
         md.memory_scope, md.memory_context_key, md.home_digest, md.memory_kind, md.repository_root
  FROM memory_fts
  JOIN memory_documents md ON md.doc_id = memory_fts.doc_id
  WHERE memory_fts MATCH ?1 AND md.agent_id = ?2
  ORDER BY bm25(memory_fts)
  LIMIT ?3
  """

  @search_workspace_sql """
  SELECT md.doc_id, md.run_id, md.session_key, md.agent_id, md.workspace_key, md.scope,
         md.started_at_ms, md.ingested_at_ms,
         md.prompt_summary, md.answer_summary,
         md.tools_used_blob, md.provider, md.model, md.outcome, md.meta_blob,
         md.memory_scope, md.memory_context_key, md.home_digest, md.memory_kind, md.repository_root
  FROM memory_fts
  JOIN memory_documents md ON md.doc_id = memory_fts.doc_id
  WHERE memory_fts MATCH ?1 AND md.workspace_key = ?2
  ORDER BY bm25(memory_fts)
  LIMIT ?3
  """

  @search_all_sql """
  SELECT md.doc_id, md.run_id, md.session_key, md.agent_id, md.workspace_key, md.scope,
         md.started_at_ms, md.ingested_at_ms,
         md.prompt_summary, md.answer_summary,
         md.tools_used_blob, md.provider, md.model, md.outcome, md.meta_blob,
         md.memory_scope, md.memory_context_key, md.home_digest, md.memory_kind, md.repository_root
  FROM memory_fts
  JOIN memory_documents md ON md.doc_id = memory_fts.doc_id
  WHERE memory_fts MATCH ?1
  ORDER BY bm25(memory_fts)
  LIMIT ?2
  """

  @owned_search_sql """
  SELECT md.doc_id, md.run_id, md.session_key, md.agent_id, md.workspace_key, md.scope,
         md.started_at_ms, md.ingested_at_ms, md.prompt_summary, md.answer_summary,
         md.tools_used_blob, md.provider, md.model, md.outcome, md.meta_blob,
         md.memory_scope, md.memory_context_key, md.home_digest, md.memory_kind, md.repository_root
  FROM memory_fts
  JOIN memory_documents md ON md.doc_id = memory_fts.doc_id
  WHERE memory_fts MATCH ?1 AND md.agent_id = ?2 AND md.home_digest = ?3
    AND (md.memory_scope = ?4 OR (?4 = 'legacy' AND md.memory_scope IS NULL))
    AND (md.memory_context_key = ?5 OR (?5 IS NULL AND md.memory_context_key IS NULL))
    AND (?7 = 0 OR COALESCE(md.memory_kind, 'run') NOT IN ('user', 'memory', 'project_learning'))
    AND (?6 IS NULL OR md.repository_root = ?6)
  ORDER BY bm25(memory_fts), md.ingested_at_ms DESC, md.doc_id DESC
  LIMIT ?8
  """

  # max_per_scope enforcement SQL (M5-03)
  @overflowing_sessions_sql """
  SELECT session_key FROM memory_documents
  WHERE COALESCE(memory_kind, 'run') NOT IN ('user', 'memory', 'project_learning')
  GROUP BY session_key
  HAVING COUNT(*) > ?1
  """

  @prune_session_sql """
  DELETE FROM memory_documents
  WHERE session_key = ?1
    AND COALESCE(memory_kind, 'run') NOT IN ('user', 'memory', 'project_learning')
    AND doc_id NOT IN (
      SELECT doc_id FROM memory_documents
      WHERE session_key = ?1
        AND COALESCE(memory_kind, 'run') NOT IN ('user', 'memory', 'project_learning')
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
  Persist a `Document`. This is a cast — write failures are logged but
  do not propagate to the caller.
  """
  @spec put(Document.t()) :: :ok
  def put(%Document{} = doc), do: put(__MODULE__, doc)

  @spec put(GenServer.server(), Document.t()) :: :ok
  def put(server, %Document{} = doc) do
    GenServer.cast(server, {:put, doc})
  end

  @doc """
  Persist one document synchronously.

  This is intended for explicit review/confirm workflows that must not report
  success before SQLite has accepted the exact document. Ordinary finalized-run
  ingestion should continue using `put/1` so it does not block the run path.
  """
  @spec put_sync(Document.t()) :: :ok | {:error, term()}
  def put_sync(%Document{} = doc), do: put_sync(__MODULE__, doc)

  @spec put_sync(GenServer.server(), Document.t()) :: :ok | {:error, term()}
  def put_sync(server, %Document{} = doc) do
    GenServer.call(server, {:put_sync, doc}, 5_000)
  catch
    :exit, reason -> {:error, {:timeout_or_down, reason}}
  end

  @doc "Replace a note only if the exact persisted revision still exists."
  def put_document_if_unchanged(server, %Document{} = doc, revision) do
    GenServer.call(server, {:put_if_unchanged, doc, revision}, 5_000)
  catch
    :exit, reason -> {:error, {:timeout_or_down, reason}}
  end

  @doc "Synchronously create one document without overwriting an existing ID."
  @spec put_new_sync(Document.t()) :: {:ok, :created | :exists} | {:error, term()}
  def put_new_sync(%Document{} = doc), do: put_new_sync(__MODULE__, doc)

  @spec put_new_sync(GenServer.server(), Document.t()) ::
          {:ok, :created | :exists} | {:error, term()}
  def put_new_sync(server, %Document{} = doc) do
    GenServer.call(server, {:put_new_sync, doc}, 5_000)
  catch
    :exit, reason -> {:error, {:timeout_or_down, reason}}
  end

  @doc "Fetch one exact document ID."
  @spec get_document(binary()) :: {:ok, Document.t()} | {:error, term()}
  def get_document(doc_id) when is_binary(doc_id), do: get_document(__MODULE__, doc_id)

  @spec get_document(GenServer.server(), binary()) :: {:ok, Document.t()} | {:error, term()}
  def get_document(server, doc_id) when is_binary(doc_id) do
    GenServer.call(server, {:get_document, doc_id}, 5_000)
  catch
    :exit, reason -> {:error, {:timeout_or_down, reason}}
  end

  @doc """
  Fetch documents for a session.

  ## Options

  - `:limit` — maximum documents to return (default: 20)
  - `:since_ms` — only documents whose `ingested_at_ms` is strictly greater
    than this watermark. Changes the ordering to **oldest-first**, so a caller
    threading the newest returned `ingested_at_ms` back as the next `since_ms`
    drains a backlog window by window without skipping anything.

  Without `:since_ms` the newest `limit` documents are returned, newest-first.
  """
  @spec get_by_session(binary(), keyword()) :: [Document.t()]
  def get_by_session(session_key, opts \\ []) when is_binary(session_key) do
    get_by_session(__MODULE__, session_key, opts)
  end

  @spec get_by_session(GenServer.server(), binary(), keyword()) :: [Document.t()]
  def get_by_session(server, session_key, opts) when is_binary(session_key) do
    GenServer.call(server, {:get_by_session, session_key, query_opts(opts)}, 5_000)
  catch
    :exit, _ -> []
  end

  @doc """
  Fetch documents for an agent across all sessions.

  Takes the same options as `get_by_session/2`.
  """
  @spec get_by_agent(binary(), keyword()) :: [Document.t()]
  def get_by_agent(agent_id, opts \\ []) when is_binary(agent_id) do
    get_by_agent(__MODULE__, agent_id, opts)
  end

  @spec get_by_agent(GenServer.server(), binary(), keyword()) :: [Document.t()]
  def get_by_agent(server, agent_id, opts) when is_binary(agent_id) do
    GenServer.call(server, {:get_by_agent, agent_id, query_opts(opts)}, 5_000)
  catch
    :exit, _ -> []
  end

  @doc """
  Fetch documents for a workspace.

  Takes the same options as `get_by_session/2`.
  """
  @spec get_by_workspace(binary(), keyword()) :: [Document.t()]
  def get_by_workspace(workspace_key, opts \\ []) when is_binary(workspace_key) do
    get_by_workspace(__MODULE__, workspace_key, opts)
  end

  @spec get_by_workspace(GenServer.server(), binary(), keyword()) :: [Document.t()]
  def get_by_workspace(server, workspace_key, opts) when is_binary(workspace_key) do
    GenServer.call(server, {:get_by_workspace, workspace_key, query_opts(opts)}, 5_000)
  catch
    :exit, _ -> []
  end

  @doc """
  Fetch the newest memory documents across scopes.

  This deliberately exposes only a bounded recent window. Operator-facing
  filtering, redaction, and deletion belong in `LemonMemory.Lifecycle` rather
  than in callers that might otherwise grow a second memory read model.
  """
  @spec list_recent(keyword()) :: {:ok, [Document.t()]} | {:error, term()}
  def list_recent(opts \\ []), do: list_recent(__MODULE__, opts)

  @spec list_recent(GenServer.server(), keyword()) ::
          {:ok, [Document.t()]} | {:error, term()}
  def list_recent(server, opts) when is_list(opts) do
    limit = opts |> Keyword.get(:limit, 20) |> clamp_limit(500)
    GenServer.call(server, {:list_recent, limit}, 5_000)
  catch
    :exit, reason -> {:error, {:timeout_or_down, reason}}
  end

  @doc "Fetch a bounded agent window without hiding store failures as empty memory."
  @spec list_agent_recent(GenServer.server(), binary(), keyword()) ::
          {:ok, [Document.t()]} | {:error, term()}
  def list_agent_recent(server, agent_id, opts \\ []) when is_binary(agent_id) do
    limit = opts |> Keyword.get(:limit, 200) |> clamp_limit(500)
    GenServer.call(server, {:list_agent_recent, agent_id, limit}, 5_000)
  catch
    :exit, reason -> {:error, {:timeout_or_down, reason}}
  end

  @doc "Apply exact persisted ownership before a bounded result limit."
  def list_owned_recent(server, agent, home, selector, opts \\ []) do
    with {:ok, mode, key} <- owner_query(selector) do
      limit = opts |> Keyword.get(:limit, 200) |> clamp_limit(500)
      preferences = if Keyword.get(opts, :preferences_only, false), do: 1, else: 0
      GenServer.call(server, {:owned_recent, [agent, home, mode, key, preferences, limit]}, 5_000)
    end
  catch
    :exit, reason -> {:error, {:timeout_or_down, reason}}
  end

  @doc "Search exact ownership before the limit; history-only by default."
  def search_owned(server, query, agent, home, selector, opts \\ []) do
    with {:ok, mode, key} <- owner_query(selector) do
      case Query.fts_match(query) do
        nil ->
          {:ok, []}

        match ->
          limit = opts |> Keyword.get(:limit, 50) |> clamp_limit(500)
          root = Keyword.get(opts, :workspace_root)
          history = if Keyword.get(opts, :history_only, true), do: 1, else: 0

          GenServer.call(
            server,
            {:owned_search, [match, agent, home, mode, key, root, history, limit]},
            5_000
          )
      end
    end
  catch
    :exit, reason -> {:error, {:timeout_or_down, reason}}
  end

  @doc "Read scoped history windows or session representatives, filtering before ranking."
  def history_window(server, agent, home, selector, opts) do
    with {:ok, mode, key} <- owner_query(selector) do
      GenServer.call(
        server,
        {:history_window,
         [
           agent,
           home,
           mode,
           key,
           Keyword.get(opts, :session),
           Keyword.get(opts, :around),
           Keyword.get(opts, :limit, 5),
           Keyword.get(opts, :workspace_root)
         ]},
        5_000
      )
    end
  catch
    :exit, reason -> {:error, {:timeout_or_down, reason}}
  end

  @doc "Exact-ID read bound to indexed profile and private/shared ownership."
  def get_owned_document(server, id, agent, home, selector) do
    with {:ok, mode, key} <- owner_query(selector) do
      GenServer.call(server, {:owned_document, [id, agent, home, mode, key]}, 5_000)
    end
  catch
    :exit, reason -> {:error, {:timeout_or_down, reason}}
  end

  @doc "Authoritative persisted ownership for lifecycle/transfer, without Store IO."
  def document_ownership(%Document{} = doc), do: ContextScope.indexed_owner(doc.meta, doc.index)

  defp owner_query({:private, key}) do
    if ContextScope.valid_key?(key),
      do: {:ok, "private", key},
      else: {:error, :invalid_memory_scope}
  end

  defp owner_query(:shared), do: {:ok, "shared", nil}
  defp owner_query(:legacy), do: {:ok, "legacy", nil}
  defp owner_query(_), do: {:error, :invalid_memory_scope}

  @doc "Read an exact profile/home snapshot inside the Store serialization boundary."
  def transfer_snapshot(server, agent_id, home_digest, fun) do
    transfer_call(server, {:transfer_snapshot, agent_id, home_digest, fun})
  end

  @doc "Read a private transfer journal entry. Never exposes content in management events."
  def transfer_get(server, key), do: transfer_call(server, {:transfer_get, key})

  @doc "Durably create a private transfer journal entry without replacing an operation."
  def transfer_put_new(server, key, value),
    do: transfer_call(server, {:transfer_put_new, key, value})

  @doc """
  Replace exact selected profile rows and commit their receipt in one transaction.
  Local `:boundary` and `:rollback` callbacks run on the Store process; the
  boundary owns filesystem locks across publication, commit and known rollback.
  A failed/uncertain commit leaves the prior durable intent pending, never replayed.
  """
  def transfer_import(server, agent, home, revisions, docs, key, receipt, publish, opts \\ []) do
    GenServer.call(
      server,
      {:transfer_import, agent, home, revisions, docs, key, receipt, publish, opts},
      :infinity
    )
  catch
    :exit, _ -> {:error, :transfer_pending}
  end

  defp transfer_call(server, message) do
    GenServer.call(server, message, :infinity)
  catch
    :exit, _ -> {:error, :memory_unavailable}
  end

  defp query_opts(opts) do
    since_ms =
      case Keyword.get(opts, :since_ms) do
        value when is_integer(value) -> value
        _ -> nil
      end

    %{limit: Keyword.get(opts, :limit, 20), since_ms: since_ms}
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

  @doc "Synchronously delete one exact memory document and its FTS row."
  @spec delete_document(binary()) :: {:ok, :deleted | :not_found} | {:error, term()}
  def delete_document(doc_id) when is_binary(doc_id), do: delete_document(__MODULE__, doc_id)

  @spec delete_document(GenServer.server(), binary()) ::
          {:ok, :deleted | :not_found} | {:error, term()}
  def delete_document(server, doc_id) when is_binary(doc_id) do
    GenServer.call(server, {:delete_document, doc_id}, 5_000)
  catch
    :exit, reason -> {:error, {:timeout_or_down, reason}}
  end

  @doc """
  Atomically delete one document only when it still equals a previously read
  snapshot.

  The comparison and deletion execute in one Store callback, so a concurrent
  write observed before this call makes the operation fail stale instead of
  deleting changed content. This is the low-level primitive used by guarded
  lifecycle deletion; ordinary callers should prefer `LemonMemory.Lifecycle`.
  """
  @spec delete_document_if_unchanged(binary(), binary()) ::
          {:ok, :deleted | :not_found | :stale} | {:error, term()}
  def delete_document_if_unchanged(doc_id, revision),
    do: delete_document_if_unchanged(__MODULE__, doc_id, revision)

  @spec delete_document_if_unchanged(GenServer.server(), binary(), binary()) ::
          {:ok, :deleted | :not_found | :stale} | {:error, term()}
  def delete_document_if_unchanged(server, doc_id, revision)
      when is_binary(doc_id) and is_binary(revision) do
    GenServer.call(server, {:delete_document_if_unchanged, doc_id, revision}, 5_000)
  catch
    :exit, reason -> {:error, {:timeout_or_down, reason}}
  end

  @doc "Deterministic SHA-256 revision over every persisted document field."
  @spec document_revision(Document.t()) :: binary()
  def document_revision(%Document{} = doc) do
    [
      doc.doc_id,
      doc.run_id,
      doc.session_key,
      doc.agent_id,
      doc.workspace_key,
      doc.scope,
      doc.started_at_ms,
      doc.ingested_at_ms,
      doc.prompt_summary,
      doc.answer_summary,
      doc.tools_used,
      doc.provider,
      doc.model,
      doc.outcome,
      doc.meta,
      doc.index || ContextScope.index_fields(doc.meta, doc.workspace_key)
    ]
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
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
  The SQLite file the default store opens from application config
  (`config :lemon_memory, LemonMemory.Store, path: ...`), without starting it.
  """
  @spec database_path() :: Path.t()
  def database_path, do: resolve_path(Application.get_env(:lemon_memory, __MODULE__, []))

  @doc """
  Full-text search over `prompt_summary` and `answer_summary`.

  Any query term may match (see `LemonMemory.Query`); results are ordered by
  BM25 relevance, best first.

  ## Options

  - `:scope` - `:session` (default), `:agent`, `:workspace`, `:all`
  - `:scope_key` - session_key / agent_id / workspace_key (required if scope != `:all`)
  - `:limit` - max results (default 5)
  """
  @spec search(binary(), keyword()) :: [Document.t()]
  def search(query, opts \\ []) when is_binary(query) do
    search(__MODULE__, query, opts)
  end

  @spec search(GenServer.server(), binary(), keyword()) :: [Document.t()]
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
    unless Code.ensure_loaded?(Sqlite3) do
      raise "#{inspect(__MODULE__)} requires the optional :exqlite dependency. " <>
              ~s(Add {:exqlite, "~> 0.34"} to your deps.)
    end

    app_config = Application.get_env(:lemon_memory, __MODULE__, [])
    # opts passed to start_link take precedence over application env
    config = Keyword.merge(app_config, Keyword.drop(opts, [:name]))

    path = resolve_path(config)
    retention_ms = Keyword.get(config, :retention_ms, @default_retention_ms)
    max_per_scope = Keyword.get(config, :max_per_scope, @default_max_per_scope)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, conn} <- Sqlite3.open(path),
         :ok <- File.chmod(path, 0o600),
         :ok <- init_db(conn),
         :ok <- private_database_sidecars(path),
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
        Logger.error("[Store] init failed: #{inspect(reason)}")
        {:stop, {:init_failed, reason}}
    end
  end

  @impl true
  def handle_cast({:put, doc}, state) do
    case do_put(state, doc) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[Store] put failed doc_id=#{doc.doc_id}: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_cast({:delete_by_session, session_key}, state) do
    run_delete(
      state.conn,
      state.stmts.fts_delete_by_session,
      [session_key],
      "fts_delete_by_session"
    )

    run_delete(state.conn, state.stmts.delete_by_session, [session_key], "delete_by_session")
    {:noreply, state}
  end

  def handle_cast({:delete_by_agent, agent_id}, state) do
    run_delete(state.conn, state.stmts.fts_delete_by_agent, [agent_id], "fts_delete_by_agent")
    run_delete(state.conn, state.stmts.delete_by_agent, [agent_id], "delete_by_agent")
    {:noreply, state}
  end

  def handle_cast({:delete_by_workspace, workspace_key}, state) do
    run_delete(
      state.conn,
      state.stmts.fts_delete_by_workspace,
      [workspace_key],
      "fts_delete_by_workspace"
    )

    run_delete(
      state.conn,
      state.stmts.delete_by_workspace,
      [workspace_key],
      "delete_by_workspace"
    )

    {:noreply, state}
  end

  def handle_call({:owned_recent, params}, _from, state),
    do: {:reply, do_query_result(state, state.stmts.owned_recent, params), state}

  def handle_call({:owned_search, params}, _from, state),
    do: {:reply, do_query_result(state, state.stmts.owned_search, params), state}

  def handle_call({:history_window, params}, _from, state) do
    sql = """
    WITH eligible AS (
      SELECT *, ROW_NUMBER() OVER (
        PARTITION BY session_key ORDER BY COALESCE(started_at_ms, ingested_at_ms), doc_id
      ) AS position,
      COUNT(*) OVER (PARTITION BY session_key) AS run_count,
      MAX(ingested_at_ms) OVER (PARTITION BY session_key) AS latest
      FROM memory_documents
      WHERE agent_id = ?1 AND home_digest = ?2
        AND (memory_scope = ?3 OR (?3 = 'legacy' AND memory_scope IS NULL))
        AND (memory_context_key = ?4 OR (?4 IS NULL AND memory_context_key IS NULL))
        AND COALESCE(memory_kind, 'run') NOT IN ('user', 'memory', 'project_learning')
        AND (?5 IS NULL OR session_key = ?5)
        AND (?8 IS NULL OR repository_root = ?8)
    ), selected AS (
      SELECT * FROM eligible
      WHERE (?5 IS NULL AND position = 1)
         OR (?5 IS NOT NULL AND ?6 IS NULL)
         OR (?5 IS NOT NULL AND position >= MAX(1,
           (SELECT position FROM eligible WHERE doc_id = ?6 OR run_id = ?6 LIMIT 1)
           - CAST((?7 - 1) / 2 AS INTEGER)))
      ORDER BY CASE WHEN ?5 IS NULL THEN latest END DESC,
               CASE WHEN ?6 IS NULL THEN position END DESC,
               position ASC, doc_id
      LIMIT ?7
    )
    SELECT doc_id, run_id, session_key, agent_id, workspace_key, scope,
           started_at_ms, CASE WHEN ?5 IS NULL THEN latest ELSE ingested_at_ms END,
           prompt_summary, answer_summary,
           tools_used_blob, provider, model, outcome, meta_blob,
           memory_scope, memory_context_key, home_digest, memory_kind, repository_root,
           run_count
    FROM selected
    """

    result =
      with {:ok, stmt} <- Sqlite3.prepare(state.conn, sql) do
        try do
          with :ok <- Sqlite3.bind(stmt, params),
               {:ok, rows} <- Sqlite3.fetch_all(state.conn, stmt) do
            Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
              case decode_row(Enum.drop(row, -1)) do
                {:ok, doc} -> {:cont, {:ok, [{doc, List.last(row)} | acc]}}
                error -> {:halt, error}
              end
            end)
          end
        after
          Sqlite3.release(state.conn, stmt)
        end
      end

    {:reply, result, state}
  end

  def handle_call({:owned_document, params}, _from, state) do
    result =
      case do_query_result(state, state.stmts.get_owned_document, params) do
        {:ok, [doc]} -> {:ok, doc}
        {:ok, []} -> {:error, :not_found}
        error -> error
      end

    {:reply, result, state}
  end

  def handle_call({:transfer_get, key}, _from, state),
    do: {:reply, transfer_journal_get(state, key), state}

  def handle_call({:transfer_put_new, key, value}, _from, state) do
    result =
      with :ok <-
             transfer_statement(
               state,
               "INSERT INTO memory_transfer_journal (operation_key, payload) VALUES (?1, ?2) ON CONFLICT(operation_key) DO NOTHING",
               [key, Jason.encode!(value)]
             ),
           {:ok, current} <- transfer_journal_get(state, key),
           do: {:ok, current}

    {:reply, result, state}
  end

  def handle_call({:transfer_snapshot, agent, home, fun}, _from, state) do
    result =
      transfer_transaction(state, fn ->
        with {:ok, docs} <- transfer_documents(state, agent, home), do: fun.(docs)
      end)

    {:reply, result, state}
  end

  def handle_call(
        {:transfer_import, agent, home, revisions, docs, key, receipt, publish, opts},
        _from,
        state
      ) do
    boundary = Keyword.get(opts, :boundary, fn run -> run.() end)
    rollback = Keyword.get(opts, :rollback, fn -> :ok end)

    result =
      boundary.(fn ->
        result =
          transfer_transaction(state, fn ->
            with :ok <- transfer_import_boundary(state, agent, home, docs, key, receipt),
                 {:ok, current} <- transfer_documents(state, agent, home),
                 true <- transfer_revisions(current) == revisions,
                 :ok <- transfer_delete_rows(state, current),
                 :ok <- transfer_insert_rows(state, docs),
                 :ok <- publish.(),
                 :ok <-
                   transfer_statement(
                     state,
                     "UPDATE memory_transfer_journal SET payload = ?2 WHERE operation_key = ?1",
                     [key, Jason.encode!(receipt)]
                   ) do
              {:ok, receipt}
            else
              false -> {:error, :stale_destination}
              {:error, _} = error -> error
              _ -> {:error, :memory_unavailable}
            end
          end)

        case result do
          {:ok, _} ->
            result

          {:error, :transfer_pending} ->
            result

          _ ->
            case rollback.() do
              :ok -> result
              _ -> {:error, :transfer_pending}
            end
        end
      end)

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_by_session, session_key, opts}, _from, state) do
    result = do_scoped_query(state, :get_by_session, session_key, opts)
    {:reply, result, state}
  end

  def handle_call({:put_sync, doc}, _from, state) do
    {:reply, do_put(state, doc), state}
  end

  def handle_call({:put_if_unchanged, doc, revision}, _from, state) do
    result =
      with {:ok, current} <- fetch_document(state, doc.doc_id),
           true <- secure_equal?(document_revision(current), revision) do
        do_put(state, doc)
      else
        false -> {:error, :stale}
        error -> error
      end

    {:reply, result, state}
  end

  def handle_call({:put_new_sync, doc}, _from, state) do
    {:reply, do_put_new(state, doc), state}
  end

  def handle_call({:get_document, doc_id}, _from, state) do
    {:reply, fetch_document(state, doc_id), state}
  end

  def handle_call({:delete_document, doc_id}, _from, state) do
    {:reply, do_delete_document(state, doc_id), state}
  end

  def handle_call({:get_by_agent, agent_id, opts}, _from, state) do
    result = do_scoped_query(state, :get_by_agent, agent_id, opts)
    {:reply, result, state}
  end

  def handle_call({:get_by_workspace, workspace_key, opts}, _from, state) do
    result = do_scoped_query(state, :get_by_workspace, workspace_key, opts)
    {:reply, result, state}
  end

  def handle_call({:list_recent, limit}, _from, state) do
    {:reply, do_query_result(state, state.stmts.list_recent, [limit]), state}
  end

  def handle_call({:list_agent_recent, agent_id, limit}, _from, state) do
    {:reply, do_query_result(state, state.stmts.get_by_agent, [agent_id, limit]), state}
  end

  def handle_call({:delete_document_if_unchanged, doc_id, revision}, _from, state) do
    {:reply, do_delete_document_if_unchanged(state, doc_id, revision), state}
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
          Logger.warning("[Store] stats failed: #{inspect(err)}")
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
    _ = Sqlite3.close(state.conn)
    :ok
  rescue
    _ -> :ok
  end

  # ── Private helpers ────────────────────────────────────────────────────────────
  defp transfer_documents(state, agent, home) do
    with {:ok, docs} <- do_query_result(state, state.stmts.get_by_agent, [agent, 2001]),
         true <- length(docs) <= 2000 do
      selected =
        Enum.filter(docs, fn doc ->
          is_map(doc.meta) and (doc.meta["home_digest"] || doc.meta[:home_digest]) == home
        end)

      if length(selected) <= 500, do: {:ok, selected}, else: {:error, :snapshot_too_large}
    else
      false -> {:error, :snapshot_too_large}
      error -> error
    end
  end

  def transfer_revisions(docs),
    do: docs |> Enum.map(&{&1.doc_id, document_revision(&1)}) |> Enum.sort()

  defp transfer_import_boundary(state, agent, home, docs, key, completed) do
    with {:ok, %{"binding" => binding, "state" => "pending"}} <- transfer_journal_get(state, key),
         true <- binding == completed["binding"] and binding["profileId"] == agent,
         true <-
           completed["state"] == "complete" and
             completed["receipt"] == Map.put(binding, "copied", true),
         true <-
           length(docs) <= 500 and
             Enum.all?(docs, fn
               %Document{agent_id: ^agent, meta: meta} when is_map(meta) ->
                 meta["home_digest"] == home

               _ ->
                 false
             end) do
      :ok
    else
      {:error, :not_found} -> {:error, :transfer_conflict}
      {:error, _} = error -> error
      _ -> {:error, :transfer_conflict}
    end
  end

  defp transfer_journal_get(state, key) do
    with {:ok, stmt} <-
           Sqlite3.prepare(
             state.conn,
             "SELECT payload FROM memory_transfer_journal WHERE operation_key = ?1"
           ) do
      try do
        with :ok <- Sqlite3.bind(stmt, [key]),
             {:ok, rows} <- Sqlite3.fetch_all(state.conn, stmt) do
          case rows do
            [[json]] -> Jason.decode(json)
            [] -> {:error, :not_found}
            _ -> {:error, :memory_unavailable}
          end
        end
      after
        Sqlite3.release(state.conn, stmt)
      end
    end
  end

  defp transfer_statement(state, sql, params) do
    with {:ok, stmt} <- Sqlite3.prepare(state.conn, sql) do
      try do
        with :ok <- Sqlite3.bind(stmt, params), :done <- Sqlite3.step(state.conn, stmt), do: :ok
      after
        Sqlite3.release(state.conn, stmt)
      end
    end
  end

  defp transfer_transaction(state, fun) do
    with :ok <- Sqlite3.execute(state.conn, "BEGIN IMMEDIATE") do
      result = fun.()

      case result do
        {:ok, _} ->
          case Sqlite3.execute(state.conn, "COMMIT") do
            :ok ->
              result

            _ ->
              _ = Sqlite3.execute(state.conn, "ROLLBACK")
              {:error, :transfer_pending}
          end

        _ ->
          case Sqlite3.execute(state.conn, "ROLLBACK") do
            :ok -> result
            _ -> {:error, :transfer_pending}
          end
      end
    end
  rescue
    _ ->
      case Sqlite3.execute(state.conn, "ROLLBACK") do
        :ok -> {:error, :memory_unavailable}
        _ -> {:error, :transfer_pending}
      end
  end

  defp transfer_delete_rows(state, docs) do
    Enum.reduce_while(docs, :ok, fn doc, :ok ->
      case delete_document_in_transaction(state, doc.doc_id) do
        {:ok, :deleted} -> {:cont, :ok}
        _ -> {:halt, {:error, :memory_unavailable}}
      end
    end)
  end

  defp transfer_insert_rows(state, docs) do
    Enum.reduce_while(docs, :ok, fn doc, :ok ->
      with {:error, :not_found} <- fetch_document(state, doc.doc_id),
           :ok <- Sqlite3.reset(state.stmts.put_new),
           :ok <- Sqlite3.bind(state.stmts.put_new, document_params(doc)),
           :done <- Sqlite3.step(state.conn, state.stmts.put_new),
           :ok <- Sqlite3.reset(state.stmts.fts_put),
           :ok <-
             Sqlite3.bind(state.stmts.fts_put, [
               doc.doc_id,
               doc.prompt_summary,
               doc.answer_summary
             ]),
           :done <- Sqlite3.step(state.conn, state.stmts.fts_put) do
        {:cont, :ok}
      else
        {:ok, _} -> {:halt, {:error, :destination_conflict}}
        _ -> {:halt, {:error, :memory_unavailable}}
      end
    end)
  end

  defp do_scoped_query(state, stmt_key, scope_key, %{limit: limit, since_ms: nil}) do
    do_query(state, Map.fetch!(state.stmts, stmt_key), [scope_key, limit])
  end

  defp do_scoped_query(state, stmt_key, scope_key, %{limit: limit, since_ms: since_ms}) do
    stmt = Map.fetch!(state.stmts, :"#{stmt_key}_since")
    do_query(state, stmt, [scope_key, since_ms, limit])
  end

  defp private_database_sidecars(path) do
    Enum.reduce_while(["-wal", "-shm"], :ok, fn suffix, :ok ->
      case File.chmod(path <> suffix, 0o600) do
        :ok -> {:cont, :ok}
        {:error, :enoent} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # Unconfigured, memory lands next to the main store's data so a deployment
  # that points the store at a directory gets its memory database there too.
  defp resolve_path(config) do
    raw =
      Keyword.get(config, :path) ||
        Application.get_env(:lemon_core, LemonCore.Store, [])
        |> Keyword.get(:backend_opts, [])
        |> Keyword.get(:path, "~/.lemon/store")

    dir = LemonCore.Paths.store_dir(raw)
    Path.join(dir, @filename)
  end

  defp init_db(conn) do
    with :ok <- Sqlite3.execute(conn, "PRAGMA journal_mode=WAL"),
         :ok <- Sqlite3.execute(conn, "PRAGMA synchronous=NORMAL"),
         :ok <- Sqlite3.execute(conn, "PRAGMA temp_store=MEMORY"),
         :ok <- Sqlite3.execute(conn, "PRAGMA busy_timeout=5000"),
         :ok <- Sqlite3.execute(conn, @schema_sql),
         :ok <- migrate_ownership_columns(conn),
         :ok <-
           Sqlite3.execute(
             conn,
             "CREATE TABLE IF NOT EXISTS memory_transfer_journal (operation_key TEXT PRIMARY KEY, payload TEXT NOT NULL)"
           ),
         :ok <- Sqlite3.execute(conn, @fts_schema_sql) do
      Enum.reduce_while(@index_sqls, :ok, fn sql, :ok ->
        case Sqlite3.execute(conn, sql) do
          :ok -> {:cont, :ok}
          err -> {:halt, err}
        end
      end)
    end
  end

  # Adding nullable columns does not attest, rewrite, or reindex retained rows.
  defp migrate_ownership_columns(conn) do
    with {:ok, stmt} <- Sqlite3.prepare(conn, "PRAGMA table_info(memory_documents)") do
      try do
        with {:ok, rows} <- Sqlite3.fetch_all(conn, stmt) do
          names = Enum.map(rows, &Enum.at(&1, 1))

          Enum.reduce_while(
            ~w(memory_scope memory_context_key home_digest memory_kind repository_root),
            :ok,
            fn name, :ok ->
              result =
                if name in names,
                  do: :ok,
                  else:
                    Sqlite3.execute(conn, "ALTER TABLE memory_documents ADD COLUMN #{name} TEXT")

              case result do
                :ok -> {:cont, :ok}
                error -> {:halt, error}
              end
            end
          )
        end
      after
        Sqlite3.release(conn, stmt)
      end
    end
  end

  defp prepare_statements(conn) do
    with {:ok, put} <- Sqlite3.prepare(conn, @put_sql),
         {:ok, put_new} <- Sqlite3.prepare(conn, @put_new_sql),
         {:ok, get_document} <- Sqlite3.prepare(conn, @get_document_sql),
         {:ok, get_owned_document} <- Sqlite3.prepare(conn, @get_owned_document_sql),
         {:ok, get_by_session} <- Sqlite3.prepare(conn, @get_by_session_sql),
         {:ok, get_by_agent} <- Sqlite3.prepare(conn, @get_by_agent_sql),
         {:ok, owned_recent} <- Sqlite3.prepare(conn, @owned_recent_sql),
         {:ok, owned_search} <- Sqlite3.prepare(conn, @owned_search_sql),
         {:ok, get_by_workspace} <- Sqlite3.prepare(conn, @get_by_workspace_sql),
         {:ok, get_by_session_since} <- Sqlite3.prepare(conn, @get_by_session_since_sql),
         {:ok, get_by_agent_since} <- Sqlite3.prepare(conn, @get_by_agent_since_sql),
         {:ok, get_by_workspace_since} <- Sqlite3.prepare(conn, @get_by_workspace_since_sql),
         {:ok, list_recent} <- Sqlite3.prepare(conn, @list_recent_sql),
         {:ok, delete_by_session} <- Sqlite3.prepare(conn, @delete_by_session_sql),
         {:ok, delete_by_agent} <- Sqlite3.prepare(conn, @delete_by_agent_sql),
         {:ok, delete_by_workspace} <- Sqlite3.prepare(conn, @delete_by_workspace_sql),
         {:ok, delete_document} <- Sqlite3.prepare(conn, @delete_document_sql),
         {:ok, sweep} <- Sqlite3.prepare(conn, @sweep_sql),
         {:ok, stats} <- Sqlite3.prepare(conn, @stats_sql),
         {:ok, fts_put} <- Sqlite3.prepare(conn, @fts_put_sql),
         {:ok, fts_delete_by_session} <- Sqlite3.prepare(conn, @fts_delete_by_session_sql),
         {:ok, fts_delete_by_agent} <- Sqlite3.prepare(conn, @fts_delete_by_agent_sql),
         {:ok, fts_delete_by_workspace} <- Sqlite3.prepare(conn, @fts_delete_by_workspace_sql),
         {:ok, fts_delete_document} <- Sqlite3.prepare(conn, @fts_delete_document_sql),
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
         put_new: put_new,
         get_document: get_document,
         get_owned_document: get_owned_document,
         get_by_session: get_by_session,
         get_by_agent: get_by_agent,
         owned_recent: owned_recent,
         owned_search: owned_search,
         get_by_workspace: get_by_workspace,
         get_by_session_since: get_by_session_since,
         get_by_agent_since: get_by_agent_since,
         get_by_workspace_since: get_by_workspace_since,
         list_recent: list_recent,
         delete_by_session: delete_by_session,
         delete_by_agent: delete_by_agent,
         delete_by_workspace: delete_by_workspace,
         delete_document: delete_document,
         sweep: sweep,
         stats: stats,
         fts_put: fts_put,
         fts_delete_by_session: fts_delete_by_session,
         fts_delete_by_agent: fts_delete_by_agent,
         fts_delete_by_workspace: fts_delete_by_workspace,
         fts_delete_document: fts_delete_document,
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

  defp do_put(state, %Document{} = doc) do
    params = document_params(doc)

    :ok = Sqlite3.execute(state.conn, "BEGIN")

    with :ok <- Sqlite3.reset(state.stmts.put),
         :ok <- Sqlite3.bind(state.stmts.put, params),
         :done <- Sqlite3.step(state.conn, state.stmts.put),
         :ok <- Sqlite3.reset(state.stmts.fts_delete_document),
         :ok <- Sqlite3.bind(state.stmts.fts_delete_document, [doc.doc_id]),
         :done <- Sqlite3.step(state.conn, state.stmts.fts_delete_document),
         :ok <- Sqlite3.reset(state.stmts.fts_put),
         :ok <-
           Sqlite3.bind(state.stmts.fts_put, [doc.doc_id, doc.prompt_summary, doc.answer_summary]),
         :done <- Sqlite3.step(state.conn, state.stmts.fts_put) do
      :ok = Sqlite3.execute(state.conn, "COMMIT")
      :ok
    else
      err ->
        _ = Sqlite3.execute(state.conn, "ROLLBACK")

        case err do
          :busy -> {:error, :sqlite_busy}
          {:error, reason} -> {:error, reason}
          other -> {:error, {:put_failed, other}}
        end
    end
  rescue
    e ->
      _ = Sqlite3.execute(state.conn, "ROLLBACK")
      {:error, {:exception, Exception.message(e)}}
  end

  defp do_put_new(state, %Document{} = doc) do
    params = document_params(doc)
    :ok = Sqlite3.execute(state.conn, "BEGIN")

    with :ok <- Sqlite3.reset(state.stmts.put_new),
         :ok <- Sqlite3.bind(state.stmts.put_new, params),
         :done <- Sqlite3.step(state.conn, state.stmts.put_new) do
      case Sqlite3.changes(state.conn) do
        {:ok, 0} ->
          :ok = Sqlite3.execute(state.conn, "ROLLBACK")
          {:ok, :exists}

        {:ok, _} ->
          with :ok <- Sqlite3.reset(state.stmts.fts_put),
               :ok <-
                 Sqlite3.bind(state.stmts.fts_put, [
                   doc.doc_id,
                   doc.prompt_summary,
                   doc.answer_summary
                 ]),
               :done <- Sqlite3.step(state.conn, state.stmts.fts_put) do
            :ok = Sqlite3.execute(state.conn, "COMMIT")
            {:ok, :created}
          else
            error ->
              _ = Sqlite3.execute(state.conn, "ROLLBACK")
              {:error, error}
          end

        error ->
          _ = Sqlite3.execute(state.conn, "ROLLBACK")
          {:error, error}
      end
    else
      error ->
        _ = Sqlite3.execute(state.conn, "ROLLBACK")
        {:error, error}
    end
  rescue
    error ->
      _ = Sqlite3.execute(state.conn, "ROLLBACK")
      {:error, {:exception, Exception.message(error)}}
  end

  defp document_params(doc) do
    [
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
      {:blob, encode(doc.tools_used)},
      doc.provider,
      doc.model,
      Atom.to_string(doc.outcome),
      {:blob, encode(doc.meta)}
    ] ++ Tuple.to_list(ContextScope.index_fields(doc.meta, doc.workspace_key))
  end

  defp do_delete_document(state, doc_id) do
    :ok = Sqlite3.execute(state.conn, "BEGIN")

    with :ok <- Sqlite3.reset(state.stmts.fts_delete_document),
         :ok <- Sqlite3.bind(state.stmts.fts_delete_document, [doc_id]),
         :done <- Sqlite3.step(state.conn, state.stmts.fts_delete_document),
         :ok <- Sqlite3.reset(state.stmts.delete_document),
         :ok <- Sqlite3.bind(state.stmts.delete_document, [doc_id]),
         :done <- Sqlite3.step(state.conn, state.stmts.delete_document) do
      result =
        case Sqlite3.changes(state.conn) do
          {:ok, 0} -> :not_found
          {:ok, _} -> :deleted
          _ -> :deleted
        end

      :ok = Sqlite3.execute(state.conn, "COMMIT")
      {:ok, result}
    else
      error ->
        _ = Sqlite3.execute(state.conn, "ROLLBACK")
        {:error, error}
    end
  rescue
    error ->
      _ = Sqlite3.execute(state.conn, "ROLLBACK")
      {:error, {:exception, Exception.message(error)}}
  end

  defp do_delete_document_if_unchanged(state, doc_id, expected_revision) do
    :ok = Sqlite3.execute(state.conn, "BEGIN IMMEDIATE")

    result =
      case fetch_document(state, doc_id) do
        {:error, :not_found} ->
          {:ok, :not_found}

        {:error, reason} ->
          {:error, reason}

        {:ok, current} ->
          current_revision = document_revision(current)

          if secure_equal?(current_revision, expected_revision) do
            delete_document_in_transaction(state, doc_id)
          else
            {:ok, :stale}
          end
      end

    case result do
      {:ok, :deleted} ->
        :ok = Sqlite3.execute(state.conn, "COMMIT")
        result

      _ ->
        _ = Sqlite3.execute(state.conn, "ROLLBACK")
        result
    end
  rescue
    error ->
      _ = Sqlite3.execute(state.conn, "ROLLBACK")
      {:error, {:exception, Exception.message(error)}}
  end

  defp delete_document_in_transaction(state, doc_id) do
    with :ok <- Sqlite3.reset(state.stmts.fts_delete_document),
         :ok <- Sqlite3.bind(state.stmts.fts_delete_document, [doc_id]),
         :done <- Sqlite3.step(state.conn, state.stmts.fts_delete_document),
         :ok <- Sqlite3.reset(state.stmts.delete_document),
         :ok <- Sqlite3.bind(state.stmts.delete_document, [doc_id]),
         :done <- Sqlite3.step(state.conn, state.stmts.delete_document) do
      case Sqlite3.changes(state.conn) do
        {:ok, 0} -> {:ok, :not_found}
        {:ok, _} -> {:ok, :deleted}
        error -> {:error, error}
      end
    end
  end

  defp fetch_document(state, doc_id) do
    case do_query_result(state, state.stmts.get_document, [doc_id]) do
      {:ok, [doc]} -> {:ok, doc}
      {:ok, []} -> {:error, :not_found}
      {:ok, _multiple} -> {:error, :ambiguous_document}
      {:error, _} = error -> error
    end
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
        Logger.warning("[Store] query failed: #{inspect(err)}")
        []
    end
  end

  defp do_query_result(state, stmt, params) do
    with :ok <- Sqlite3.reset(stmt),
         :ok <- Sqlite3.bind(stmt, params),
         {:ok, rows} <- Sqlite3.fetch_all(state.conn, stmt) do
      Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, documents} ->
        case decode_row(row) do
          {:ok, doc} -> {:cont, {:ok, [doc | documents]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, documents} -> {:ok, Enum.reverse(documents)}
        {:error, _} = error -> error
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_row([
         doc_id,
         run_id,
         session_key,
         agent_id,
         workspace_key,
         scope,
         started_at_ms,
         ingested_at_ms,
         prompt_summary,
         answer_summary,
         tools_used_blob,
         provider,
         model,
         outcome,
         meta_blob,
         memory_scope,
         memory_context_key,
         home_digest,
         memory_kind,
         repository_root
       ]) do
    with {:ok, tools_used} <- decode(tools_used_blob),
         {:ok, meta} <- decode(meta_blob) do
      doc = %Document{
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
        meta: meta,
        index: {memory_scope, memory_context_key, home_digest, memory_kind, repository_root}
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
      err -> Logger.warning("[Store] #{op} failed: #{inspect(err)}")
    end
  rescue
    e -> Logger.warning("[Store] #{op} exception: #{Exception.message(e)}")
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
        err -> Logger.warning("[Store] fts sweep failed: #{inspect(err)}")
      end

      n
    else
      err ->
        Logger.warning("[Store] retention sweep in prune failed: #{inspect(err)}")
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
            Logger.warning("[Store] fts prune failed for '#{session_key}': #{inspect(err)}")
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
      err -> Logger.warning("[Store] sweep failed: #{inspect(err)}")
    end
  end

  defp do_search(state, query, scope, scope_key, limit) do
    safe_query = Query.fts_match(query)

    cond do
      # A query made only of stopwords has nothing to match; an empty MATCH
      # expression is an FTS5 syntax error, not an empty result.
      is_nil(safe_query) ->
        []

      # Scoped searches with a nil scope_key must NOT fall back to :all
      scope in [:session, :agent, :workspace] and not is_binary(scope_key) ->
        []

      true ->
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

  defp clamp_limit(value, max) when is_integer(value) and value > 0, do: min(value, max)
  defp clamp_limit(_, _max), do: 20

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

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: :crypto.hash_equals(left, right)

  defp secure_equal?(_, _), do: false

  defp safe_atom(str, default) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    _ -> default
  end

  defp safe_atom(_, default), do: default
end
