defmodule LemonMemory.ProfileLifecycleTest do
  use ExUnit.Case, async: true

  alias LemonMemory.{Document, Lifecycle, Project, Store}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    store = :"profile_lifecycle_#{System.unique_integer([:positive])}"
    start_supervised!({Store, name: store, path: Path.join(tmp_dir, "store")})
    context = %{
      cwd: tmp_dir, workspace_dir: Path.join(tmp_dir, "assistant-home"),
      agent_id: "lb-alice", session_scope: :main
    }
    %{store: store, context: context, opts: [server: store]}
  end

  test "profile ownership includes agent AND assistant home, including project learnings", ctx do
    own = document(ctx, "own", "Release review")
    project = %{
      own
      | doc_id: "mem_project",
        meta: Map.put(own.meta, "kind", "project_learning"),
        workspace_key: "/a/different/repository",
        answer_summary: "Build conventions"
    }
    wrong_agent = %{own | doc_id: "mem_wrong-agent", agent_id: "lb-bob"}
    wrong_home = %{own | doc_id: "mem_wrong-home", meta: %{"home_digest" => digest("elsewhere")}}
    unscoped = %{own | doc_id: "mem_unscoped", meta: %{}}
    for doc <- [own, project, wrong_agent, wrong_home, unscoped], do: :ok = Store.put_sync(ctx.store, doc)

    assert Project.profile_document?(own, ctx.context)
    assert Project.profile_document?(project, ctx.context)
    refute Project.profile_document?(wrong_agent, ctx.context)
    refute Project.profile_document?(wrong_home, ctx.context)
    refute Project.profile_document?(unscoped, ctx.context)
    refute Project.profile_document?(own, %{ctx.context | session_scope: :subagent})

    assert {:ok, %{items: items}} = Lifecycle.profile_list(ctx.context, "", ctx.opts)
    assert Enum.sort(Enum.map(items, & &1["kind"])) == ["project_learning", "run"]
    assert {:ok, %{items: [match]}} = Lifecycle.profile_list(ctx.context, "review", ctx.opts)
    assert match["kind"] == "run"
  end

  test "owning service preview binds profile and revision and deletion removes FTS", ctx do
    doc = document(ctx, "delete", "Unique searchable lifecycle phrase")
    :ok = Store.put_sync(ctx.store, doc)
    assert {:ok, %{items: [item]}} = Lifecycle.profile_list(ctx.context, "", ctx.opts)
    id = item["id"]
    assert {:ok, ^item} = Lifecycle.profile_get(ctx.context, id, ctx.opts)
    assert {:ok, preview} = Lifecycle.profile_preview_delete(ctx.context, id, ctx.opts)
    assert {:ok, _} = Store.get_document(ctx.store, doc.doc_id)

    other = %{ctx.context | workspace_dir: ctx.context.workspace_dir <> "-other"}
    assert {:error, :not_found} = Lifecycle.profile_get(other, id, ctx.opts)
    assert {:error, :not_found} = Lifecycle.profile_preview_delete(other, id, ctx.opts)
    assert {:error, :not_found} = Lifecycle.profile_delete(other, id, preview.confirmation_digest, ctx.opts)
    assert {:error, :confirmation_mismatch} = Lifecycle.profile_delete(ctx.context, id, String.duplicate("0", 64), ctx.opts)

    :ok = Store.put_sync(ctx.store, %{doc | answer_summary: "Changed searchable lifecycle phrase"})
    assert {:error, :stale} = Lifecycle.profile_get(ctx.context, id, ctx.opts)
    assert {:error, :stale} = Lifecycle.profile_delete(ctx.context, id, preview.confirmation_digest, ctx.opts)
    assert {:ok, %{items: [fresh]}} = Lifecycle.profile_list(ctx.context, "", ctx.opts)
    assert {:ok, fresh_preview} = Lifecycle.profile_preview_delete(ctx.context, fresh["id"], ctx.opts)
    assert {:ok, %{"deleted" => true, "id" => deleted_id}} =
             Lifecycle.profile_delete(ctx.context, fresh["id"], fresh_preview.confirmation_digest, ctx.opts)
    assert deleted_id == fresh["id"]
    assert {:error, :not_found} = Store.get_document(ctx.store, doc.doc_id)
    assert Store.search(ctx.store, "lifecycle", scope: :all, limit: 10) == []
  end

  test "a preview cannot delete an ownership-changed document", ctx do
    doc = document(ctx, "moved", "An original decision")
    :ok = Store.put_sync(ctx.store, doc)
    assert {:ok, %{items: [item]}} = Lifecycle.profile_list(ctx.context, "", ctx.opts)
    assert {:ok, preview} = Lifecycle.profile_preview_delete(ctx.context, item["id"], ctx.opts)
    :ok = Store.put_sync(ctx.store, %{doc | agent_id: "lb-bob"})
    assert {:error, :not_found} =
             Lifecycle.profile_delete(ctx.context, item["id"], preview.confirmation_digest, ctx.opts)
    assert {:ok, current} = Store.get_document(ctx.store, doc.doc_id)
    assert current.agent_id == "lb-bob"
  end

  test "profile browse is bounded and store failure is not an empty list", ctx do
    for index <- 1..205 do
      :ok = Store.put_sync(ctx.store, document(ctx, "bounded-#{index}", "Bounded profile history"))
    end
    assert {:ok, %{items: items, revision: revision}} = Lifecycle.profile_list(ctx.context, "", ctx.opts)
    assert length(items) == 200
    assert byte_size(revision) == 64
    assert {:error, :memory_unavailable} =
             Lifecycle.profile_list(ctx.context, "", server: :missing_profile_lifecycle_store)
    assert {:error, :unscoped} = Lifecycle.profile_list(%{}, "", ctx.opts)
    assert {:error, :invalid_document_id} = Lifecycle.profile_get(ctx.context, "mem_raw-id", ctx.opts)
  end

  test "ingestion metadata resolves profiles to their home boundary", ctx do
    doc = Document.from_run("run", %{}, %{
      session_key: "agent:lb-alice:main", agent_id: "lb-alice", meta: %{profile_id: "lb-alice"}
    })
    assert {:ok, paths} = LemonCore.ProfileStore.paths("lb-alice")
    assert doc.meta["home_digest"] == digest(Path.expand(paths["workspace"]))
    refute Project.profile_document?(doc, ctx.context)
    explicit = Project.history_metadata(%{"home_digest" => digest(Path.expand(ctx.context.workspace_dir))})
    assert Project.profile_document?(%{doc | meta: explicit}, ctx.context)
    refute Map.has_key?(Project.history_metadata(%{profile_id: "../escape"}), "home_digest")
  end

  defp document(ctx, suffix, text) do
    Document.new(
      doc_id: "mem_#{suffix}", agent_id: ctx.context.agent_id,
      session_key: "agent:lb-alice:main", answer_summary: text, outcome: :success,
      meta: %{"home_digest" => digest(Path.expand(ctx.context.workspace_dir))}
    )
  end

  defp digest(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
end
