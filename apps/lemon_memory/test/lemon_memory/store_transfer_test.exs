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

  test "stale revisions prevent publication and preserve old rows and pending intent", ctx do
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
    assert {:ok, entry} = Store.transfer_get(ctx.server, "operation")
    assert entry == ctx.intent
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

  test "publication failure rolls back SQLite and receipt, leaving reconciliation pending", ctx do
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
    assert {:ok, entry} = Store.transfer_get(ctx.server, "operation")
    assert entry == ctx.intent
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
