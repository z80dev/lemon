defmodule LemonSkills.LearnTest do
  use ExUnit.Case, async: false

  alias LemonMemory.Store
  alias LemonSkills.Learn
  alias LemonSkills.Synthesis.DraftStore

  defmodule NoWriteMemory do
    def get_document(_server, _doc_id), do: {:error, :not_found}

    def put_new_sync(_server, _doc) do
      send(self(), :unexpected_memory_write)
      {:ok, :created}
    end
  end

  defmodule FailingMemory do
    def get_document(_server, _doc_id), do: {:error, :not_found}
    def put_new_sync(_server, _doc), do: {:error, :injected_memory_failure}
  end

  defmodule CrashingMemory do
    def get_document(_server, _doc_id), do: {:error, :not_found}
    def put_new_sync(_server, _doc), do: exit(:injected_memory_exit)
  end

  defmodule RacingMemory do
    def get_document(_server, _doc_id) do
      case Process.get(:racing_memory_doc) do
        nil -> {:error, :not_found}
        doc -> {:ok, doc}
      end
    end

    def put_new_sync(_server, doc) do
      Process.put(:racing_memory_doc, %{doc | answer_summary: "concurrent conflicting content"})
      {:ok, :exists}
    end
  end

  defmodule FailingDraftStore do
    def get(_key, _opts), do: {:error, :not_found}

    def put_new(_draft, _opts) do
      send(self(), :draft_write_attempted)
      {:error, :injected_draft_failure}
    end

    def record_audit(_key, _audit, _opts), do: :ok
    def delete(_key, _opts), do: :ok
  end

  defmodule RacingDraftStore do
    def get(_key, _opts) do
      if Process.get(:racing_draft_created),
        do: {:ok, %{content: "concurrent conflicting draft"}},
        else: {:error, :not_found}
    end

    def put_new(_draft, _opts) do
      Process.put(:racing_draft_created, true)
      {:error, :already_exists}
    end

    def record_audit(_key, _audit, _opts), do: :ok
    def delete(_key, _opts), do: :ok
  end

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(root)
    name = String.to_atom("learn_memory_#{System.unique_integer([:positive])}")
    start_supervised!({Store, name: name, path: Path.join(tmp_dir, "memory")})

    opts = [
      root: root,
      global: false,
      memory_server: name,
      agent_id: "reviewer",
      now_ms: 1_700_000_000_000
    ]

    {:ok, root: root, opts: opts, memory_server: name}
  end

  test "review is non-mutating and confirmation writes redacted canonical state", %{
    root: root,
    opts: opts,
    memory_server: memory_server
  } do
    planted = "sk-abcdefghijklmnopqrstuvwxyz123456"

    File.write!(
      Path.join(root, "procedure.md"),
      "# Deploy safely\napi_key=#{planted}\nValidate, stage, deploy, and verify the health check."
    )

    assert {:ok, review} = Learn.review(["@file:procedure.md"], opts)
    assert review["status"] == "review"
    assert review["canConfirm"]
    assert review["sources"]["redactionCount"] >= 1
    assert review["memory"]["action"] == "create"
    assert review["skill"]["action"] == "create"
    assert review["cleanup"]["sourceTextReturned"] == false
    refute Jason.encode!(review) =~ planted
    refute Jason.encode!(review) =~ root
    assert Store.get_by_session(memory_server, "agent:reviewer:learn", limit: 10) == []
    assert {:error, :not_found} = DraftStore.get(review["skill"]["key"], global: false, cwd: root)

    assert {:ok, confirmed} =
             Learn.confirm(["@file:procedure.md"], review["confirmationDigest"], opts)

    assert confirmed["status"] == "confirmed"
    assert confirmed["memory"]["status"] == "created"
    assert confirmed["skill"]["status"] == "created"

    assert [doc] = Store.get_by_session(memory_server, "agent:reviewer:learn", limit: 10)
    refute doc.answer_summary =~ planted
    assert doc.answer_summary =~ "[REDACTED]"
    assert doc.meta["source_digest"] == review["sources"]["contentDigest"]
    assert [provenance] = doc.meta["source_provenance"]
    assert provenance["referenceDigest"] =~ ~r/^[a-f0-9]{64}$/
    assert provenance["contentDigest"] =~ ~r/^[a-f0-9]{64}$/

    assert {:ok, draft} =
             DraftStore.get(review["skill"]["key"], global: false, cwd: root)

    refute draft.content =~ planted
    assert draft.content =~ "[REDACTED]"
    assert draft.meta["source_doc_id"] == doc.doc_id
    assert draft.meta["source_digest"] == review["sources"]["contentDigest"]
    assert draft.meta["source_provenance"] == review["sources"]["provenance"]
    assert draft.meta["source_text_redacted"] == true
    assert draft.meta["bundle_hash"] == review["skill"]["bundleDigest"]

    assert {:ok, replay_review} = Learn.review(["@file:procedure.md"], opts)
    assert replay_review["memory"]["action"] == "unchanged"
    assert replay_review["skill"]["action"] == "unchanged"

    assert {:ok, replayed} =
             Learn.confirm(
               ["@file:procedure.md"],
               replay_review["confirmationDigest"],
               opts
             )

    assert replayed["memory"]["status"] == "unchanged"
    assert replayed["skill"]["status"] == "unchanged"
    assert [_one] = Store.get_by_session(memory_server, "agent:reviewer:learn", limit: 10)

    assert {:ok, :deleted} = Store.delete_document(memory_server, doc.doc_id)
    assert [] = Store.get_by_session(memory_server, "agent:reviewer:learn", limit: 10)
    assert :ok = DraftStore.delete(review["skill"]["key"], global: false, cwd: root)
    assert {:error, :not_found} = DraftStore.get(review["skill"]["key"], global: false, cwd: root)
  end

  test "source change invalidates the exact confirmation digest", %{root: root, opts: opts} do
    path = Path.join(root, "procedure.md")
    File.write!(path, String.duplicate("A safe reusable deployment procedure. ", 8))
    assert {:ok, review} = Learn.review(["@file:procedure.md"], opts)

    File.write!(path, String.duplicate("A changed reusable deployment procedure. ", 8))

    assert {:error, {:confirmation_mismatch, _}} =
             Learn.confirm(["@file:procedure.md"], review["confirmationDigest"], opts)
  end

  test "proposal content stays idempotent across wall-clock dates", %{root: root, opts: opts} do
    File.write!(
      Path.join(root, "procedure.md"),
      String.duplicate("A stable reusable deployment procedure. ", 8)
    )

    review_opts = Keyword.put(opts, :now_ms, 1_700_000_000_000)
    next_day_opts = Keyword.put(opts, :now_ms, 1_700_086_400_000)
    much_later_opts = Keyword.put(opts, :now_ms, 1_800_000_000_000)

    assert {:ok, review} = Learn.review(["@file:procedure.md"], review_opts)

    assert {:ok, confirmed} =
             Learn.confirm(
               ["@file:procedure.md"],
               review["confirmationDigest"],
               next_day_opts
             )

    assert confirmed["status"] == "confirmed"
    assert {:ok, replay} = Learn.review(["@file:procedure.md"], much_later_opts)
    assert replay["memory"]["action"] == "unchanged"
    assert replay["skill"]["action"] == "unchanged"
  end

  test "path traversal and private-network URLs fail closed without leaking targets", %{
    root: root,
    opts: opts
  } do
    outside = Path.join(Path.dirname(root), "outside-secret.txt")
    File.write!(outside, "password=do-not-leak")

    assert {:error, {_, traversal_message}} = Learn.review(["@file:../outside-secret.txt"], opts)
    refute traversal_message =~ outside
    refute traversal_message =~ "do-not-leak"

    assert {:error, {_, url_message}} = Learn.review(["@url:http://127.0.0.1/private"], opts)
    refute url_message =~ "127.0.0.1"
    refute url_message =~ "/private"
  end

  test "a conflicting canonical draft is reported and blocks confirmation", %{
    root: root,
    opts: opts
  } do
    File.write!(
      Path.join(root, "procedure.md"),
      String.duplicate("Reusable source procedure. ", 10)
    )

    assert {:ok, review} = Learn.review(["@file:procedure.md"], opts)

    :ok =
      DraftStore.put(
        %{key: review["skill"]["key"], content: "different", source_doc_id: "other"},
        global: false,
        cwd: root
      )

    assert {:ok, conflicted} = Learn.review(["@file:procedure.md"], opts)
    refute conflicted["canConfirm"]
    assert "skill_collision" in conflicted["conflicts"]

    assert {:error, {:conflict, _}} =
             Learn.confirm(
               ["@file:procedure.md"],
               conflicted["confirmationDigest"],
               opts
             )
  end

  test "a draft write failure occurs before and prevents any memory write", %{
    root: root,
    opts: opts
  } do
    File.write!(
      Path.join(root, "procedure.md"),
      String.duplicate("Reusable safe procedure. ", 10)
    )

    failure_opts =
      opts
      |> Keyword.put(:memory_store, NoWriteMemory)
      |> Keyword.put(:memory_server, :ignored)
      |> Keyword.put(:draft_store, FailingDraftStore)

    assert {:ok, review} = Learn.review(["@file:procedure.md"], failure_opts)

    assert {:error, {:skill_write_failed, _}} =
             Learn.confirm(["@file:procedure.md"], review["confirmationDigest"], failure_opts)

    assert_received :draft_write_attempted
    refute_received :unexpected_memory_write
  end

  test "a memory failure rolls back only the newly created draft", %{root: root, opts: opts} do
    File.write!(
      Path.join(root, "procedure.md"),
      String.duplicate("Reusable safe procedure. ", 10)
    )

    failure_opts =
      opts
      |> Keyword.put(:memory_store, FailingMemory)
      |> Keyword.put(:memory_server, :ignored)

    assert {:ok, review} = Learn.review(["@file:procedure.md"], failure_opts)

    assert {:error, {:memory_write_failed, _}} =
             Learn.confirm(["@file:procedure.md"], review["confirmationDigest"], failure_opts)

    assert {:error, :not_found} =
             DraftStore.get(review["skill"]["key"], global: false, cwd: root)
  end

  test "a memory exit is sanitized and rolls back the newly created draft", %{
    root: root,
    opts: opts
  } do
    File.write!(
      Path.join(root, "procedure.md"),
      String.duplicate("Reusable safe procedure. ", 10)
    )

    failure_opts =
      opts
      |> Keyword.put(:memory_store, CrashingMemory)
      |> Keyword.put(:memory_server, :ignored)

    assert {:ok, review} = Learn.review(["@file:procedure.md"], failure_opts)

    assert {:error, {:memory_write_failed, "The operation failed safely"}} =
             Learn.confirm(["@file:procedure.md"], review["confirmationDigest"], failure_opts)

    assert {:error, :not_found} =
             DraftStore.get(review["skill"]["key"], global: false, cwd: root)
  end

  test "a draft created between replan and write is never overwritten", %{root: root, opts: opts} do
    Process.delete(:racing_draft_created)

    File.write!(
      Path.join(root, "procedure.md"),
      String.duplicate("Reusable safe procedure. ", 10)
    )

    race_opts =
      opts
      |> Keyword.put(:memory_store, NoWriteMemory)
      |> Keyword.put(:memory_server, :ignored)
      |> Keyword.put(:draft_store, RacingDraftStore)

    assert {:ok, review} = Learn.review(["@file:procedure.md"], race_opts)

    assert {:error, {:skill_collision, _}} =
             Learn.confirm(["@file:procedure.md"], review["confirmationDigest"], race_opts)

    refute_received :unexpected_memory_write
  end

  test "a memory row created between replan and write is never overwritten", %{
    root: root,
    opts: opts
  } do
    Process.delete(:racing_memory_doc)

    File.write!(
      Path.join(root, "procedure.md"),
      String.duplicate("Reusable safe procedure. ", 10)
    )

    race_opts =
      opts
      |> Keyword.put(:memory_store, RacingMemory)
      |> Keyword.put(:memory_server, :ignored)

    assert {:ok, review} = Learn.review(["@file:procedure.md"], race_opts)

    assert {:error, {:memory_write_failed, _}} =
             Learn.confirm(["@file:procedure.md"], review["confirmationDigest"], race_opts)

    assert {:error, :not_found} =
             DraftStore.get(review["skill"]["key"], global: false, cwd: root)
  end
end
