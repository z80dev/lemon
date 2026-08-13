defmodule LemonMemory.StoreTest do
  use ExUnit.Case, async: false

  alias LemonMemory.Document
  alias LemonMemory.Store

  @moduletag :tmp_dir

  setup do
    # Use a temp directory for each test run so stores don't collide
    tmp = System.tmp_dir!()
    dir = Path.join(tmp, "memory_store_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    # Use a unique name so we don't conflict with the globally-started Store
    name = :"memory_store_test_#{System.unique_integer([:positive])}"

    # Start an isolated Store for the test
    {:ok, pid} =
      start_supervised(
        {Store,
         [
           name: name,
           path: dir,
           retention_ms: 30 * 24 * 3_600_000,
           max_per_scope: 100
         ]}
      )

    on_exit(fn -> File.rm_rf(dir) end)

    %{store_pid: pid, dir: dir}
  end

  defp make_doc(opts) do
    now = System.system_time(:millisecond)
    session_key = Keyword.get(opts, :session_key, "agent:test_agent_#{:rand.uniform(1000)}:main")
    agent_id = Keyword.get(opts, :agent_id, "test_agent_#{:rand.uniform(1000)}")

    %Document{
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
    Store.put(pid, doc)

    assert eventually(fn ->
             results = Store.get_by_session(pid, "agent:rta:main", limit: 10)
             Enum.any?(results, &(&1.doc_id == doc.doc_id))
           end)
  end

  test "get_by_session returns most recent first", %{store_pid: pid} do
    session = "agent:order_test:main"
    now = System.system_time(:millisecond)

    doc_old = %{make_doc(session_key: session) | ingested_at_ms: now - 10_000}
    doc_new = %{make_doc(session_key: session) | ingested_at_ms: now}

    Store.put(pid, doc_old)
    Store.put(pid, doc_new)

    assert eventually(fn ->
             results = Store.get_by_session(pid, session, limit: 10)
             length(results) >= 2
           end)

    results = Store.get_by_session(pid, session, limit: 10)
    [first | _] = results
    assert first.ingested_at_ms >= hd(tl(results)).ingested_at_ms
  end

  test "same-millisecond writes order deterministically by doc_id", %{store_pid: pid} do
    session = "agent:tie_break:main"
    ts = System.system_time(:millisecond)

    # Identical ingested_at_ms — without a secondary sort key the order is
    # whatever SQLite returns, which flakes. doc_id breaks the tie.
    docs =
      for i <- 1..5 do
        %{make_doc(session_key: session) | doc_id: "mem_tie_#{i}", ingested_at_ms: ts}
      end

    Enum.each(docs, &Store.put(pid, &1))

    assert eventually(fn ->
             length(Store.get_by_session(pid, session, limit: 10)) == 5
           end)

    order = fn -> Enum.map(Store.get_by_session(pid, session, limit: 10), & &1.doc_id) end
    first_order = order.()

    # Deterministic across repeated reads, and specifically descending by doc_id.
    assert first_order == order.()
    assert first_order == Enum.sort(first_order, :desc)
  end

  describe "since_ms watermark reads" do
    test "drains the oldest unseen window so a backlog larger than the limit is never skipped",
         %{store_pid: pid} do
      agent_id = "agent_backlog_#{:rand.uniform(9999)}"
      base = System.system_time(:millisecond) - 200_000

      docs =
        for i <- 1..120 do
          %{
            make_doc(agent_id: agent_id, session_key: "agent:#{agent_id}:main")
            | doc_id: "mem_backlog_#{String.pad_leading("#{i}", 3, "0")}",
              ingested_at_ms: base + i
          }
        end

      Enum.each(docs, &Store.put(pid, &1))

      assert eventually(fn ->
               length(Store.get_by_agent(pid, agent_id, limit: 200)) == 120
             end)

      # Three passes of 50, threading the newest ingested_at_ms back as the
      # next watermark, must observe all 120 documents exactly once.
      {seen, watermark} =
        Enum.reduce(1..3, {[], 0}, fn _pass, {seen, since_ms} ->
          window = Store.get_by_agent(pid, agent_id, limit: 50, since_ms: since_ms)
          {seen ++ Enum.map(window, & &1.doc_id), List.last(window).ingested_at_ms}
        end)

      assert length(seen) == 120
      assert Enum.uniq(seen) == seen
      assert MapSet.new(seen) == MapSet.new(docs, & &1.doc_id)
      assert watermark == base + 120
      assert Store.get_by_agent(pid, agent_id, limit: 50, since_ms: watermark) == []
    end

    test "since_ms is strict and applies to session and workspace reads", %{store_pid: pid} do
      session = "agent:since_scopes:main"
      wk = "/home/test/since_#{:rand.uniform(9999)}"
      base = System.system_time(:millisecond) - 100_000

      docs =
        for i <- 1..3 do
          %{
            make_doc(session_key: session, workspace_key: wk, scope: :workspace)
            | doc_id: "mem_since_#{i}",
              ingested_at_ms: base + i
          }
        end

      Enum.each(docs, &Store.put(pid, &1))

      assert eventually(fn ->
               length(Store.get_by_session(pid, session, limit: 10)) == 3
             end)

      # Strictly greater than, and oldest-first.
      assert Enum.map(
               Store.get_by_session(pid, session, limit: 10, since_ms: base + 1),
               & &1.doc_id
             ) ==
               ["mem_since_2", "mem_since_3"]

      assert Enum.map(
               Store.get_by_workspace(pid, wk, limit: 10, since_ms: base + 2),
               & &1.doc_id
             ) == ["mem_since_3"]

      # No since_ms keeps the newest-first contract.
      assert Enum.map(Store.get_by_session(pid, session, limit: 10), & &1.doc_id) ==
               ["mem_since_3", "mem_since_2", "mem_since_1"]
    end
  end

  test "get_by_agent returns documents across sessions", %{store_pid: pid} do
    agent_id = "agent_cross_#{:rand.uniform(9999)}"
    doc1 = make_doc(agent_id: agent_id, session_key: "agent:#{agent_id}:main")
    doc2 = make_doc(agent_id: agent_id, session_key: "agent:#{agent_id}:main:sub:001")

    Store.put(pid, doc1)
    Store.put(pid, doc2)

    assert eventually(fn ->
             results = Store.get_by_agent(pid, agent_id, limit: 10)
             length(results) >= 2
           end)
  end

  test "get_by_workspace filters by workspace_key", %{store_pid: pid} do
    wk = "/home/test/project_#{:rand.uniform(9999)}"
    doc = make_doc(workspace_key: wk, scope: :workspace)
    other_doc = make_doc(workspace_key: "/other/path", scope: :workspace)

    Store.put(pid, doc)
    Store.put(pid, other_doc)

    assert eventually(fn ->
             results = Store.get_by_workspace(pid, wk, limit: 10)
             Enum.any?(results, &(&1.doc_id == doc.doc_id))
           end)

    results = Store.get_by_workspace(pid, wk, limit: 10)
    refute Enum.any?(results, &(&1.doc_id == other_doc.doc_id))
  end

  test "delete_by_session removes matching documents", %{store_pid: pid} do
    session = "agent:del_test:main"
    doc = make_doc(session_key: session)
    Store.put(pid, doc)

    assert eventually(fn ->
             results = Store.get_by_session(pid, session, limit: 10)
             Enum.any?(results, &(&1.doc_id == doc.doc_id))
           end)

    Store.delete_by_session(pid, session)

    assert eventually(fn ->
             results = Store.get_by_session(pid, session, limit: 10)
             Enum.empty?(results)
           end)
  end

  test "stats returns total count", %{store_pid: pid} do
    doc = make_doc(session_key: "agent:stats_test:main")
    Store.put(pid, doc)

    assert eventually(fn ->
             stats = Store.stats(pid)
             stats.total > 0
           end)
  end

  test "get_by_session returns empty list for unknown session", %{store_pid: pid} do
    results = Store.get_by_session(pid, "agent:nobody:main", limit: 10)
    assert results == []
  end

  test "limit is respected", %{store_pid: pid} do
    session = "agent:limit_test_#{:rand.uniform(9999)}:main"

    for _ <- 1..5 do
      Store.put(pid, make_doc(session_key: session))
    end

    assert eventually(fn ->
             results = Store.get_by_session(pid, session, limit: 10)
             length(results) >= 5
           end)

    results = Store.get_by_session(pid, session, limit: 3)
    assert length(results) == 3
  end

  test "search returns matching documents", %{store_pid: pid} do
    session = "agent:search_test_#{:rand.uniform(9999)}:main"

    doc =
      make_doc(
        session_key: session,
        prompt: "How do I deploy to production?",
        answer: "Run mix release and copy the tarball."
      )

    Store.put(pid, doc)

    assert eventually(fn ->
             results = Store.get_by_session(pid, session, limit: 10)
             results != []
           end)

    results =
      Store.search(pid, "deploy production", scope: :session, scope_key: session, limit: 5)

    assert Enum.any?(results, &(&1.doc_id == doc.doc_id))
  end

  test "prune returns ok with counts", %{store_pid: pid} do
    session = "agent:prune_test_#{:rand.uniform(9999)}:main"
    Store.put(pid, make_doc(session_key: session))

    assert eventually(fn ->
             Store.get_by_session(pid, session, limit: 10) != []
           end)

    assert {:ok, %{swept: _, pruned: _}} = Store.prune(pid)
  end

  test "search returns empty for no match", %{store_pid: pid} do
    session = "agent:search_nomatch_#{:rand.uniform(9999)}:main"
    doc = make_doc(session_key: session, prompt: "Fix the login bug", answer: "Done.")
    Store.put(pid, doc)

    assert eventually(fn ->
             Store.get_by_session(pid, session, limit: 10) != []
           end)

    results =
      Store.search(pid, "completely unrelated xyzzy quux",
        scope: :session,
        scope_key: session,
        limit: 5
      )

    assert results == []
  end

  describe "J4: search scope must not broaden to :all when scope_key is nil" do
    test "scoped :session search with nil scope_key returns empty list", %{store_pid: pid} do
      session_a = "agent:scope_a_#{:rand.uniform(9999)}:main"
      session_b = "agent:scope_b_#{:rand.uniform(9999)}:main"

      doc_a = make_doc(session_key: session_a, prompt: "deploy to production")
      doc_b = make_doc(session_key: session_b, prompt: "deploy to production")
      Store.put(pid, doc_a)
      Store.put(pid, doc_b)

      assert eventually(fn ->
               Store.get_by_session(pid, session_a, limit: 10) != []
             end)

      # Scoped search with nil scope_key must NOT fall back to :all
      results = Store.search(pid, "deploy", scope: :session, scope_key: nil, limit: 10)
      assert results == [], "scoped search with nil scope_key must return empty, not all docs"
    end

    test "scoped :agent search with nil scope_key returns empty list", %{store_pid: pid} do
      agent_id = "agent_j4_#{:rand.uniform(9999)}"

      doc =
        make_doc(agent_id: agent_id, session_key: "agent:#{agent_id}:main", prompt: "fix the bug")

      Store.put(pid, doc)

      assert eventually(fn ->
               Store.get_by_agent(pid, agent_id, limit: 10) != []
             end)

      results = Store.search(pid, "fix", scope: :agent, scope_key: nil, limit: 10)
      assert results == [], "agent-scoped search with nil scope_key must return empty"
    end

    test "scoped :workspace search with nil scope_key returns empty list", %{store_pid: pid} do
      wk = "/ws/j4_#{:rand.uniform(9999)}"
      doc = make_doc(workspace_key: wk, scope: :workspace, prompt: "refactor the module")
      Store.put(pid, doc)

      assert eventually(fn ->
               Store.get_by_workspace(pid, wk, limit: 10) != []
             end)

      results = Store.search(pid, "refactor", scope: :workspace, scope_key: nil, limit: 10)
      assert results == [], "workspace-scoped search with nil scope_key must return empty"
    end

    test ":all scope still returns results without scope_key", %{store_pid: pid} do
      session = "agent:all_scope_#{:rand.uniform(9999)}:main"
      doc = make_doc(session_key: session, prompt: "deploy application")
      Store.put(pid, doc)

      assert eventually(fn ->
               Store.get_by_session(pid, session, limit: 10) != []
             end)

      results = Store.search(pid, "deploy", scope: :all, limit: 10)
      assert Enum.any?(results, &(&1.doc_id == doc.doc_id))
    end
  end

  describe "J5: memory_documents and FTS writes must be atomic" do
    test "FTS failure leaves no orphan row in memory_documents", %{store_pid: pid, dir: dir} do
      db_path = Path.join(dir, "memory.sqlite3")

      # Wait for the Store to fully initialize (no pending puts)
      _ = Store.stats(pid)

      # Open a second connection to drop the FTS table, forcing the next put to fail on FTS
      {:ok, conn2} = Exqlite.Sqlite3.open(db_path)
      :ok = Exqlite.Sqlite3.execute(conn2, "DROP TABLE IF EXISTS memory_fts")
      :ok = Exqlite.Sqlite3.close(conn2)

      doc = make_doc(session_key: "agent:fts_atomic_test:main")
      Store.put(pid, doc)

      # Use a synchronous call to flush the cast queue
      stats = Store.stats(pid)

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
