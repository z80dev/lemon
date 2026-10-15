defmodule LemonSkills.TimelineTest do
  use ExUnit.Case, async: false

  alias LemonMemory.{ContextScope, Document, Store}
  alias LemonSkills.{Timeline, Usage}

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    store = :"timeline_#{System.unique_integer([:positive])}"
    start_supervised!({Store, name: store, path: Path.join(root, "store")})
    home = Path.join(root, "alice")
    File.mkdir_p!(home)
    context = %{agent_id: "alice", workspace_dir: home, cwd: root, session_scope: :main}
    %{store: store, context: context, home: home, opts: [server: store]}
  end

  test "orders current add/update events, includes project and source learning, excludes runs",
       ctx do
    for {id, kind, added, updated} <- [
          {"note", "memory", 100, 400},
          {"user", "user", 200, 200},
          {"project", "project_learning", 300, 300},
          {"source", "learned_source", 350, 350},
          {"run", "run", 500, 500}
        ] do
      put(ctx, id, kind, added, updated)
    end

    assert {:ok, %{"items" => items, "history" => "current_state"}} =
             Timeline.list(ctx.context, ctx.opts)

    assert Enum.map(items, &{&1["at"], &1["kind"], &1["action"]}) == [
             {400, "memory", "updated"},
             {350, "memory", "added"},
             {300, "project", "added"},
             {200, "user", "added"},
             {100, "memory", "added"}
           ]

    assert {:ok, %{"items" => [project]}} =
             Timeline.list(ctx.context, ctx.opts ++ [kind: "project"])

    assert project["at"] == 300
  end

  test "scopes by both home and agent and refuses subagents", ctx do
    put(ctx, "owned", "memory", 1, 1)
    put(ctx, "other_agent", "memory", 2, 2, agent_id: "bob")

    put(ctx, "other_home", "memory", 3, 3,
      meta: %{"kind" => "memory", "home_digest" => digest("other")}
    )

    assert {:ok, %{"items" => [item]}} = Timeline.list(ctx.context, ctx.opts)
    assert item["at"] == 1

    assert {:error, :subagent} =
             Timeline.list(%{ctx.context | session_scope: :subagent}, ctx.opts)

    assert {:error, :unscoped} = Timeline.list(%{}, ctx.opts)
  end

  test "explicit private selection never widens into shared, workspace or skill state", ctx do
    for {id, owner} <- [
          {"own", {:private, "key-a"}},
          {"foreign", {:private, "key-b"}},
          {"shared", :shared}
        ] do
      meta =
        Map.merge(
          %{"kind" => "memory", "home_digest" => digest(ctx.home)},
          ContextScope.metadata(owner)
        )

      put(ctx, id, "memory", 1, 1, meta: meta)
    end

    File.write!(Path.join(ctx.home, "MEMORY.md"), "# Memory\n\n- Workspace only\n")

    sidecar(ctx, "skills.usage.json", "skills", %{
      "example" => %{"created_at" => "2026-01-01T00:00:00Z"}
    })

    assert {:ok, %{"items" => [item]}} =
             Timeline.list(ctx.context, ctx.opts ++ [memory_scope: {:private, "key-a"}])

    assert item["kind"] == "memory"
    assert String.starts_with?(item["id"], "durable_")
  end

  test "redacts and truncates current untrusted previews and preserves valid UTF8", ctx do
    text =
      "<img src=x onerror=alert(1)> api_key=sk-test-abcdefghijklmnop https://private.example/a /Users/alice/private " <>
        String.duplicate("界", 300)

    put(ctx, "unsafe", "learned_source", 1, 1, answer_summary: text)
    assert {:ok, %{"items" => [item]}} = Timeline.list(ctx.context, ctx.opts)
    assert item["preview"] =~ "<img"
    refute item["preview"] =~ "sk-test"
    refute item["preview"] =~ "private.example"
    refute item["preview"] =~ "/Users/alice"
    assert String.valid?(item["preview"])
    assert byte_size(item["preview"]) <= 320
  end

  test "skill sidecars use real timestamps, filter foreign writers and do not scan cwd", ctx do
    stamp = "2026-01-01T00:00:00Z"

    sidecar(ctx, "skills.usage.json", "skills", %{
      "own" => %{
        "created_at" => stamp,
        "created_by_agent_id" => "alice",
        "last_write_at" => stamp,
        "last_writer_agent_id" => "alice",
        "last_action" => "patch",
        "last_write_result" => "ok",
        "last_loaded_at" => stamp,
        "last_loaded_by_agent_id" => "alice",
        "state_updated_at" => stamp,
        "lifecycle_state" => "pinned"
      },
      "foreign" => %{
        "created_at" => stamp,
        "created_by_agent_id" => "bob",
        "last_write_at" => stamp,
        "last_writer_agent_id" => "bob"
      },
      "failed" => %{
        "last_write_at" => stamp,
        "last_action" => "patch",
        "last_write_result" => "error"
      }
    })

    sidecar(ctx, "skills.lock.json", "skills", %{"installed" => %{"installed_at" => stamp}})
    sidecar(ctx, "skills.audit.json", "records", %{"skill:installed" => %{"scanned_at" => stamp}})
    dir = Path.join([ctx.home, ".lemon", "skill_drafts", "draft-one"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".draft_meta.json"), Jason.encode!(%{"created_at" => stamp}))
    assert {:ok, %{"items" => events}} = Timeline.list(ctx.context, ctx.opts)

    assert Enum.sort(Enum.map(events, & &1["action"])) ==
             ~w(audited created drafted installed loaded patched pinned)

    refute Enum.any?(events, &(&1["id"] in ["foreign", "failed"]))
    other = %{ctx.context | workspace_dir: Path.join(ctx.home, "other")}
    assert {:ok, %{"items" => []}} = Timeline.list(other, ctx.opts)
  end

  test "global skills require exact agent attribution and drafts require owned source memory",
       ctx do
    agent_dir = Path.join(ctx.home, "global-agent")
    old = System.get_env("LEMON_AGENT_DIR")
    System.put_env("LEMON_AGENT_DIR", agent_dir)

    on_exit(fn ->
      if old,
        do: System.put_env("LEMON_AGENT_DIR", old),
        else: System.delete_env("LEMON_AGENT_DIR")
    end)

    File.mkdir_p!(agent_dir)
    stamp = "2026-01-01T00:00:00Z"

    File.write!(
      Path.join(agent_dir, "skills.usage.json"),
      Jason.encode!(%{
        "skills" => %{
          "own" => %{"created_at" => stamp, "created_by_agent_id" => "default"},
          "foreign" => %{"created_at" => stamp, "created_by_agent_id" => "alice"},
          "unknown" => %{"created_at" => stamp}
        }
      })
    )

    File.write!(
      Path.join(agent_dir, "skills.lock.json"),
      Jason.encode!(%{
        "skills" => %{
          "own" => %{"installed_at" => stamp},
          "foreign" => %{"installed_at" => stamp},
          "unknown" => %{"installed_at" => stamp}
        }
      })
    )

    home = Path.join(agent_dir, "workspace")
    File.mkdir_p!(home)
    default = %{ctx.context | agent_id: "default", workspace_dir: home}
    put(%{ctx | home: home}, "source", "learned_source", 1, 1, agent_id: "default")

    for {key, source} <- [{"owned-draft", "mem_source"}, {"foreign-draft", "mem_foreign"}] do
      dir = Path.join([agent_dir, "skill_drafts", key])
      File.mkdir_p!(dir)

      File.write!(
        Path.join(dir, ".draft_meta.json"),
        Jason.encode!(%{"created_at" => stamp, "source_doc_id" => source})
      )
    end

    assert {:ok, %{"items" => items}} = Timeline.list(default, ctx.opts ++ [kind: "skill"])

    assert Enum.sort(Enum.map(items, &{&1["id"], &1["action"]})) ==
             [{"draft:owned-draft", "drafted"}, {"own", "created"}, {"own", "installed"}]

    assert {:ok, %{"items" => []}} = Timeline.list(ctx.context, ctx.opts)
  end

  test "skill sidecar and draft symlinks cannot cross a profile boundary", ctx do
    foreign = Path.join(ctx.home, "foreign.json")

    File.write!(
      foreign,
      Jason.encode!(%{"skills" => %{"secret" => %{"created_at" => "2026-01-01T00:00:00Z"}}})
    )

    File.mkdir_p!(Path.join(ctx.home, ".lemon"))
    File.ln_s!(foreign, Usage.usage_file(scope: :project, cwd: ctx.home))
    assert {:error, :timeline_unavailable} = Timeline.list(ctx.context, ctx.opts)
  end

  test "enforces event, sidecar byte and record bounds and reports read failures", ctx do
    for n <- 1..120, do: put(ctx, "n#{n}", "memory", n, n)
    assert {:ok, %{"items" => events}} = Timeline.list(ctx.context, ctx.opts ++ [limit: 100])
    assert length(events) == 100
    assert hd(events)["at"] == 120
    assert {:ok, %{"items" => [_]}} = Timeline.list(ctx.context, ctx.opts ++ [limit: 1])
    assert {:error, :invalid_options} = Timeline.list(ctx.context, ctx.opts ++ [limit: 101])
    assert {:error, :invalid_options} = Timeline.list(ctx.context, ctx.opts ++ [kind: "run"])
    sidecar(ctx, "skills.usage.json", "skills", Map.new(1..201, &{"s#{&1}", %{}}))
    assert {:error, :timeline_unavailable} = Timeline.list(ctx.context, ctx.opts)

    File.write!(
      Usage.usage_file(scope: :project, cwd: ctx.home),
      String.duplicate(" ", 1_048_577)
    )

    assert {:error, :timeline_unavailable} = Timeline.list(ctx.context, ctx.opts)

    assert {:error, :memory_unavailable} =
             Timeline.list(ctx.context, server: :nonexistent_timeline_store)
  end

  defp put(ctx, id, kind, added, updated, overrides \\ []) do
    doc =
      Document.new(
        Keyword.merge(
          [
            doc_id: "mem_#{id}",
            agent_id: "alice",
            session_key: "agent:alice:main",
            answer_summary: "Saved learning #{id}",
            outcome: :success,
            started_at_ms: added,
            ingested_at_ms: updated,
            meta: %{
              "kind" => kind,
              "home_digest" => digest(ctx.home),
              "preference_facts" => ["Saved learning #{id}"]
            }
          ],
          overrides
        )
      )

    :ok = Store.put_sync(ctx.store, doc)
  end

  defp sidecar(ctx, file, field, records) do
    dir = Path.join(ctx.home, ".lemon")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, file), Jason.encode!(%{field => records}))
  end

  defp digest(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
end
