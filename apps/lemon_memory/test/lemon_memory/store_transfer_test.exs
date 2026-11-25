defmodule LemonMemory.StoreTransferTest do
  use ExUnit.Case, async: true
  alias LemonMemory.{Document, Store}
  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    server = :"store_transfer_#{System.unique_integer([:positive])}"
    start_supervised!({Store, name: server, path: root})
    home = sha("assistant-home")

    binding = %{
      "profileId" => "alice",
      "mutationId" => "operation",
      "sourceNodeId" => "source",
      "nodeId" => "destination",
      "snapshotDigest" => sha("snapshot")
    }

    intent = %{"binding" => binding, "state" => "pending"}

    completed = %{
      "binding" => binding,
      "state" => "complete",
      "receipt" => Map.put(binding, "copied", true)
    }

    %{server: server, home: home, binding: binding, intent: intent, completed: completed}
  end

  test "snapshot selects exact agent and home without a management-window truncation", ctx do
    own = doc("owned", "alice", ctx.home)
    foreign = doc("foreign", "bob", ctx.home)
    old_home = doc("old-home", "alice", sha("different home"))
    for record <- [own, foreign, old_home], do: :ok = Store.put_sync(ctx.server, record)
    assert {:ok, [^own]} = Store.transfer_snapshot(ctx.server, "alice", ctx.home, &{:ok, &1})
    assert {:ok, _} = Store.transfer_put_new(ctx.server, "operation", ctx.intent)
    assert {:ok, ctx.intent} == Store.transfer_put_new(ctx.server, "operation", ctx.completed)
  end

  test "a full agent scan overflow rejects instead of hiding older selected records", ctx do
    :ok = Store.put_sync(ctx.server, doc("selected", "alice", ctx.home))
    other_home = sha("other-home")

    for index <- 1..2000 do
      :ok = Store.put_sync(ctx.server, doc("other-#{index}", "alice", other_home))
    end

    assert {:error, :snapshot_too_large} =
             Store.transfer_snapshot(ctx.server, "alice", ctx.home, &{:ok, &1})
  end

  test "row replacement, FTS and exact receipt commit together", ctx do
    old = doc("old", "alice", ctx.home)
    incoming = %{doc("new", "alice", ctx.home) | answer_summary: "Incoming searchable keyword."}
    :ok = Store.put_sync(ctx.server, old)
    assert {:ok, _} = Store.transfer_put_new(ctx.server, "operation", ctx.intent)
    owner = self()

    assert {:ok, completed} =
             Store.transfer_import(
               ctx.server,
               "alice",
               ctx.home,
               Store.transfer_revisions([old]),
               [incoming],
               "operation",
               ctx.completed,
               fn ->
                 send(owner, :published)
                 :ok
               end
             )

    assert completed == ctx.completed
    assert_received :published
    assert {:error, :not_found} = Store.get_document(ctx.server, old.doc_id)
    assert {:ok, ^incoming} = Store.get_document(ctx.server, incoming.doc_id)
    assert {:ok, ^completed} = Store.transfer_get(ctx.server, "operation")
    assert [^incoming] = Store.search(ctx.server, "searchable", scope: :all, limit: 10)
  end

  test "stale revisions prevent publication, preserve old rows and free the pending intent",
       ctx do
    old = doc("old", "alice", ctx.home)
    :ok = Store.put_sync(ctx.server, old)
    assert {:ok, _} = Store.transfer_put_new(ctx.server, "operation", ctx.intent)
    changed = %{old | answer_summary: "Newer fact."}
    :ok = Store.put_sync(ctx.server, changed)
    owner = self()

    assert {:error, :stale_destination} =
             Store.transfer_import(
               ctx.server,
               "alice",
               ctx.home,
               Store.transfer_revisions([old]),
               [],
               "operation",
               ctx.completed,
               fn ->
                 send(owner, :published)
                 :ok
               end
             )

    refute_received :published
    assert {:ok, ^changed} = Store.get_document(ctx.server, old.doc_id)
    assert {:error, :not_found} = Store.transfer_get(ctx.server, "operation")
  end

  test "foreign identifier collisions rollback deletion and never overwrite foreign summaries",
       ctx do
    old = doc("old", "alice", ctx.home)
    foreign = %{doc("collision", "bob", sha("bob-home")) | answer_summary: "Foreign fact."}
    incoming = doc("collision", "alice", ctx.home)
    for record <- [old, foreign], do: :ok = Store.put_sync(ctx.server, record)
    assert {:ok, _} = Store.transfer_put_new(ctx.server, "operation", ctx.intent)
    owner = self()

    assert {:error, :destination_conflict} =
             Store.transfer_import(
               ctx.server,
               "alice",
               ctx.home,
               Store.transfer_revisions([old]),
               [incoming],
               "operation",
               ctx.completed,
               fn ->
                 send(owner, :published)
                 :ok
               end
             )

    refute_received :published
    assert {:ok, ^old} = Store.get_document(ctx.server, old.doc_id)
    assert {:ok, ^foreign} = Store.get_document(ctx.server, foreign.doc_id)
  end

  test "publication failure rolls back SQLite and receipt and frees the pending intent", ctx do
    old = doc("old", "alice", ctx.home)
    incoming = doc("new", "alice", ctx.home)
    :ok = Store.put_sync(ctx.server, old)
    assert {:ok, _} = Store.transfer_put_new(ctx.server, "operation", ctx.intent)

    assert {:error, :memory_unavailable} =
             Store.transfer_import(
               ctx.server,
               "alice",
               ctx.home,
               Store.transfer_revisions([old]),
               [incoming],
               "operation",
               ctx.completed,
               fn -> {:error, :memory_unavailable} end
             )

    assert {:ok, ^old} = Store.get_document(ctx.server, old.doc_id)
    assert {:error, :not_found} = Store.get_document(ctx.server, incoming.doc_id)
    assert {:error, :not_found} = Store.transfer_get(ctx.server, "operation")
    assert Store.search(ctx.server, "new", scope: :all, limit: 10) == []
  end

  test "missing intents, altered receipt bindings and crossprofile imports reject before writes",
       ctx do
    owner = self()

    publish = fn ->
      send(owner, :published)
      :ok
    end

    assert {:error, :transfer_conflict} =
             Store.transfer_import(
               ctx.server,
               "alice",
               ctx.home,
               [],
               [],
               "operation",
               ctx.completed,
               publish
             )

    assert {:ok, _} = Store.transfer_put_new(ctx.server, "operation", ctx.intent)
    altered = put_in(ctx.completed, ["binding", "snapshotDigest"], sha("other snapshot"))

    assert {:error, :transfer_conflict} =
             Store.transfer_import(
               ctx.server,
               "alice",
               ctx.home,
               [],
               [],
               "operation",
               altered,
               publish
             )

    # Another operation's intent is never freed by a failure that is not its own.
    assert {:ok, ctx.intent} == Store.transfer_get(ctx.server, "operation")

    assert {:error, :transfer_conflict} =
             Store.transfer_import(
               ctx.server,
               "alice",
               ctx.home,
               [],
               [doc("foreign", "bob", ctx.home)],
               "operation",
               ctx.completed,
               publish
             )

    refute_received :published
    assert {:error, :not_found} = Store.transfer_get(ctx.server, "operation")
  end

  test "a boundary that never runs is definite and the same operation can be retried", ctx do
    incoming = doc("retried", "alice", ctx.home)
    assert {:ok, _} = Store.transfer_put_new(ctx.server, "operation", ctx.intent)
    owner = self()

    publish = fn ->
      send(owner, :published)
      :ok
    end

    assert {:error, :memory_unavailable} =
             Store.transfer_import(
               ctx.server,
               "alice",
               ctx.home,
               [],
               [incoming],
               "operation",
               ctx.completed,
               publish,
               boundary: fn _run -> {:error, :memory_unavailable} end
             )

    refute_received :published
    assert {:error, :not_found} = Store.transfer_get(ctx.server, "operation")
    assert {:ok, _} = Store.transfer_put_new(ctx.server, "operation", ctx.intent)

    assert {:ok, completed} =
             Store.transfer_import(
               ctx.server,
               "alice",
               ctx.home,
               [],
               [incoming],
               "operation",
               ctx.completed,
               publish
             )

    assert completed == ctx.completed
    assert_received :published
    assert {:ok, ^incoming} = Store.get_document(ctx.server, incoming.doc_id)
  end

  test "an unverified rollback stays pending and keeps the intent", ctx do
    assert {:ok, _} = Store.transfer_put_new(ctx.server, "operation", ctx.intent)

    assert {:error, :transfer_pending} =
             Store.transfer_import(
               ctx.server,
               "alice",
               ctx.home,
               [],
               [],
               "operation",
               ctx.completed,
               fn -> {:error, :memory_unavailable} end,
               rollback: fn -> {:error, :restore_failed} end
             )

    assert {:ok, ctx.intent} == Store.transfer_get(ctx.server, "operation")
  end

  test "the receipt commit releases the named snapshot and previews only", ctx do
    assert {:ok, _} = Store.transfer_put_new(ctx.server, "operation", ctx.intent)
    assert {:ok, _} = Store.transfer_put_new(ctx.server, "source:op", envelope(["mem_x"]))

    assert {:ok, _} =
             Store.transfer_put_new(ctx.server, "preview:op:" <> sha("a"), %{"preview" => %{}})

    assert {:ok, _} = Store.transfer_put_new(ctx.server, "preview:other:1", %{"preview" => %{}})

    assert {:ok, _} =
             Store.transfer_import(
               ctx.server,
               "alice",
               ctx.home,
               [],
               [],
               "operation",
               ctx.completed,
               fn -> :ok end,
               release: [{:key, "source:op"}, {:prefix, "preview:op:"}]
             )

    assert {:error, :not_found} = Store.transfer_get(ctx.server, "source:op")
    assert {:error, :not_found} = Store.transfer_get(ctx.server, "preview:op:" <> sha("a"))
    assert {:ok, _} = Store.transfer_get(ctx.server, "preview:other:1")
    assert {:ok, ctx.completed} == Store.transfer_get(ctx.server, "operation")
    assert :ok = Store.transfer_release(ctx.server, [{:prefix, "preview:other:"}])
    assert {:error, :not_found} = Store.transfer_get(ctx.server, "preview:other:1")
  end

  test "deleting a captured document deletes every snapshot that holds it", ctx do
    secret = "Private fact about the deploy key rotation."
    kept = doc("kept", "alice", ctx.home)
    private = %{doc("private", "alice", ctx.home) | answer_summary: secret}
    for record <- [kept, private], do: :ok = Store.put_sync(ctx.server, record)

    assert {:ok, _} =
             Store.transfer_put_new(ctx.server, "source:a", envelope([private.doc_id], secret))

    assert {:ok, _} = Store.transfer_put_new(ctx.server, "source:b", envelope([kept.doc_id]))
    assert {:ok, _} = Store.transfer_put_new(ctx.server, "operation", ctx.intent)
    assert journal_bytes(ctx) =~ secret

    assert {:ok, :deleted} =
             Store.delete_document_if_unchanged(
               ctx.server,
               private.doc_id,
               Store.document_revision(private)
             )

    refute journal_bytes(ctx) =~ secret
    assert {:error, :not_found} = Store.transfer_get(ctx.server, "source:a")
    assert {:ok, _} = Store.transfer_get(ctx.server, "source:b")
    assert {:ok, _} = Store.transfer_get(ctx.server, "operation")

    assert {:ok, :deleted} = Store.delete_document(ctx.server, kept.doc_id)
    assert {:error, :not_found} = Store.transfer_get(ctx.server, "source:b")
    assert {:ok, _} = Store.transfer_get(ctx.server, "operation")
  end

  test "scope erasure removes snapshots of the erased documents and of an erased agent", ctx do
    session = doc("session", "alice", ctx.home)
    workspace = %{doc("workspace", "alice", ctx.home) | workspace_key: "/work/a"}
    other = %{doc("other", "alice", ctx.home) | session_key: "agent:alice:other"}
    for record <- [session, workspace, other], do: :ok = Store.put_sync(ctx.server, record)

    for {key, ids} <- [
          {"source:session", [session.doc_id]},
          {"source:workspace", [workspace.doc_id]},
          {"source:other", [other.doc_id]},
          {"source:empty", []}
        ],
        do: assert({:ok, _} = Store.transfer_put_new(ctx.server, key, envelope(ids)))

    Store.delete_by_session(ctx.server, "agent:alice:main")
    _ = Store.stats(ctx.server)
    assert {:error, :not_found} = Store.transfer_get(ctx.server, "source:session")
    assert {:ok, _} = Store.transfer_get(ctx.server, "source:other")

    :ok = Store.put_sync(ctx.server, workspace)

    assert {:ok, _} =
             Store.transfer_put_new(ctx.server, "source:workspace", envelope([workspace.doc_id]))

    Store.delete_by_workspace(ctx.server, "/work/a")
    _ = Store.stats(ctx.server)
    assert {:error, :not_found} = Store.transfer_get(ctx.server, "source:workspace")

    Store.delete_by_agent(ctx.server, "alice")
    _ = Store.stats(ctx.server)
    assert {:error, :not_found} = Store.transfer_get(ctx.server, "source:other")
    # A snapshot of the agent's preference files alone goes with the agent too.
    assert {:error, :not_found} = Store.transfer_get(ctx.server, "source:empty")
  end

  test "retention and the transfer TTL prune snapshots and previews, not receipts", %{
    tmp_dir: root
  } do
    server = :"store_transfer_ttl_#{System.unique_integer([:positive])}"
    path = Path.join(root, "ttl")

    start_supervised!(
      Supervisor.child_spec(
        {Store, name: server, path: path, retention_ms: 120_000, transfer_ttl_ms: 60_000},
        id: server
      )
    )

    home = sha("ttl-home")
    old = %{doc("aged", "alice", home) | ingested_at_ms: 1}
    fresh = doc("fresh", "alice", home)
    for record <- [old, fresh], do: :ok = Store.put_sync(server, record)
    assert {:ok, _} = Store.transfer_put_new(server, "source:aged", envelope([old.doc_id]))
    assert {:ok, _} = Store.transfer_put_new(server, "source:fresh", envelope([fresh.doc_id]))
    assert {:ok, _} = Store.transfer_put_new(server, "preview:fresh:1", %{"preview" => %{}})
    assert {:ok, _} = Store.transfer_put_new(server, "destination:fresh", %{"state" => "pending"})

    assert {:ok, %{swept: 1}} = Store.prune(server)
    assert {:error, :not_found} = Store.transfer_get(server, "source:aged")
    assert {:ok, _} = Store.transfer_get(server, "source:fresh")

    age_journal(Path.join(path, "memory.sqlite3"), 60_001)
    assert {:ok, _} = Store.prune(server)
    assert {:error, :not_found} = Store.transfer_get(server, "source:fresh")
    assert {:error, :not_found} = Store.transfer_get(server, "preview:fresh:1")
    assert {:ok, _} = Store.transfer_get(server, "destination:fresh")
  end

  test "index kinds are SQLite strings while source atom metadata remains unchanged", ctx do
    record = doc("atom-kind", "alice", ctx.home)

    record =
      %{record | meta: Map.put(record.meta, :kind, :learned_source)}
      |> Document.with_index()

    assert :ok = Store.put_sync(ctx.server, record)
    assert {:ok, ^record} = Store.get_document(ctx.server, record.doc_id)
    assert record.index == {"legacy", nil, ctx.home, "learned_source", nil}
    assert {:ok, [^record]} = Store.transfer_snapshot(ctx.server, "alice", ctx.home, &{:ok, &1})
  end

  @tag timeout: 10_000
  test "slow snapshot callbacks keep Store status responsive and bound transfer callers", ctx do
    assert {:ok, _} = Store.transfer_put_new(ctx.server, "operation", ctx.intent)
    owner = self()
    store = Process.whereis(ctx.server)

    snapshot =
      Task.async(fn ->
        Store.transfer_snapshot(ctx.server, "alice", ctx.home, fn _docs ->
          send(owner, {:snapshot_entered, self()})

          receive do
            :release_snapshot -> {:ok, []}
          end
        end)
      end)

    assert_receive {:snapshot_entered, worker}, 1_000
    on_exit(fn -> send(worker, :release_snapshot) end)
    assert %{total: 0} = GenServer.call(store, :stats, 1_000)
    assert {:status, ^store, _, _} = :sys.get_status(store, 1_000)

    read = Task.async(fn -> Store.transfer_get(ctx.server, "operation") end)
    journal = Task.async(fn -> Store.transfer_put_new(ctx.server, "queued", ctx.intent) end)

    import =
      Task.async(fn ->
        Store.transfer_import(
          ctx.server,
          "alice",
          ctx.home,
          [],
          [],
          "operation",
          ctx.completed,
          fn ->
            send(owner, :published_after_timeout)
            :ok
          end
        )
      end)

    assert {:error, :memory_unavailable} = Task.await(snapshot, 6_000)
    assert {:error, :memory_unavailable} = Task.await(read, 1_000)
    assert {:error, :memory_unavailable} = Task.await(journal, 1_000)
    assert {:error, :transfer_pending} = Task.await(import, 1_000)
    refute_received :published_after_timeout

    send(worker, :release_snapshot)
    assert_receive :published_after_timeout, 1_000
    assert {:ok, entry} = Store.transfer_get(ctx.server, "operation")
    assert entry == ctx.completed
    assert {:ok, entry} = Store.transfer_get(ctx.server, "queued")
    assert entry == ctx.intent
  end

  test "snapshot worker death rolls back the transaction and releases queued writes", ctx do
    owner = self()

    snapshot =
      Task.async(fn ->
        Store.transfer_snapshot(ctx.server, "alice", ctx.home, fn _docs ->
          send(owner, {:snapshot_worker, self()})

          receive do
            :release -> {:ok, []}
          end
        end)
      end)

    assert_receive {:snapshot_worker, worker}, 1_000
    record = doc("after-worker-death", "alice", ctx.home)
    write = :gen_server.send_request(ctx.server, {:put_sync, record})
    assert :queue.len(:sys.get_state(ctx.server, 1_000).deferred) == 1
    Process.exit(worker, :kill)
    assert {:error, :memory_unavailable} = Task.await(snapshot, 1_000)
    assert {:reply, :ok} = :gen_server.receive_response(write, 1_000)
    assert {:ok, [^record]} = Store.transfer_snapshot(ctx.server, "alice", ctx.home, &{:ok, &1})
  end

  test "snapshot worker admission failure releases the SQLite transaction", ctx do
    :sys.replace_state(ctx.server, &%{&1 | task_supervisor: :missing_memory_task_supervisor})

    assert {:error, :memory_unavailable} =
             Store.transfer_snapshot(ctx.server, "alice", ctx.home, &{:ok, &1})

    record = doc("after-admission-failure", "alice", ctx.home)
    assert :ok = Store.put_sync(ctx.server, record)
    assert {:ok, ^record} = Store.get_document(ctx.server, record.doc_id)
  end

  # The shape `LemonSkills.ProfileMemoryTransfer` freezes: content lives under
  # `snapshot.documents[*]` and `snapshot.preferences`.
  defp envelope(ids, text \\ "Saved fact.") do
    %{
      "profileId" => "alice",
      "mutationId" => "operation",
      "snapshot" => %{
        "documents" => Enum.map(ids, &%{"id" => &1, "answerSummary" => text}),
        "preferences" => %{"USER.md" => text, "MEMORY.md" => nil}
      }
    }
  end

  # Every journal payload as stored, read through a separate SQLite connection.
  defp journal_bytes(ctx) do
    with_connection(Path.join(ctx.tmp_dir, "memory.sqlite3"), fn conn ->
      {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT payload FROM memory_transfer_journal")
      {:ok, rows} = Exqlite.Sqlite3.fetch_all(conn, stmt)
      :ok = Exqlite.Sqlite3.release(conn, stmt)
      rows |> List.flatten() |> Enum.join("\n")
    end)
  end

  defp age_journal(database, by_ms) do
    with_connection(database, fn conn ->
      :ok =
        Exqlite.Sqlite3.execute(
          conn,
          "UPDATE memory_transfer_journal SET created_at_ms = created_at_ms - #{by_ms}"
        )
    end)
  end

  defp with_connection(database, fun) do
    {:ok, conn} = Exqlite.Sqlite3.open(database)

    try do
      :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA busy_timeout=5000")
      fun.(conn)
    after
      Exqlite.Sqlite3.close(conn)
    end
  end

  defp doc(id, agent, home) do
    %Document{
      doc_id: "mem_" <> id,
      run_id: "run-" <> id,
      session_key: "agent:" <> agent <> ":main",
      agent_id: agent,
      prompt_summary: "Saved summary",
      answer_summary: "Saved " <> id <> " fact.",
      ingested_at_ms: System.system_time(:millisecond),
      meta: %{"home_digest" => home}
    }
    |> Document.with_index()
  end

  defp sha(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
