defmodule LemonCore.MemoryStoreTest do
  use ExUnit.Case, async: false

  alias LemonCore.MemoryDocument
  alias LemonCore.MemoryStore

  @moduletag :tmp_dir

  setup do
    # Use a temp directory for each test run so stores don't collide
    tmp = System.tmp_dir!()
    dir = Path.join(tmp, "memory_store_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    # Use a unique name so we don't conflict with the globally-started MemoryStore
    name = :"memory_store_test_#{System.unique_integer([:positive])}"

    # Start an isolated MemoryStore for the test
    {:ok, pid} =
      start_supervised(
        {MemoryStore,
         [
           name: name,
           path: dir,
           retention_ms: 30 * 24 * 3600_000,
           max_per_scope: 100
         ]}
      )

    on_exit(fn -> File.rm_rf(dir) end)

    %{store_pid: pid, dir: dir}
  end

  defp make_doc(opts \\ []) do
    now = System.system_time(:millisecond)
    session_key = Keyword.get(opts, :session_key, "agent:test_agent_#{:rand.uniform(1000)}:main")
    agent_id = Keyword.get(opts, :agent_id, "test_agent_#{:rand.uniform(1000)}")

    %MemoryDocument{
      doc_id: "mem_#{LemonCore.Id.uuid()}",
      run_id: "run_#{LemonCore.Id.uuid()}",
      session_key: session_key,
      agent_id: agent_id,
      workspace_key: Keyword.get(opts, :workspace_key),
      scope: Keyword.get(opts, :scope, :session),
      started_at_ms: now - 5_000,
      ingested_at_ms: now,
      prompt_summary: Keyword.get(opts, :prompt, "Fix the bug"),
      answer_summary: Keyword.get(opts, :answer, "Fixed it"),
      tools_used: Keyword.get(opts, :tools, ["bash"]),
      provider: "anthropic",
      model: "claude-sonnet-4-6",
      outcome: :unknown,
      meta: %{}
    }
  end

  test "put and get_by_session round-trip", %{store_pid: pid} do
    doc = make_doc(session_key: "agent:rta:main")
    MemoryStore.put(pid, doc)

    assert eventually(fn ->
      results = MemoryStore.get_by_session(pid, "agent:rta:main", limit: 10)
      Enum.any?(results, &(&1.doc_id == doc.doc_id))
    end)
  end

  test "get_by_session returns most recent first", %{store_pid: pid} do
    session = "agent:order_test:main"
    now = System.system_time(:millisecond)

    doc_old = %{make_doc(session_key: session) | ingested_at_ms: now - 10_000}
    doc_new = %{make_doc(session_key: session) | ingested_at_ms: now}

    MemoryStore.put(pid, doc_old)
    MemoryStore.put(pid, doc_new)

    assert eventually(fn ->
      results = MemoryStore.get_by_session(pid, session, limit: 10)
      length(results) >= 2
    end)

    results = MemoryStore.get_by_session(pid, session, limit: 10)
    [first | _] = results
    assert first.ingested_at_ms >= hd(tl(results)).ingested_at_ms
  end

  test "get_by_agent returns documents across sessions", %{store_pid: pid} do
    agent_id = "agent_cross_#{:rand.uniform(9999)}"
    doc1 = make_doc(agent_id: agent_id, session_key: "agent:#{agent_id}:main")
    doc2 = make_doc(agent_id: agent_id, session_key: "agent:#{agent_id}:main:sub:001")

    MemoryStore.put(pid, doc1)
    MemoryStore.put(pid, doc2)

    assert eventually(fn ->
      results = MemoryStore.get_by_agent(pid, agent_id, limit: 10)
      length(results) >= 2
    end)
  end

  test "get_by_workspace filters by workspace_key", %{store_pid: pid} do
    wk = "/home/test/project_#{:rand.uniform(9999)}"
    doc = make_doc(workspace_key: wk, scope: :workspace)
    other_doc = make_doc(workspace_key: "/other/path", scope: :workspace)

    MemoryStore.put(pid, doc)
    MemoryStore.put(pid, other_doc)

    assert eventually(fn ->
      results = MemoryStore.get_by_workspace(pid, wk, limit: 10)
      Enum.any?(results, &(&1.doc_id == doc.doc_id))
    end)

    results = MemoryStore.get_by_workspace(pid, wk, limit: 10)
    refute Enum.any?(results, &(&1.doc_id == other_doc.doc_id))
  end

  test "delete_by_session removes matching documents", %{store_pid: pid} do
    session = "agent:del_test:main"
    doc = make_doc(session_key: session)
    MemoryStore.put(pid, doc)

    assert eventually(fn ->
      results = MemoryStore.get_by_session(pid, session, limit: 10)
      Enum.any?(results, &(&1.doc_id == doc.doc_id))
    end)

    MemoryStore.delete_by_session(pid, session)

    assert eventually(fn ->
      results = MemoryStore.get_by_session(pid, session, limit: 10)
      Enum.empty?(results)
    end)
  end

  test "stats returns total count", %{store_pid: pid} do
    doc = make_doc(session_key: "agent:stats_test:main")
    MemoryStore.put(pid, doc)

    assert eventually(fn ->
      stats = MemoryStore.stats(pid)
      stats.total > 0
    end)
  end

  test "get_by_session returns empty list for unknown session", %{store_pid: pid} do
    results = MemoryStore.get_by_session(pid, "agent:nobody:main", limit: 10)
    assert results == []
  end

  test "limit is respected", %{store_pid: pid} do
    session = "agent:limit_test_#{:rand.uniform(9999)}:main"

    for _ <- 1..5 do
      MemoryStore.put(pid, make_doc(session_key: session))
    end

    assert eventually(fn ->
      results = MemoryStore.get_by_session(pid, session, limit: 10)
      length(results) >= 5
    end)

    results = MemoryStore.get_by_session(pid, session, limit: 3)
    assert length(results) == 3
  end

  test "search returns matching documents", %{store_pid: pid} do
    session = "agent:search_test_#{:rand.uniform(9999)}:main"

    doc = make_doc(
      session_key: session,
      prompt: "How do I deploy to production?",
      answer: "Run mix release and copy the tarball."
    )
    MemoryStore.put(pid, doc)

    assert eventually(fn ->
      results = MemoryStore.get_by_session(pid, session, limit: 10)
      length(results) >= 1
    end)

    results = MemoryStore.search(pid, "deploy production", scope: :session, scope_key: session, limit: 5)
    assert Enum.any?(results, &(&1.doc_id == doc.doc_id))
  end

  test "prune returns ok with counts", %{store_pid: pid} do
    session = "agent:prune_test_#{:rand.uniform(9999)}:main"
    MemoryStore.put(pid, make_doc(session_key: session))

    assert eventually(fn ->
      MemoryStore.get_by_session(pid, session, limit: 10) != []
    end)

    assert {:ok, %{swept: _, pruned: _}} = MemoryStore.prune(pid)
  end

  test "search returns empty for no match", %{store_pid: pid} do
    session = "agent:search_nomatch_#{:rand.uniform(9999)}:main"
    doc = make_doc(session_key: session, prompt: "Fix the login bug", answer: "Done.")
    MemoryStore.put(pid, doc)

    assert eventually(fn ->
      MemoryStore.get_by_session(pid, session, limit: 10) != []
    end)

    results = MemoryStore.search(pid, "completely unrelated xyzzy quux", scope: :session, scope_key: session, limit: 5)
    assert results == []
  end

  describe "J4: search scope must not broaden to :all when scope_key is nil" do
    test "scoped :session search with nil scope_key returns empty list", %{store_pid: pid} do
      session_a = "agent:scope_a_#{:rand.uniform(9999)}:main"
      session_b = "agent:scope_b_#{:rand.uniform(9999)}:main"

      doc_a = make_doc(session_key: session_a, prompt: "deploy to production")
      doc_b = make_doc(session_key: session_b, prompt: "deploy to production")
      MemoryStore.put(pid, doc_a)
      MemoryStore.put(pid, doc_b)

      assert eventually(fn ->
        MemoryStore.get_by_session(pid, session_a, limit: 10) != []
      end)

      # Scoped search with nil scope_key must NOT fall back to :all
      results = MemoryStore.search(pid, "deploy", scope: :session, scope_key: nil, limit: 10)
      assert results == [], "scoped search with nil scope_key must return empty, not all docs"
    end

    test "scoped :agent search with nil scope_key returns empty list", %{store_pid: pid} do
      agent_id = "agent_j4_#{:rand.uniform(9999)}"
      doc = make_doc(agent_id: agent_id, session_key: "agent:#{agent_id}:main", prompt: "fix the bug")
      MemoryStore.put(pid, doc)

      assert eventually(fn ->
        MemoryStore.get_by_agent(pid, agent_id, limit: 10) != []
      end)

      results = MemoryStore.search(pid, "fix", scope: :agent, scope_key: nil, limit: 10)
      assert results == [], "agent-scoped search with nil scope_key must return empty"
    end

    test "scoped :workspace search with nil scope_key returns empty list", %{store_pid: pid} do
      wk = "/ws/j4_#{:rand.uniform(9999)}"
      doc = make_doc(workspace_key: wk, scope: :workspace, prompt: "refactor the module")
      MemoryStore.put(pid, doc)

      assert eventually(fn ->
        MemoryStore.get_by_workspace(pid, wk, limit: 10) != []
      end)

      results = MemoryStore.search(pid, "refactor", scope: :workspace, scope_key: nil, limit: 10)
      assert results == [], "workspace-scoped search with nil scope_key must return empty"
    end

    test ":all scope still returns results without scope_key", %{store_pid: pid} do
      session = "agent:all_scope_#{:rand.uniform(9999)}:main"
      doc = make_doc(session_key: session, prompt: "deploy application")
      MemoryStore.put(pid, doc)

      assert eventually(fn ->
        MemoryStore.get_by_session(pid, session, limit: 10) != []
      end)

      results = MemoryStore.search(pid, "deploy", scope: :all, limit: 10)
      assert Enum.any?(results, &(&1.doc_id == doc.doc_id))
    end
  end

  describe "J5: memory_documents and FTS writes must be atomic" do
    test "FTS failure leaves no orphan row in memory_documents", %{store_pid: pid, dir: dir} do
      db_path = Path.join(dir, "memory.sqlite3")

      # Wait for the MemoryStore to fully initialize (no pending puts)
      _ = MemoryStore.stats(pid)

      # Open a second connection to drop the FTS table, forcing the next put to fail on FTS
      {:ok, conn2} = Exqlite.Sqlite3.open(db_path)
      :ok = Exqlite.Sqlite3.execute(conn2, "DROP TABLE IF EXISTS memory_fts")
      :ok = Exqlite.Sqlite3.close(conn2)

      doc = make_doc(session_key: "agent:fts_atomic_test:main")
      MemoryStore.put(pid, doc)

      # Use a synchronous call to flush the cast queue
      stats = MemoryStore.stats(pid)

      # With transaction wrapping: FTS failure rolls back main-table insert
      assert stats.total == 0,
             "orphan row found in memory_documents after FTS failure; expected atomic rollback"
    end
  end

  defp eventually(fun, attempts \\ 20)
  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(15)
      eventually(fun, attempts - 1)
    end
  end
  defp eventually(_fun, 0), do: false
end
