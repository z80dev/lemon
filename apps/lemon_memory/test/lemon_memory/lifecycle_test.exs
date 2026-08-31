defmodule LemonMemory.LifecycleTest do
  use ExUnit.Case, async: false

  alias LemonMemory.{Document, Lifecycle, Store}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    name = String.to_atom("memory_lifecycle_#{System.unique_integer([:positive])}")
    start_supervised!({Store, name: name, path: tmp_dir})
    {:ok, server: name, opts: [server: name]}
  end

  test "lists learned provenance and ordinary run memory with bounded safe filters", ctx do
    learned =
      document("learned", 30,
        agent_id: "reviewer",
        workspace_key: "/Users/operator/private-project",
        scope: :agent,
        answer_summary:
          "Deploy safely using password=hunter2 from https://private.invalid/run and /Users/operator/key.pem",
        meta: %{
          "kind" => "learned_source",
          "source_digest" => String.duplicate("a", 64),
          "source_count" => 1,
          "source_text_redacted" => true,
          "source_provenance" => [
            %{
              "type" => :file,
              "referenceDigest" => String.duplicate("b", 64),
              "contentDigest" => String.duplicate("c", 64),
              "selectedItems" => 2,
              "selectedBytes" => 240,
              "redactionCount" => 1,
              "reference" => "/must/not/render"
            }
          ]
        }
      )

    run =
      document("run", 20,
        agent_id: "default",
        workspace_key: "/tmp/workspace",
        scope: :workspace,
        prompt_summary: "Investigate release health",
        answer_summary: "The release is healthy."
      )

    :ok = Store.put_sync(ctx.server, learned)
    :ok = Store.put_sync(ctx.server, run)

    assert {:ok, result} =
             Lifecycle.list(%{kind: "learned_source", agent: "reviewer", limit: 10}, ctx.opts)

    assert [%{id: "mem_learned", kind: "learned_source"} = item] = result.items
    assert item.scope == "agent"
    assert item.workspace_digest =~ ~r/^[a-f0-9]{12}$/
    assert item.provenance.source_digest == String.duplicate("a", 64)
    assert [%{type: "file"} = source] = item.provenance.sources
    assert source.reference_digest == String.duplicate("b", 64)

    encoded = inspect(result, limit: :infinity)
    refute encoded =~ "hunter2"
    refute encoded =~ "private.invalid"
    refute encoded =~ "/Users"
    refute encoded =~ "/must/not/render"

    assert {:ok, workspace_result} =
             Lifecycle.list(
               %{scope: "workspace", workspace_digest: workspace_digest(run), limit: 10},
               ctx.opts
             )

    assert [%{id: "mem_run", kind: "run"}] = workspace_result.items
  end

  test "inspection redacts secret names, values, paths and URLs and withholds failure details",
       ctx do
    secret = "sk-abcdefghijklmnopqrstuvwxyz123456"

    successful =
      document("safe-preview", 30,
        prompt_summary: "Read OPENAI_API_KEY at /private/source.txt",
        answer_summary: "token=#{secret} then visit https://private.example/path"
      )

    failed =
      document("failed", 20,
        answer_summary: "ProviderError {:bad_secret, #{secret}} /private/stack.ex:42",
        outcome: :failure
      )

    :ok = Store.put_sync(ctx.server, successful)
    :ok = Store.put_sync(ctx.server, failed)

    assert {:ok, preview} = Lifecycle.inspect_document(successful.doc_id, ctx.opts)
    encoded = inspect(preview, limit: :infinity)
    refute encoded =~ secret
    refute encoded =~ "OPENAI_API_KEY"
    refute encoded =~ "/private"
    refute encoded =~ "private.example"
    assert encoded =~ "[REDACTED]"

    assert {:ok, failed_preview} = Lifecycle.inspect_document(failed.doc_id, ctx.opts)
    assert failed_preview.answer_preview == "Preview withheld for a failed run."
    refute inspect(failed_preview, limit: :infinity) =~ "ProviderError"
  end

  test "delete preview is non-mutating, rejects forged and stale confirmation, and removes FTS",
       ctx do
    doc = document("delete", 10, answer_summary: "unique searchable deletion phrase")
    :ok = Store.put_sync(ctx.server, doc)

    assert {:ok, preview} = Lifecycle.preview_delete(doc.doc_id, ctx.opts)
    assert preview.dry_run
    assert {:ok, _} = Store.get_document(ctx.server, doc.doc_id)

    forged = String.duplicate("0", 64)
    assert {:error, :confirmation_mismatch} = Lifecycle.delete(doc.doc_id, forged, ctx.opts)
    assert {:ok, _} = Store.get_document(ctx.server, doc.doc_id)

    changed = %{
      doc
      | answer_summary: "concurrently changed searchable phrase",
        ingested_at_ms: 11
    }

    :ok = Store.put_sync(ctx.server, changed)

    assert {:error, :confirmation_mismatch} =
             Lifecycle.delete(doc.doc_id, preview.confirmation_digest, ctx.opts)

    assert {:ok, current} = Store.get_document(ctx.server, doc.doc_id)
    assert current.answer_summary == changed.answer_summary

    assert {:ok, fresh} = Lifecycle.preview_delete(doc.doc_id, ctx.opts)

    assert {:ok, %{status: :deleted}} =
             Lifecycle.delete(doc.doc_id, fresh.confirmation_digest, ctx.opts)

    assert {:error, :not_found} = Store.get_document(ctx.server, doc.doc_id)
    assert Store.search(ctx.server, "concurrently changed", scope: :all, limit: 10) == []
  end

  test "store guarded delete reports stale atomically and preserves the changed row", ctx do
    doc = document("store-race", 10, answer_summary: "before")
    :ok = Store.put_sync(ctx.server, doc)
    revision = Store.document_revision(doc)

    :ok = Store.put_sync(ctx.server, %{doc | answer_summary: "after", ingested_at_ms: 11})

    assert {:ok, :stale} =
             Store.delete_document_if_unchanged(ctx.server, doc.doc_id, revision)

    assert {:ok, current} = Store.get_document(ctx.server, doc.doc_id)
    assert current.answer_summary == "after"
  end

  test "query, identifiers, filters, and item counts are strictly bounded", ctx do
    for index <- 1..70 do
      :ok =
        Store.put_sync(
          ctx.server,
          document("bounded-#{index}", index,
            answer_summary: "bounded phrase #{index}",
            agent_id: if(rem(index, 2) == 0, do: "even", else: "odd")
          )
        )
    end

    assert {:ok, result} = Lifecycle.list(%{limit: 50}, ctx.opts)
    assert length(result.items) == 50
    assert result.truncated

    assert {:ok, searched} = Lifecycle.list(%{query: "bounded phrase", limit: 7}, ctx.opts)
    assert length(searched.items) == 7

    assert {:error, :invalid_query} = Lifecycle.list(%{query: "***(((!!!"}, ctx.opts)

    assert {:error, :invalid_query} =
             Lifecycle.list(%{query: String.duplicate("a", 257)}, ctx.opts)

    assert {:error, :invalid_filter} = Lifecycle.list(%{scope: "../../global"}, ctx.opts)
    assert {:error, :invalid_filter} = Lifecycle.list(%{agent: "../../operator"}, ctx.opts)
    assert {:error, :invalid_limit} = Lifecycle.list(%{limit: 51}, ctx.opts)

    assert {:error, :invalid_document_id} =
             Lifecycle.inspect_document("../memory.sqlite3", ctx.opts)

    assert {:error, :invalid_confirmation} = Lifecycle.delete("mem_bounded-1", "short", ctx.opts)
  end

  defp document(suffix, ingested_at_ms, overrides) do
    fields = %{
      doc_id: "mem_#{suffix}",
      run_id: "run_#{suffix}",
      session_key: "agent:default:session",
      agent_id: "default",
      workspace_key: nil,
      scope: :session,
      started_at_ms: ingested_at_ms,
      ingested_at_ms: ingested_at_ms,
      prompt_summary: "Prompt #{suffix}",
      answer_summary: "Answer #{suffix}",
      tools_used: [],
      provider: nil,
      model: nil,
      outcome: :success,
      meta: %{}
    }

    Document.new(Map.merge(fields, Map.new(overrides)))
  end

  defp workspace_digest(doc) do
    :crypto.hash(:sha256, doc.workspace_key)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)
  end
end
