defmodule LemonSkills.ProfileMemoryTransferTest do
  use ExUnit.Case, async: true
  alias LemonCore.{JSONPayload, ProfileStore}
  alias LemonMemory.{Document, Project, Store}
  alias LemonSkills.ProfileMemoryTransfer, as: Transfer
  alias LemonSkills.WorkspacePreferences, as: Preferences
  @moduletag :tmp_dir
  @profile "lb-alice"

  setup %{tmp_dir: root} do
    source = start_store(root, "source")
    target = start_store(root, "target")
    source_opts = [store: source, profile_opts: [home_state_dir: Path.join(root, "source-state")]]

    target_opts = [
      store: target,
      profile_opts: [home_state_dir: Path.join(root, "target-state")],
      node_id: "node-target"
    ]

    source_home = home(source_opts)
    target_home = home(target_opts)
    File.mkdir_p!(source_home)
    File.mkdir_p!(target_home)

    %{
      source: source,
      target: target,
      source_opts: source_opts,
      target_opts: target_opts,
      source_home: source_home,
      target_home: target_home,
      root: root
    }
  end

  test "exact full bytes and scoped metadata transfer, without general files or history", ctx do
    content = "# Memory\n\n" <> String.duplicate("A semantically complete saved fact.\n", 260)
    File.write!(Path.join(ctx.source_home, "MEMORY.md"), content)
    File.write!(Path.join(ctx.source_home, "USER.md"), "# User\n\nLikes written plans.\n")

    for name <- ["cookies.json", "credentials.json", "session.jsonl", "other.md"] do
      File.write!(Path.join(ctx.source_home, name), "must not copy")
    end

    own = doc(ctx.source_home, "own", String.duplicate("complete summary ", 250))
    other_agent = %{own | doc_id: "mem_other-agent", agent_id: "lb-bob"}

    other_home = %{
      own
      | doc_id: "mem_other-home",
        meta: %{"home_digest" => sha("different home")}
    }

    legacy = %{own | doc_id: "mem_legacy", meta: %{}}

    for record <- [own, other_agent, other_home, legacy],
        do: :ok = Store.put_sync(ctx.source, record)

    assert {:ok, envelope} = prepare(ctx)

    assert Enum.sort(Map.keys(envelope)) ==
             Enum.sort(~w(profileId mutationId sourceNodeId nodeId snapshotDigest snapshot))

    assert envelope["snapshotDigest"] == sha(canonical(envelope["snapshot"]))
    assert [record] = envelope["snapshot"]["documents"]
    assert record["answerSummary"] == own.answer_summary

    assert record["metadata"] == %{
             "home_digest" => sha(Path.expand(ctx.source_home)),
             "memory_scope" => "legacy"
           }

    refute Jason.encode!(envelope) =~ ctx.root
    assert :ok = Transfer.validate(envelope, ctx.source_opts)
    assert {:ok, receipt} = Transfer.apply_transfer(envelope, ctx.target_opts)

    assert Enum.sort(Map.keys(receipt)) ==
             Enum.sort(~w(profileId mutationId sourceNodeId nodeId snapshotDigest copied))

    assert receipt["copied"] == true
    assert File.read!(Path.join(ctx.target_home, "MEMORY.md")) == content

    assert File.read!(Path.join(ctx.target_home, "USER.md")) ==
             File.read!(Path.join(ctx.source_home, "USER.md"))

    for name <- ["cookies.json", "credentials.json", "session.jsonl", "other.md"],
        do: refute(File.exists?(Path.join(ctx.target_home, name)))

    assert {:ok, [imported]} = Store.list_agent_recent(ctx.target, @profile, limit: 500)
    assert imported.answer_summary == own.answer_summary
    assert imported.meta["home_digest"] == sha(Path.expand(ctx.target_home))
    assert imported.workspace_key == ctx.target_home
    assert {:ok, ^own} = Store.get_document(ctx.source, own.doc_id)
    assert {:ok, ^receipt} = Transfer.apply_transfer(envelope, ctx.target_opts)

    assert {:ok, ^receipt} =
             Transfer.status(@profile, "mutation-1", "local", "node-target", ctx.target_opts)
  end

  test "frozen snapshots survive source changes and validate rejects stale complete revisions",
       ctx do
    own = doc(ctx.source_home, "frozen", "Saved fact.")
    :ok = Store.put_sync(ctx.source, own)
    assert {:ok, envelope} = prepare(ctx)

    :ok =
      Store.put_sync(ctx.source, %{
        own
        | meta: Map.put(own.meta, "local_path", "/private/new-path")
      })

    assert {:ok, ^envelope} = prepare(ctx)

    assert {:ok, ^envelope} =
             Transfer.snapshot(@profile, "mutation-1", "local", "node-target", ctx.source_opts)

    assert {:error, :stale_source} = Transfer.validate(envelope, ctx.source_opts)

    assert {:error, :transfer_conflict} =
             Transfer.prepare(@profile, "mutation-1", "local", "node-other", ctx.source_opts)

    assert {:error, :transfer_conflict} =
             Transfer.snapshot(
               @profile,
               "mutation-1",
               "node-other",
               "node-target",
               ctx.source_opts
             )

    assert {:error, :not_found} =
             Transfer.snapshot(@profile, "not-prepared", "local", "node-target", ctx.source_opts)
  end

  test "preferences including absent versus empty files are part of stale source check", ctx do
    assert {:ok, envelope} = prepare(ctx)
    File.write!(Path.join(ctx.source_home, "USER.md"), "")
    assert {:error, :stale_source} = Transfer.validate(envelope, ctx.source_opts)
  end

  test "create only rejects even identical target data without an operation receipt", ctx do
    File.write!(Path.join(ctx.source_home, "MEMORY.md"), "Same saved fact.\n")
    File.write!(Path.join(ctx.target_home, "MEMORY.md"), "Same saved fact.\n")
    assert {:ok, envelope} = prepare(ctx)
    assert {:error, :destination_conflict} = Transfer.apply_transfer(envelope, ctx.target_opts)

    assert {:error, :not_found} =
             Transfer.status(@profile, "mutation-1", "local", "node-target", ctx.target_opts)

    assert File.read!(Path.join(ctx.target_home, "MEMORY.md")) == "Same saved fact.\n"
  end

  test "opaque persisted preview confirms exact overwrite and preserves other scopes", ctx do
    File.write!(Path.join(ctx.source_home, "MEMORY.md"), "Incoming fact.\n")
    File.write!(Path.join(ctx.target_home, "USER.md"), "Old user preference.\n")
    selected = doc(ctx.target_home, "selected", "Old selected fact.")
    other = %{selected | doc_id: "mem_other", agent_id: "lb-bob"}

    other_home =
      Document.with_index(%{
        selected
        | doc_id: "mem_other-home",
          meta: %{"home_digest" => sha("another")}
      })

    for record <- [selected, other, other_home], do: :ok = Store.put_sync(ctx.target, record)
    assert {:ok, envelope} = prepare(ctx)
    assert {:ok, preview} = Transfer.preview(envelope, ctx.target_opts)
    assert preview["sourceCounts"] == %{"documents" => 0, "preferences" => 1}
    assert preview["destinationCounts"] == %{"documents" => 1, "preferences" => 1}
    assert preview["overwrite"] == true
    refute Jason.encode!(preview) =~ "Old selected fact"
    refute Jason.encode!(preview) =~ ctx.root
    assert {:ok, ^preview} = Transfer.preview(envelope, ctx.target_opts)
    assert {:ok, ^selected} = Store.get_document(ctx.target, selected.doc_id)

    assert {:error, :confirmation_mismatch} =
             Transfer.apply_transfer(
               confirm(envelope, %{preview | "confirmationToken" => "forged"}),
               ctx.target_opts
             )

    assert {:ok, receipt} = Transfer.apply_transfer(confirm(envelope, preview), ctx.target_opts)
    assert {:error, :not_found} = Store.get_document(ctx.target, selected.doc_id)
    assert {:ok, ^other} = Store.get_document(ctx.target, other.doc_id)
    assert {:ok, ^other_home} = Store.get_document(ctx.target, other_home.doc_id)
    refute File.exists?(Path.join(ctx.target_home, "USER.md"))
    assert File.read!(Path.join(ctx.target_home, "MEMORY.md")) == "Incoming fact.\n"
    assert {:ok, ^receipt} = Transfer.apply_transfer(envelope, ctx.target_opts)
  end

  test "preview rejects stale preferences and stale durable metadata", ctx do
    File.write!(Path.join(ctx.target_home, "MEMORY.md"), "Old fact.\n")
    own = doc(ctx.target_home, "stale", "Old summary.")
    :ok = Store.put_sync(ctx.target, own)
    assert {:ok, envelope} = prepare(ctx)
    assert {:ok, first} = Transfer.preview(envelope, ctx.target_opts)
    File.write!(Path.join(ctx.target_home, "MEMORY.md"), "Newer fact.\n")

    assert {:error, :stale_destination} =
             Transfer.apply_transfer(confirm(envelope, first), ctx.target_opts)

    assert {:ok, second} = Transfer.preview(envelope, ctx.target_opts)
    :ok = Store.put_sync(ctx.target, %{own | meta: Map.put(own.meta, "arbitrary_revision", 1)})

    assert {:error, :stale_destination} =
             Transfer.apply_transfer(confirm(envelope, second), ctx.target_opts)

    assert File.read!(Path.join(ctx.target_home, "MEMORY.md")) == "Newer fact.\n"
  end

  test "digest, crossprofile records, node binding, shape and control fields fail closed", ctx do
    :ok = Store.put_sync(ctx.source, doc(ctx.source_home, "shape", "Scoped fact."))
    assert {:ok, envelope} = prepare(ctx)

    assert {:error, :invalid_snapshot} =
             Transfer.apply_transfer(
               Map.put(envelope, "snapshotDigest", sha("wrong")),
               ctx.target_opts
             )

    altered =
      update_in(envelope, ["snapshot", "documents"], fn [record] ->
        [Map.put(record, "agentId", "lb-bob")]
      end)
      |> rehash()

    assert {:error, :profile_mismatch} = Transfer.apply_transfer(altered, ctx.target_opts)

    assert {:error, :node_mismatch} =
             Transfer.apply_transfer(
               envelope,
               Keyword.put(ctx.target_opts, :node_id, "wrong-node")
             )

    assert {:error, :invalid_snapshot} =
             Transfer.apply_transfer(Map.put(envelope, "path", ctx.source_home), ctx.target_opts)

    malformed = put_in(envelope, ["snapshot", "documents"], [nil]) |> rehash()
    assert {:error, :invalid_snapshot} = Transfer.apply_transfer(malformed, ctx.target_opts)

    assert {:error, :invalid_id} =
             Transfer.prepare("../escape", "mutation", "local", "node-target", ctx.source_opts)

    assert {:ok, preview} = Transfer.preview(envelope, ctx.target_opts)

    changed =
      put_in(
        envelope,
        ["snapshot", "documents", Access.at(0), "answerSummary"],
        "Different incoming fact."
      )
      |> rehash()

    assert {:error, :confirmation_mismatch} =
             Transfer.apply_transfer(confirm(changed, preview), ctx.target_opts)
  end

  test "unsafe source content including excluded secret metadata fails instead of redacting",
       ctx do
    own = doc(ctx.source_home, "unsafe", "password=hunter2")
    :ok = Store.put_sync(ctx.source, own)
    assert {:error, :unsafe_snapshot} = prepare(ctx)

    :ok =
      Store.put_sync(ctx.source, %{
        own
        | answer_summary: "Safe fact.",
          meta: Map.put(own.meta, "credential", "api_key=sk-secret")
      })

    assert {:error, :unsafe_snapshot} = prepare(ctx)

    :ok =
      Store.put_sync(ctx.source, %{
        own
        | answer_summary: "Safe fact.",
          meta: Map.put(own.meta, "excluded_run_metadata", {:credential, "password=hunter2"})
      })

    assert {:error, :unsafe_snapshot} = prepare(ctx)
    :ok = Store.put_sync(ctx.source, %{own | answer_summary: "Safe fact."})
    File.write!(Path.join(ctx.source_home, "USER.md"), "password=hunter2")
    assert {:error, :unsafe_snapshot} = prepare(ctx)
  end

  test "source oversized snapshots and 501 scoped records are rejected, not truncated", ctx do
    own = doc(ctx.source_home, "oversized", String.duplicate("a", 2 * 1024 * 1024))
    :ok = Store.put_sync(ctx.source, own)
    assert {:error, :snapshot_too_large} = prepare(ctx)
    assert {:ok, :deleted} = Store.delete_document(ctx.source, own.doc_id)

    for index <- 1..501,
        do: :ok = Store.put_sync(ctx.source, doc(ctx.source_home, "overflow-#{index}", "Fact."))

    assert {:error, :snapshot_too_large} = prepare(ctx)
  end

  test "node item policy rejects 500 valid small records before freezing any snapshot", ctx do
    for index <- 1..500 do
      record = %{
        doc(ctx.source_home, "transport-#{index}", "Complete saved fact.")
        | tools_used: ["mcp/one", "mcp/two"]
      }

      :ok = Store.put_sync(ctx.source, record)
    end

    frozen_key = "source:" <> sha(@profile <> "\0mutation-1")
    assert {:error, :not_found} = Store.transfer_get(ctx.source, frozen_key)
    assert {:error, :snapshot_too_large} = prepare(ctx)
    assert {:error, :not_found} = Store.transfer_get(ctx.source, frozen_key)

    assert {:error, :not_found} =
             Transfer.snapshot(@profile, "mutation-1", "local", "node-target", ctx.source_opts)

    assert {:ok, rows} = Store.list_agent_recent(ctx.source, @profile, limit: 500)
    assert length(rows) == 500
    assert Enum.all?(rows, &(&1.answer_summary == "Complete saved fact."))

    assert {:ok, %{"status" => "unknown", "receipt" => nil}} =
             Transfer.inspect_status(@profile, "mutation-1", "node-target", ctx.target_opts)
  end

  test "incoming snapshots share byte, item and reserved depth limits", ctx do
    source = %{
      doc(ctx.source_home, "incoming-budget", "Complete saved fact.")
      | tools_used: ["mcp/one", "mcp/two"]
    }

    :ok = Store.put_sync(ctx.source, source)
    assert {:ok, envelope} = prepare(ctx)
    [record] = envelope["snapshot"]["documents"]
    documents = Enum.map(1..500, fn index -> Map.put(record, "id", "mem_incoming-#{index}") end)
    wide = put_in(envelope, ["snapshot", "documents"], documents) |> rehash()
    assert byte_size(Jason.encode!(wide["snapshot"])) < 2 * 1024 * 1024

    assert {:error, {:max_items, _}} =
             JSONPayload.validate(wide["snapshot"], max_bytes: 2 * 1024 * 1024)

    assert {:error, :snapshot_too_large} = Transfer.apply_transfer(wide, ctx.target_opts)
    nested = Enum.reduce(1..(JSONPayload.default_max_depth() - 7), 0, fn _, value -> [value] end)

    deep =
      put_in(
        envelope,
        ["snapshot", "documents", Access.at(0), "metadata", "source_provenance"],
        nested
      )
      |> rehash()

    assert {:error, :snapshot_too_large} = Transfer.apply_transfer(deep, ctx.target_opts)

    oversized =
      put_in(
        envelope,
        ["snapshot", "documents", Access.at(0), "answerSummary"],
        String.duplicate("a", 2 * 1024 * 1024)
      )
      |> rehash()

    assert {:error, :snapshot_too_large} = Transfer.apply_transfer(oversized, ctx.target_opts)
    assert {:ok, []} = Store.list_agent_recent(ctx.target, @profile, limit: 500)

    assert {:ok, %{"status" => "unknown", "receipt" => nil}} =
             Transfer.inspect_status(@profile, "mutation-1", "node-target", ctx.target_opts)

    refute File.exists?(Path.join(ctx.target_home, "USER.md"))
    refute File.exists?(Path.join(ctx.target_home, "MEMORY.md"))
  end

  test "file size boundaries and symlinks cannot escape profile home", ctx do
    File.write!(Path.join(ctx.source_home, "USER.md"), String.duplicate("a", 65_536))
    assert {:ok, envelope} = prepare(ctx)
    assert byte_size(envelope["snapshot"]["preferences"]["USER.md"]) == 65_536
    File.write!(Path.join(ctx.source_home, "USER.md"), String.duplicate("a", 65_537))

    assert {:error, :memory_unavailable} =
             Transfer.prepare(@profile, "too-large-file", "local", "node-target", ctx.source_opts)

    File.rm!(Path.join(ctx.source_home, "USER.md"))
    File.ln_s!(Path.join(ctx.root, "outside"), Path.join(ctx.source_home, "USER.md"))

    assert {:error, :memory_unavailable} =
             Transfer.prepare(@profile, "symlink", "local", "node-target", ctx.source_opts)
  end

  test "home project identity is rebound and distinct repository facts stay intact", ctx do
    context = %{
      agent_id: @profile,
      cwd: ctx.source_home,
      workspace_dir: ctx.source_home,
      session_scope: :main,
      session_key: "agent:lb-alice:main"
    }

    assert {:ok, _} = Project.remember(context, "Build with mix release.", nil, store: ctx.source)

    remote_project = %{
      doc(ctx.source_home, "repository", "Never forget repository-specific facts.")
      | workspace_key: Path.join(ctx.root, "other-repository"),
        meta: %{"home_digest" => sha(Path.expand(ctx.source_home)), "kind" => "project_learning"}
    }

    :ok = Store.put_sync(ctx.source, remote_project)
    assert {:ok, envelope} = prepare(ctx)
    assert {:ok, _} = Transfer.apply_transfer(envelope, ctx.target_opts)
    target_context = %{context | cwd: ctx.target_home, workspace_dir: ctx.target_home}
    assert {:ok, ["Build with mix release."]} = Project.read(target_context, store: ctx.target)
    assert {:ok, docs} = Store.list_agent_recent(ctx.target, @profile, limit: 500)

    assert Enum.any?(
             docs,
             &(&1.answer_summary == remote_project.answer_summary and
                 String.starts_with?(&1.workspace_key, "sha256:"))
           )
  end

  test "pending destination never replays and durable receipt survives Store restart", ctx do
    assert {:ok, envelope} = prepare(ctx)
    binding = Map.delete(envelope, "snapshot")
    journal_key = "destination:" <> sha(@profile <> "\0mutation-1")

    assert {:ok, _} =
             Store.transfer_put_new(ctx.target, journal_key, %{
               "binding" => binding,
               "state" => "pending",
               "destinationHomeDigest" => sha(Path.expand(ctx.target_home))
             })

    assert {:error, :transfer_pending} = Transfer.apply_transfer(envelope, ctx.target_opts)

    assert {:error, :transfer_pending} =
             Transfer.status(@profile, "mutation-1", "local", "node-target", ctx.target_opts)

    assert {:error, :transfer_conflict} =
             Transfer.status(
               @profile,
               "mutation-1",
               "local",
               "node-other",
               Keyword.delete(ctx.target_opts, :node_id)
             )

    assert {:ok, second} =
             Transfer.prepare(@profile, "mutation-2", "local", "node-target", ctx.source_opts)

    assert {:ok, receipt} = Transfer.apply_transfer(second, ctx.target_opts)
    stop_supervised!(ctx.target)

    start_supervised!(
      Supervisor.child_spec({Store, name: ctx.target, path: Path.join(ctx.root, "target-store")},
        id: ctx.target
      )
    )

    assert {:ok, ^receipt} =
             Transfer.status(@profile, "mutation-2", "local", "node-target", ctx.target_opts)

    stop_supervised!(ctx.source)

    start_supervised!(
      Supervisor.child_spec({Store, name: ctx.source, path: Path.join(ctx.root, "source-store")},
        id: ctx.source
      )
    )

    assert {:ok, ^second} =
             Transfer.snapshot(@profile, "mutation-2", "local", "node-target", ctx.source_opts)
  end

  test "post-dispatch collisions leave exact old state and pending operation, never replay",
       ctx do
    source = doc(ctx.source_home, "collision", "Incoming fact.")
    selected = doc(ctx.target_home, "old", "Old selected fact.")

    imported_id =
      "mem_transfer_" <>
        sha(@profile <> "\0" <> sha(Path.expand(ctx.target_home)) <> "\0" <> source.doc_id)

    foreign = %{
      selected
      | doc_id: imported_id,
        agent_id: "lb-bob",
        answer_summary: "Foreign protected fact."
    }

    :ok = Store.put_sync(ctx.source, source)
    for record <- [selected, foreign], do: :ok = Store.put_sync(ctx.target, record)
    File.write!(Path.join(ctx.source_home, "USER.md"), "Incoming preference.\n")
    File.write!(Path.join(ctx.target_home, "USER.md"), "Old preference.\n")
    assert {:ok, envelope} = prepare(ctx)
    assert {:ok, preview} = Transfer.preview(envelope, ctx.target_opts)

    assert {:error, :transfer_pending} =
             Transfer.apply_transfer(confirm(envelope, preview), ctx.target_opts)

    assert {:ok, ^selected} = Store.get_document(ctx.target, selected.doc_id)
    assert {:ok, ^foreign} = Store.get_document(ctx.target, foreign.doc_id)
    assert File.read!(Path.join(ctx.target_home, "USER.md")) == "Old preference.\n"

    assert {:error, :transfer_pending} =
             Transfer.status(@profile, "mutation-1", "local", "node-target", ctx.target_opts)

    assert {:error, :transfer_pending} =
             Transfer.apply_transfer(confirm(envelope, preview), ctx.target_opts)
  end

  test "foreign destination record with identical source id is untouched", ctx do
    source = doc(ctx.source_home, "same-id", "Incoming saved fact.")

    foreign = %{
      source
      | agent_id: "lb-bob",
        answer_summary: "Bob's saved fact.",
        meta: %{"home_digest" => sha("bob-home")}
    }

    :ok = Store.put_sync(ctx.source, source)
    :ok = Store.put_sync(ctx.target, foreign)
    assert {:ok, envelope} = prepare(ctx)
    assert {:ok, _} = Transfer.apply_transfer(envelope, ctx.target_opts)
    assert {:ok, untouched} = Store.get_document(ctx.target, foreign.doc_id)
    assert untouched.agent_id == "lb-bob"
    assert untouched.answer_summary == "Bob's saved fact."
    assert untouched.meta == foreign.meta
    assert {:ok, [imported]} = Store.list_agent_recent(ctx.target, @profile, limit: 500)
    refute imported.doc_id == foreign.doc_id
    assert imported.answer_summary == source.answer_summary

    changed =
      put_in(
        envelope,
        ["snapshot", "documents", Access.at(0), "answerSummary"],
        "Different fact."
      )
      |> rehash()

    assert {:error, :transfer_conflict} = Transfer.apply_transfer(changed, ctx.target_opts)
  end

  test "unsafe old destination memory can be explicitly replaced without exporting it", ctx do
    File.write!(Path.join(ctx.target_home, "USER.md"), "password=hunter2")
    assert {:ok, envelope} = prepare(ctx)
    assert {:ok, preview} = Transfer.preview(envelope, ctx.target_opts)
    refute Jason.encode!(preview) =~ "hunter2"
    assert {:ok, _} = Transfer.apply_transfer(confirm(envelope, preview), ctx.target_opts)
    refute File.exists?(Path.join(ctx.target_home, "USER.md"))
  end

  test "partial preference publication rolls back rows and exact old bytes without a receipt",
       ctx do
    previous = %{"USER.md" => "Old user.\n", "MEMORY.md" => "Old memory.\n"}
    incoming = %{"USER.md" => "New user.\n", "MEMORY.md" => "New memory.\n"}
    for {name, text} <- previous, do: File.write!(Path.join(ctx.target_home, name), text)
    old = doc(ctx.target_home, "rollback-old", "Old fact.")
    new = doc(ctx.target_home, "rollback-new", "New fact.")
    :ok = Store.put_sync(ctx.target, old)
    assert {:ok, envelope} = prepare(ctx)
    binding = Map.delete(envelope, "snapshot")
    intent = %{"binding" => binding, "state" => "pending"}

    completed = %{
      "binding" => binding,
      "state" => "complete",
      "receipt" => Map.put(binding, "copied", true)
    }

    assert {:ok, _} = Store.transfer_put_new(ctx.target, "filesystem-rollback", intent)
    assert {:ok, stage} = Preferences.transfer_stage(ctx.target_home, incoming, previous)
    File.rm!(Path.join(stage.dir, "MEMORY.md.new"))

    assert {:error, :memory_unavailable} =
             Store.transfer_import(
               ctx.target,
               @profile,
               sha(Path.expand(ctx.target_home)),
               Store.transfer_revisions([old]),
               [new],
               "filesystem-rollback",
               completed,
               fn -> Preferences.transfer_publish(stage) end,
               boundary: fn run -> Preferences.transfer_locked(ctx.target_home, run) end,
               rollback: fn -> Preferences.transfer_restore(stage) end
             )

    assert {:ok, ^previous} = Preferences.transfer_snapshot(ctx.target_home)
    Preferences.transfer_cleanup(stage)
    assert {:ok, ^old} = Store.get_document(ctx.target, old.doc_id)
    assert {:error, :not_found} = Store.get_document(ctx.target, new.doc_id)
    assert {:ok, ^intent} = Store.transfer_get(ctx.target, "filesystem-rollback")
  end

  test "runtime namespaces and stored atom provenance transfer faithfully as safe JSON", ctx do
    metadata = %{
      home_digest: sha(Path.expand(ctx.source_home)),
      kind: :learned_source,
      source_digest: sha("learned source"),
      source_count: 2,
      source_text_redacted: true,
      source_provenance: [
        %{
          "type" => :file,
          "referenceDigest" => sha("file reference"),
          "contentDigest" => sha("file content"),
          "selectedItems" => 1,
          "selectedBytes" => 10,
          "redactionCount" => 0
        },
        %{
          type: :session,
          referenceDigest: sha("session reference"),
          contentDigest: sha("session content"),
          selectedItems: 2,
          selectedBytes: 20,
          redactionCount: 0
        }
      ]
    }

    source = %{
      doc(ctx.source_home, "labels", "Exact learned facts preserved.")
      | provider: "openrouter/provider",
        model: "anthropic/claude-sonnet",
        tools_used: ["mcp/lemon/工具"],
        session_key: "agent:lb-alice/project/主",
        run_id: "run/记录",
        meta: metadata
    }

    :ok = Store.put_sync(ctx.source, source)
    assert {:ok, stored} = Store.get_document(ctx.source, source.doc_id)
    assert stored.meta == metadata
    assert {:ok, envelope} = prepare(ctx)
    assert Jason.decode!(Jason.encode!(envelope)) == envelope
    [record] = envelope["snapshot"]["documents"]
    assert Enum.map(record["metadata"]["source_provenance"], & &1["type"]) == ["file", "session"]
    assert :ok = Transfer.validate(envelope, ctx.source_opts)

    for {field, invalid} <- [
          {"provider", "bad\nprovider"},
          {"model", "bad\u202Emodel"},
          {"sessionKey", "bad\nsession"},
          {"runId", "bad" <> <<0>>}
        ] do
      malformed =
        put_in(envelope, ["snapshot", "documents", Access.at(0), field], invalid) |> rehash()

      assert {:error, :invalid_snapshot} = Transfer.apply_transfer(malformed, ctx.target_opts)
    end

    assert {:ok, _} = Transfer.apply_transfer(envelope, ctx.target_opts)
    assert {:ok, [imported]} = Store.list_agent_recent(ctx.target, @profile, limit: 500)

    for field <- [:provider, :model, :tools_used, :session_key, :run_id, :answer_summary] do
      assert Map.fetch!(imported, field) == Map.fetch!(source, field)
    end

    assert imported.meta["source_provenance"] == record["metadata"]["source_provenance"]
    assert {:ok, ^stored} = Store.get_document(ctx.source, source.doc_id)
    conflicting = Map.merge(metadata, %{"kind" => "run"})
    :ok = Store.put_sync(ctx.source, %{source | meta: conflicting})

    assert {:error, :invalid_snapshot} =
             Transfer.prepare(
               @profile,
               "conflicting-metadata",
               "local",
               "node-target",
               ctx.source_opts
             )
  end

  test "Store owns publication lock even when requesting caller dies", ctx do
    previous = %{"USER.md" => nil, "MEMORY.md" => nil}
    incoming = %{"USER.md" => "Transferred saved preference.\n", "MEMORY.md" => nil}
    assert {:ok, stage} = Preferences.transfer_stage(ctx.target_home, incoming, previous)
    assert {:ok, envelope} = prepare(ctx)
    binding = Map.delete(envelope, "snapshot")
    intent = %{"binding" => binding, "state" => "pending"}

    completed = %{
      "binding" => binding,
      "state" => "complete",
      "receipt" => Map.put(binding, "copied", true)
    }

    assert {:ok, _} = Store.transfer_put_new(ctx.target, "caller-death", intent)
    imported = doc(ctx.target_home, "caller-death", "Transferred durable fact.")
    owner = self()

    {caller, monitor} =
      spawn_monitor(fn ->
        result =
          Store.transfer_import(
            ctx.target,
            @profile,
            sha(Path.expand(ctx.target_home)),
            [],
            [imported],
            "caller-death",
            completed,
            fn ->
              :ok = Preferences.transfer_publish(stage)
              send(owner, {:publication_active, self()})

              receive do
                :finish_publication -> :ok
              after
                5_000 -> {:error, :memory_unavailable}
              end
            end,
            boundary: fn run -> Preferences.transfer_locked(ctx.target_home, run) end,
            rollback: fn -> Preferences.transfer_restore(stage) end
          )

        send(owner, {:caller_result, result})
      end)

    assert_receive {:publication_active, store_process}, 1_000
    assert store_process == Process.whereis(ctx.target)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}, 1_000

    spawn(fn ->
      send(owner, :remember_attempt)

      send(
        owner,
        {:remember_result, Preferences.add(ctx.target_home, "user", "After publication note.")}
      )
    end)

    assert_receive :remember_attempt, 1_000
    refute_receive {:remember_result, _}, 50
    send(store_process, :finish_publication)
    assert_receive {:remember_result, {:ok, _}}, 1_000
    assert {:ok, ^completed} = Store.transfer_get(ctx.target, "caller-death")
    assert {:ok, ^imported} = Store.get_document(ctx.target, imported.doc_id)
    text = File.read!(Path.join(ctx.target_home, "USER.md"))
    assert text =~ incoming["USER.md"]
    assert text =~ "After publication note."
    refute_received {:caller_result, _}
    Preferences.transfer_cleanup(stage)
  end

  test "public inspection reads unknown, pending and completed states without any effects", ctx do
    journal_key = "destination:" <> sha(@profile <> "\0mutation-1")
    old = doc(ctx.target_home, "inspection", "Existing destination fact.")
    :ok = Store.put_sync(ctx.target, old)
    File.write!(Path.join(ctx.target_home, "USER.md"), "Existing destination preference.\n")

    unknown = %{
      "profileId" => @profile,
      "mutationId" => "mutation-1",
      "nodeId" => "node-target",
      "sourceNodeId" => nil,
      "snapshotDigest" => nil,
      "status" => "unknown",
      "receipt" => nil
    }

    assert {:error, :not_found} = Store.transfer_get(ctx.target, journal_key)

    assert {:ok, ^unknown} =
             Transfer.inspect_status(@profile, "mutation-1", "node-target", ctx.target_opts)

    assert {:error, :not_found} = Store.transfer_get(ctx.target, journal_key)
    assert {:ok, ^old} = Store.get_document(ctx.target, old.doc_id)

    assert File.read!(Path.join(ctx.target_home, "USER.md")) ==
             "Existing destination preference.\n"

    assert {:ok, envelope} =
             Transfer.prepare(
               @profile,
               "mutation-1",
               "node-source",
               "node-target",
               ctx.source_opts
             )

    intent = %{
      "binding" => Map.delete(envelope, "snapshot"),
      "state" => "pending",
      "destinationHomeDigest" => sha(Path.expand(ctx.target_home))
    }

    assert {:ok, ^intent} = Store.transfer_put_new(ctx.target, journal_key, intent)

    pending = %{
      unknown
      | "sourceNodeId" => "node-source",
        "snapshotDigest" => envelope["snapshotDigest"],
        "status" => "pending"
    }

    assert {:ok, ^pending} =
             Transfer.inspect_status(@profile, "mutation-1", "node-target", ctx.target_opts)

    assert {:ok, ^intent} = Store.transfer_get(ctx.target, journal_key)
    assert {:ok, ^old} = Store.get_document(ctx.target, old.doc_id)

    assert File.read!(Path.join(ctx.target_home, "USER.md")) ==
             "Existing destination preference.\n"

    assert {:error, :node_mismatch} =
             Transfer.inspect_status(@profile, "mutation-1", "node-other", ctx.target_opts)

    assert {:error, :transfer_conflict} =
             Transfer.inspect_status(
               @profile,
               "mutation-1",
               "node-other",
               Keyword.put(ctx.target_opts, :node_id, "node-other")
             )

    wrong_home_opts =
      Keyword.put(ctx.target_opts, :profile_opts,
        home_state_dir: Path.join(ctx.root, "wrong-state")
      )

    wrong_home = home(wrong_home_opts)
    refute File.exists?(wrong_home)

    assert {:error, :transfer_conflict} =
             Transfer.inspect_status(@profile, "mutation-1", "node-target", wrong_home_opts)

    refute File.exists?(wrong_home)

    assert {:error, :memory_unavailable} =
             Transfer.inspect_status(
               @profile,
               "mutation-1",
               "node-target",
               Keyword.put(ctx.target_opts, :store, :missing_transfer_inspection_store)
             )

    assert {:ok, final_envelope} =
             Transfer.prepare(
               @profile,
               "completed-inspection",
               "node-source",
               "node-target",
               ctx.source_opts
             )

    assert {:ok, preview} = Transfer.preview(final_envelope, ctx.target_opts)

    assert {:ok, receipt} =
             Transfer.apply_transfer(confirm(final_envelope, preview), ctx.target_opts)

    final_key = "destination:" <> sha(@profile <> "\0completed-inspection")
    assert {:ok, complete_entry} = Store.transfer_get(ctx.target, final_key)

    completed = %{
      "profileId" => @profile,
      "mutationId" => "completed-inspection",
      "nodeId" => "node-target",
      "sourceNodeId" => "node-source",
      "snapshotDigest" => final_envelope["snapshotDigest"],
      "status" => "completed",
      "receipt" => receipt
    }

    assert {:ok, ^completed} =
             Transfer.inspect_status(
               @profile,
               "completed-inspection",
               "node-target",
               ctx.target_opts
             )

    assert {:ok, ^complete_entry} = Store.transfer_get(ctx.target, final_key)
    assert {:error, :not_found} = Store.get_document(ctx.target, old.doc_id)
    refute File.exists?(Path.join(ctx.target_home, "USER.md"))
  end

  test "public inspection rejects malformed receipts and crossprofile journal bindings", ctx do
    assert {:ok, envelope} =
             Transfer.prepare(
               @profile,
               "inspect-invalid",
               "node-source",
               "node-target",
               ctx.source_opts
             )

    binding = Map.delete(envelope, "snapshot")

    entry = %{
      "binding" => binding,
      "state" => "complete",
      "destinationHomeDigest" => sha(Path.expand(ctx.target_home)),
      "receipt" => Map.put(binding, "copied", false)
    }

    journal_key = "destination:" <> sha(@profile <> "\0inspect-invalid")
    assert {:ok, ^entry} = Store.transfer_put_new(ctx.target, journal_key, entry)

    assert {:error, :memory_unavailable} =
             Transfer.inspect_status(@profile, "inspect-invalid", "node-target", ctx.target_opts)

    assert {:ok, ^entry} = Store.transfer_get(ctx.target, journal_key)
    cross_key = "destination:" <> sha(@profile <> "\0inspect-crossprofile")

    cross = %{
      entry
      | "binding" => %{binding | "profileId" => "lb-bob", "mutationId" => "inspect-crossprofile"}
    }

    assert {:ok, ^cross} = Store.transfer_put_new(ctx.target, cross_key, cross)

    assert {:error, :transfer_conflict} =
             Transfer.inspect_status(
               @profile,
               "inspect-crossprofile",
               "node-target",
               ctx.target_opts
             )

    assert {:ok, ^cross} = Store.transfer_get(ctx.target, cross_key)
  end

  test "private actor keys and canonical shared preferences survive transfer without promoting legacy files",
       ctx do
    a = %{
      agent_id: @profile,
      cwd: ctx.source_home,
      workspace_dir: ctx.source_home,
      session_scope: :main,
      session_key: "agent:lb-alice:main",
      invocation_context_key: "epoch-1",
      memory_context_key: "actor-a",
      memory_context_verified: true
    }

    b = %{a | memory_context_key: "actor-b"}
    shared = Map.put(a, :shared_memory_grant, true)

    assert {:ok, _} =
             LemonMemory.Preferences.remember(a, "user", "Private amber preference.", nil,
               store: ctx.source
             )

    assert {:ok, _} =
             LemonMemory.Preferences.remember(b, "user", "Private cobalt preference.", nil,
               store: ctx.source
             )

    assert {:ok, _} =
             LemonMemory.Preferences.remember(shared, "user", "Shared citrus preference.", nil,
               store: ctx.source
             )

    assert {:ok, _} = Project.remember(a, "Private amber build command.", nil, store: ctx.source)
    assert {:ok, _} = Project.remember(b, "Private cobalt build command.", nil, store: ctx.source)

    assert {:ok, _} =
             Project.remember(shared, "Shared citrus build command.", nil, store: ctx.source)

    File.write!(Path.join(ctx.source_home, "USER.md"), "Unknown legacy lilac preference.\n")
    assert {:ok, envelope} = prepare(ctx)
    assert length(envelope["snapshot"]["documents"]) == 6
    assert {:ok, _receipt} = Transfer.apply_transfer(envelope, ctx.target_opts)

    destination_a = %{
      a
      | cwd: ctx.target_home,
        workspace_dir: ctx.target_home,
        invocation_context_key: "epoch-2"
    }

    destination_b = %{
      b
      | cwd: ctx.target_home,
        workspace_dir: ctx.target_home,
        invocation_context_key: "epoch-2"
    }

    assert {:ok, a_notes} = LemonMemory.Preferences.read(destination_a, store: ctx.target)
    assert Enum.sort(a_notes) == ["Private amber preference.", "Shared citrus preference."]
    assert {:ok, b_notes} = LemonMemory.Preferences.read(destination_b, store: ctx.target)
    assert Enum.sort(b_notes) == ["Private cobalt preference.", "Shared citrus preference."]
    assert {:ok, a_project} = Project.read(destination_a, store: ctx.target)

    assert Enum.sort(a_project) == [
             "Private amber build command.",
             "Shared citrus build command."
           ]

    assert {:ok, b_project} = Project.read(destination_b, store: ctx.target)

    assert Enum.sort(b_project) == [
             "Private cobalt build command.",
             "Shared citrus build command."
           ]

    assert {:ok, files} =
             LemonMemory.Preferences.shared_bootstrap(destination_a, store: ctx.target)

    assert files["USER.md"] =~ "Shared citrus preference."
    refute files["USER.md"] =~ "lilac"
    refute files["USER.md"] =~ "amber"

    assert File.read!(Path.join(ctx.target_home, "USER.md")) ==
             "Unknown legacy lilac preference.\n"

    assert {:ok, %{changed: true}} =
             LemonMemory.Preferences.remember(
               destination_a,
               "user",
               "Private amber corrected preference.",
               "Private amber preference.", store: ctx.target)

    assert {:ok, ^b_notes} = LemonMemory.Preferences.read(destination_b, store: ctx.target)
  end

  test "moving pre-index proof claims preserves bytes but cannot create new private or shared authority",
       ctx do
    metadata = %{
      "home_digest" => sha(Path.expand(ctx.source_home)),
      "kind" => "user",
      "memory_scope" => "shared",
      "memory_shared_verified" => true,
      "preference_facts" => ["Retained unproven orchid preference."]
    }

    retained = %{
      doc(ctx.source_home, "claimed-shared", "Retained unproven orchid preference.")
      | meta: metadata
    }

    source = legacy_store(ctx.root, retained)
    source_opts = Keyword.put(ctx.source_opts, :store, source)
    assert {:ok, stored} = Store.get_document(source, retained.doc_id)
    assert Store.document_ownership(stored) == :unproven

    assert {:ok, envelope} =
             Transfer.prepare(@profile, "mutation-1", "local", "node-target", source_opts)

    assert [record] = envelope["snapshot"]["documents"]
    assert record["metadata"]["memory_scope"] == "unproven"
    refute Map.has_key?(record["metadata"], "memory_shared_verified")
    assert record["metadata"]["preference_facts"] == metadata["preference_facts"]
    assert {:ok, _} = Transfer.apply_transfer(envelope, ctx.target_opts)
    assert {:ok, [imported]} = Store.list_agent_recent(ctx.target, @profile, limit: 500)
    assert Store.document_ownership(imported) == :unproven
    assert imported.answer_summary == retained.answer_summary

    target = %{
      agent_id: @profile,
      cwd: ctx.target_home,
      workspace_dir: ctx.target_home,
      session_scope: :main,
      invocation_context_key: "epoch-2",
      memory_context_key: "actor-a",
      memory_context_verified: true
    }

    assert {:ok, []} = LemonMemory.Preferences.read(target, store: ctx.target)

    assert {:ok, %{"items" => []}} =
             LemonSkills.ProfileMemory.execute(
               "list",
               @profile,
               %{"memoryScope" => "shared"},
               ctx.target_opts
             )

    assert {:ok, ^stored} = Store.get_document(source, retained.doc_id)
  end

  defp legacy_store(root, doc) do
    alias Exqlite.Sqlite3
    path = Path.join(root, "legacy-source-store")
    File.mkdir_p!(path)
    {:ok, conn} = Sqlite3.open(Path.join(path, "memory.sqlite3"))

    :ok =
      Sqlite3.execute(conn, """
      CREATE TABLE memory_documents (
        doc_id TEXT PRIMARY KEY, run_id TEXT NOT NULL, session_key TEXT NOT NULL,
        agent_id TEXT NOT NULL, workspace_key TEXT, scope TEXT NOT NULL,
        started_at_ms INTEGER NOT NULL, ingested_at_ms INTEGER NOT NULL,
        prompt_summary TEXT NOT NULL, answer_summary TEXT NOT NULL,
        tools_used_blob BLOB NOT NULL, provider TEXT, model TEXT, outcome TEXT NOT NULL,
        meta_blob BLOB NOT NULL
      )
      """)

    {:ok, statement} =
      Sqlite3.prepare(
        conn,
        "INSERT INTO memory_documents VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)"
      )

    :ok =
      Sqlite3.bind(statement, [
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
        {:blob, :erlang.term_to_binary(doc.tools_used)},
        doc.provider,
        doc.model,
        Atom.to_string(doc.outcome),
        {:blob, :erlang.term_to_binary(doc.meta)}
      ])

    assert :done = Sqlite3.step(conn, statement)
    :ok = Sqlite3.release(conn, statement)
    :ok = Sqlite3.close(conn)
    name = :"legacy_transfer_#{System.unique_integer([:positive])}"
    start_supervised!(Supervisor.child_spec({Store, name: name, path: path}, id: name))
    name
  end

  defp start_store(root, role) do
    name = :"memory_transfer_#{role}_#{System.unique_integer([:positive])}"

    start_supervised!(
      Supervisor.child_spec({Store, name: name, path: Path.join(root, role <> "-store")},
        id: name
      )
    )

    name
  end

  defp home(opts) do
    {:ok, paths} = ProfileStore.paths(@profile, Keyword.fetch!(opts, :profile_opts))
    paths["workspace"]
  end

  defp prepare(ctx),
    do: Transfer.prepare(@profile, "mutation-1", "local", "node-target", ctx.source_opts)

  defp confirm(envelope, preview),
    do: Map.merge(envelope, Map.take(preview, ~w(confirmationToken destinationDigest)))

  defp rehash(envelope),
    do: Map.put(envelope, "snapshotDigest", sha(canonical(envelope["snapshot"])))

  defp doc(home, id, answer),
    do:
      %Document{
        doc_id: "mem_" <> id,
        run_id: "run-" <> id,
        session_key: "agent:lb-alice:main",
        agent_id: @profile,
        workspace_key: home,
        prompt_summary: "Saved memory summary",
        answer_summary: answer,
        started_at_ms: 1,
        ingested_at_ms: System.system_time(:millisecond),
        meta: %{"home_digest" => sha(Path.expand(home)), "local_path" => home}
      }
      |> Document.with_index()

  defp canonical(value) when is_map(value),
    do:
      "{" <>
        (value
         |> Enum.sort_by(&elem(&1, 0))
         |> Enum.map_join(",", fn {k, v} -> Jason.encode!(k) <> ":" <> canonical(v) end)) <> "}"

  defp canonical(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &canonical/1) <> "]"

  defp canonical(value), do: Jason.encode!(value)
  defp sha(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
