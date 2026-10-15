defmodule LemonMemory.SessionScrollTest do
  use ExUnit.Case, async: false
  alias LemonMemory.{ContextScope, Document, Project, SessionSearch, Store}
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous = System.get_env("LEMON_FEATURE_SESSION_SEARCH")
    System.put_env("LEMON_FEATURE_SESSION_SEARCH", "on")

    on_exit(fn ->
      if previous,
        do: System.put_env("LEMON_FEATURE_SESSION_SEARCH", previous),
        else: System.delete_env("LEMON_FEATURE_SESSION_SEARCH")
    end)

    name = :"scroll_#{System.unique_integer([:positive])}"
    start_supervised!({Store, name: name, path: Path.join(dir, "store")})
    File.mkdir_p!(Path.join(dir, "repo/.git"))

    context = %{
      agent_id: "coding",
      workspace_dir: Path.join(dir, "home"),
      cwd: Path.join(dir, "repo"),
      session_scope: :main,
      memory_context_key: "owner-a",
      invocation_context_key: "epoch-a",
      memory_context_verified: true
    }

    {:ok, identity} = Project.scope(context)

    for {owner, agent, home, session} <- [
          {"owner-a", "coding", identity.home_digest, "mine"},
          {"owner-b", "coding", identity.home_digest, "foreign"},
          {"owner-a", "other", identity.home_digest, "other-agent"},
          {"owner-a", "coding", "other-home", "other-profile"}
        ],
        n <- 1..30 do
      doc =
        Document.new(
          doc_id: "#{session}-#{n}",
          run_id: "run-#{session}-#{n}",
          session_key: session,
          agent_id: agent,
          workspace_key: context.cwd,
          started_at_ms: n,
          ingested_at_ms: n,
          prompt_summary: String.duplicate("p", 2000),
          answer_summary: String.duplicate("a", 2000),
          meta: Map.put(ContextScope.metadata({:private, owner}), "home_digest", home)
        )

      assert :ok = Store.put_sync(name, doc)
    end

    %{context: context, store: name}
  end

  test "owned SQL window centers anchor before limiting and excludes foreign sessions", %{
    context: context,
    store: store
  } do
    {:ok, identity} = Project.scope(context)

    assert {:ok, rows} =
             Store.history_window(store, "coding", identity.home_digest, {:private, "owner-a"},
               session: "mine",
               around: "mine-15",
               limit: 5
             )

    assert rows |> Enum.map(fn {doc, _} -> doc.started_at_ms end) |> Enum.sort() == [
             13,
             14,
             15,
             16,
             17
           ]

    assert {:ok, [{doc, 30}]} =
             Store.history_window(store, "coding", identity.home_digest, {:private, "owner-a"},
               limit: 5
             )

    assert doc.session_key == "mine"

    for session <- ["foreign", "other-agent", "other-profile"] do
      assert {:ok, []} =
               Store.history_window(store, "coding", identity.home_digest, {:private, "owner-a"},
                 session: session,
                 limit: 5
               )
    end
  end

  test "feature policy gates browse and scroll", %{context: context, store: store} do
    System.put_env("LEMON_FEATURE_SESSION_SEARCH", "off")
    refute SessionSearch.enabled?()
    assert {:ok, []} = SessionSearch.session(context, "mine", store: store)
    assert {:ok, []} = SessionSearch.recent_sessions(context, store: store)
  end

  test "browse and scroll require the same proven private owner as history search", %{
    context: context,
    store: store
  } do
    legacy =
      Map.drop(context, [:memory_context_key, :invocation_context_key, :memory_context_verified])

    unproven = %{context | memory_context_verified: false}
    partial = Map.delete(context, :invocation_context_key)

    for rejected <- [legacy, unproven, partial] do
      assert {:error, :unproven_context} =
               Project.search_history(rejected, "prompt", :agent, store: store)

      assert {:error, :unproven_context} = SessionSearch.session(rejected, "mine", store: store)
      assert {:error, :unproven_context} = SessionSearch.recent_sessions(rejected, store: store)
    end
  end

  test "public scroll refuses subagents", %{context: context} do
    assert {:error, _} = SessionSearch.session(%{context | session_scope: :subagent}, "mine")
    assert {:error, _} = SessionSearch.recent_sessions(%{context | session_scope: :subagent})
  end

  test "public window is ordered and bounded when feature enabled", %{
    context: context,
    store: store
  } do
    assert SessionSearch.enabled?()

    assert {:ok, docs} =
             SessionSearch.session(context, "mine", store: store, around: "mine-15", window: 5)

    assert Enum.map(docs, & &1.started_at_ms) == [13, 14, 15, 16, 17]
    assert {:ok, docs} = SessionSearch.session(context, "mine", store: store, window: 999)
    assert length(docs) == 20
    assert Enum.all?(docs, &(byte_size(&1.prompt_summary) <= 1024))

    assert {:ok, [%{session: "mine", run_count: 30}]} =
             SessionSearch.recent_sessions(context, store: store)

    assert {:ok, []} = SessionSearch.session(context, "mine", store: store, around: "foreign-15")

    for session <- ["foreign", "other-agent", "other-profile"] do
      assert {:ok, []} = SessionSearch.session(context, session, store: store)
    end

    assert byte_size(SessionSearch.format_results(docs)) <= 65_536
  end
end
