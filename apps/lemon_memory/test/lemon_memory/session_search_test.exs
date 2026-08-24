defmodule LemonMemory.SessionSearchTest do
  @moduledoc """
  Direct tests for the public search façade.

  Everything here is driven through `LemonMemory.SessionSearch` itself against
  an isolated, seeded `LemonMemory.Store` reached through the built-in local
  provider, so the assertions describe what consumers (`search_memory`,
  `session_search`) actually observe: the feature gate and its kill switch, the
  blank-query and limit contracts, scope isolation, and the rendering injected
  into an agent's context.
  """

  use ExUnit.Case, async: false

  alias LemonMemory.Document
  alias LemonMemory.Providers.Local
  alias LemonMemory.SessionSearch
  alias LemonMemory.Store

  @moduletag :tmp_dir

  @flag_env "LEMON_FEATURE_SESSION_SEARCH"

  # Records the calls it receives and returns nothing, so a test can prove the
  # façade short-circuited before any provider ran.
  defmodule RecordingProvider do
    @behaviour LemonMemory.Provider

    @impl true
    def put(_doc, _opts), do: :ok

    @impl true
    def search(query, opts) do
      send(opts[:owner], {:provider_searched, query, opts[:limit]})
      []
    end
  end

  setup %{tmp_dir: tmp_dir} do
    # The env var beats both TOML layers, so the gate is pinned regardless of
    # whatever global/project config the suite runs under.
    previous_flag = System.get_env(@flag_env)
    System.put_env(@flag_env, "on")

    on_exit(fn ->
      case previous_flag do
        nil -> System.delete_env(@flag_env)
        value -> System.put_env(@flag_env, value)
      end
    end)

    store =
      start_supervised!(
        {Store,
         [
           name: :"session_search_store_#{System.unique_integer([:positive])}",
           path: tmp_dir,
           retention_ms: 30 * 24 * 3_600_000,
           max_per_scope: 100
         ]}
      )

    %{store: store, now: System.system_time(:millisecond)}
  end

  describe "search/2 feature gate" do
    test "the documented kill switch returns [] without reaching a provider" do
      System.put_env(@flag_env, "off")

      assert SessionSearch.search("deploy", recording_opts()) == []
      refute_received {:provider_searched, _query, _limit}
    end

    test "an opt-in rollout state does not activate search" do
      System.put_env(@flag_env, "opt-in")

      assert SessionSearch.search("deploy", recording_opts()) == []
      refute_received {:provider_searched, _query, _limit}
    end
  end

  describe "search/2 query handling" do
    test "blank queries short-circuit before any provider runs" do
      for blank <- ["", "   ", "\n\t"] do
        assert SessionSearch.search(blank, recording_opts()) == []
      end

      refute_received {:provider_searched, _query, _limit}
    end

    test "a non-blank query reaches the provider with the resolved limit" do
      assert SessionSearch.search("deploy", recording_opts()) == []
      assert_received {:provider_searched, "deploy", 5}
    end
  end

  describe "search/2 results" do
    test "returns matching documents newest first", %{store: store, now: now} do
      session = "agent:order:main"

      seed(store, [
        doc(session_key: session, ingested_at_ms: now - 30_000, prompt_summary: "deploy the api"),
        doc(session_key: session, ingested_at_ms: now, prompt_summary: "deploy the api again"),
        doc(session_key: session, ingested_at_ms: now - 10_000, prompt_summary: "deploy the docs")
      ])

      results = search(store, "deploy", scope: :session, scope_key: session, limit: 10)

      assert length(results) == 3
      assert Enum.map(results, & &1.ingested_at_ms) == [now, now - 10_000, now - 30_000]
    end

    test "documents that do not match the query are not returned", %{store: store} do
      session = "agent:miss:main"

      seed(store, [
        doc(session_key: session, prompt_summary: "fix the login bug", answer_summary: "fixed")
      ])

      assert search(store, "xyzzy quux", scope: :session, scope_key: session, limit: 10) == []
    end

    test "an empty store yields no results", %{store: store} do
      assert search(store, "deploy", scope: :session, scope_key: "agent:empty:main") == []
      assert search(store, "deploy", scope: :all) == []
    end
  end

  describe "search/2 limits" do
    test "returns at most the default 5 results, still ordered newest first", %{
      store: store,
      now: now
    } do
      session = "agent:default_limit:main"
      seed(store, matching_docs(8, session, now))

      results = search(store, "deploy", scope: :session, scope_key: session)

      assert length(results) == 5
      assert_newest_first(results)
    end

    test "a caller limit above the cap is clamped to 20", %{store: store, now: now} do
      session = "agent:capped:main"
      seed(store, matching_docs(22, session, now))

      assert length(search(store, "deploy", scope: :session, scope_key: session, limit: 100)) == 20
    end

    test "a caller limit below the cap is honoured", %{store: store, now: now} do
      session = "agent:small_limit:main"
      seed(store, matching_docs(8, session, now))

      assert length(search(store, "deploy", scope: :session, scope_key: session, limit: 2)) == 2
    end
  end

  describe "search/2 scoping" do
    test "the default scope is :session and other sessions do not leak", %{
      store: store,
      now: now
    } do
      mine = "agent:mine:main"
      theirs = "agent:theirs:main"

      seed(store, [
        doc(session_key: mine, ingested_at_ms: now, prompt_summary: "deploy the api"),
        doc(session_key: theirs, ingested_at_ms: now, prompt_summary: "deploy the api")
      ])

      results = search(store, "deploy", scope_key: mine, limit: 10)

      assert Enum.map(results, & &1.session_key) == [mine]
    end

    test ":agent scope spans that agent's sessions only", %{store: store, now: now} do
      seed(store, [
        doc(
          agent_id: "keeper",
          session_key: "agent:keeper:main",
          ingested_at_ms: now,
          prompt_summary: "deploy the api"
        ),
        doc(
          agent_id: "keeper",
          session_key: "agent:keeper:side",
          ingested_at_ms: now - 1_000,
          prompt_summary: "deploy the docs"
        ),
        doc(
          agent_id: "stranger",
          session_key: "agent:stranger:main",
          ingested_at_ms: now,
          prompt_summary: "deploy the api"
        )
      ])

      results = search(store, "deploy", scope: :agent, scope_key: "keeper", limit: 10)

      assert Enum.map(results, & &1.session_key) == ["agent:keeper:main", "agent:keeper:side"]
    end

    test ":workspace scope returns the workspace's documents across sessions", %{
      store: store,
      now: now
    } do
      workspace = "/ws/lemon"

      seed(store, [
        doc(
          session_key: "agent:one:main",
          workspace_key: workspace,
          scope: :workspace,
          ingested_at_ms: now,
          prompt_summary: "deploy the api"
        ),
        doc(
          session_key: "agent:two:main",
          workspace_key: workspace,
          scope: :workspace,
          ingested_at_ms: now - 1_000,
          prompt_summary: "deploy the docs"
        ),
        doc(
          session_key: "agent:three:main",
          workspace_key: "/ws/other",
          scope: :workspace,
          ingested_at_ms: now,
          prompt_summary: "deploy the api"
        )
      ])

      results = search(store, "deploy", scope: :workspace, scope_key: workspace, limit: 10)

      assert Enum.map(results, & &1.workspace_key) == [workspace, workspace]
    end

    test ":all scope needs no scope_key and spans sessions", %{store: store, now: now} do
      seed(store, [
        doc(session_key: "agent:a:main", ingested_at_ms: now, prompt_summary: "deploy the api"),
        doc(
          session_key: "agent:b:main",
          ingested_at_ms: now - 1_000,
          prompt_summary: "deploy the docs"
        )
      ])

      results = search(store, "deploy", scope: :all, limit: 10)

      assert Enum.map(results, & &1.session_key) == ["agent:a:main", "agent:b:main"]
    end

    test "a scoped search without a scope_key returns nothing instead of broadening", %{
      store: store,
      now: now
    } do
      seed(store, [
        doc(
          session_key: "agent:closed:main",
          agent_id: "closed",
          workspace_key: "/ws/closed",
          ingested_at_ms: now,
          prompt_summary: "deploy the api"
        )
      ])

      for scope <- [:session, :agent, :workspace] do
        assert search(store, "deploy", scope: scope, limit: 10) == [],
               "#{inspect(scope)} search without a scope_key must not broaden to all documents"
      end

      refute search(store, "deploy", scope: :all, limit: 10) == []
    end
  end

  describe "search/2 degradation" do
    test "an unavailable store degrades to [] rather than raising", %{store: store, now: now} do
      session = "agent:down:main"
      seed(store, [doc(session_key: session, ingested_at_ms: now)])

      :ok = GenServer.stop(store)

      assert search(store, "deploy", scope: :session, scope_key: session, limit: 10) == []
    end
  end

  describe "format_results/1" do
    test "an empty result set renders the no-match sentence" do
      assert SessionSearch.format_results([]) == "No matching memory documents found."
    end

    test "renders numbered entries in order with timestamp, session and summaries" do
      docs = [
        doc(
          session_key: "agent:fmt:main",
          # 2023-11-14 22:13 UTC
          ingested_at_ms: 1_700_000_000_000,
          prompt_summary: "fix the login bug",
          answer_summary: "swapped the token check"
        ),
        doc(
          session_key: "agent:fmt:side",
          ingested_at_ms: 1_700_000_060_000,
          prompt_summary: "deploy the api",
          answer_summary: "deployed"
        )
      ]

      assert SessionSearch.format_results(docs) ==
               """
               [1] 2023-11-14 22:13 UTC | session: agent:fmt:main
               Q: fix the login bug
               A: swapped the token check

               [2] 2023-11-14 22:14 UTC | session: agent:fmt:side
               Q: deploy the api
               A: deployed
               """
               |> String.trim()
    end

    test "a document without an ingest timestamp renders an unknown time" do
      rendered =
        SessionSearch.format_results([
          doc(session_key: "agent:fmt:main", ingested_at_ms: nil)
        ])

      assert rendered =~ "[1] unknown | session: agent:fmt:main"
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  # Drives the real local provider against the test's own store instance instead
  # of the globally registered one.
  defp search(store, query, opts) do
    SessionSearch.search(
      query,
      Keyword.merge(opts, provider_specs: local_specs(), memory_store: store)
    )
  end

  defp local_specs do
    [
      %{
        id: "test-local",
        module: Local,
        enabled: true,
        scopes: [:session, :agent, :workspace, :all],
        timeout_ms: 10_000
      }
    ]
  end

  defp recording_opts do
    [
      provider_specs: [
        %{
          id: "recording",
          module: RecordingProvider,
          enabled: true,
          scopes: [:session, :agent, :workspace, :all],
          timeout_ms: 10_000
        }
      ],
      owner: self(),
      scope: :session,
      scope_key: "agent:gate:main"
    ]
  end

  defp seed(store, docs) do
    Enum.each(docs, &Store.put(store, &1))
    # `put` is a cast; a synchronous call flushes everything queued before it.
    _ = Store.stats(store)
    :ok
  end

  defp matching_docs(count, session, now) do
    for i <- 1..count do
      doc(
        session_key: session,
        ingested_at_ms: now - i * 1_000,
        prompt_summary: "deploy the api build #{i}"
      )
    end
  end

  defp doc(attrs) do
    unique = System.unique_integer([:positive])

    defaults = %Document{
      doc_id: "mem_#{unique}",
      run_id: "run_#{unique}",
      session_key: "agent:session_search_test:main",
      agent_id: "session_search_test",
      workspace_key: nil,
      scope: :session,
      started_at_ms: 0,
      ingested_at_ms: 0,
      prompt_summary: "deploy the api",
      answer_summary: "deployed the api",
      tools_used: ["bash"],
      provider: "anthropic",
      model: "claude-sonnet-4-6",
      outcome: :unknown,
      meta: %{}
    }

    struct!(defaults, attrs)
  end

  defp assert_newest_first(results) do
    timestamps = Enum.map(results, & &1.ingested_at_ms)
    assert timestamps == Enum.sort(timestamps, :desc)
  end
end
