defmodule LemonPlatformTest.ProviderCase do
  @moduledoc """
  Compliance suite for `LemonMemory.Provider` implementations.

  ## What a provider is

  A memory provider is a searchable place to keep what an agent has already
  done. `LemonMemory` ships one — `LemonMemory.Providers.Local`, backed by
  SQLite FTS — and fans out to any others you register:
  a vector database, a wiki, an issue tracker, a company knowledge base.

  Two callbacks. `put/2` receives a `LemonMemory.Document` when a run finishes;
  `search/2` receives a query and returns documents. `LemonMemory.Providers` is
  what calls both, and it is deliberately paranoid: it runs providers in tasks,
  applies a per-provider timeout, rescues exceptions, discards results that are
  not `LemonMemory.Document` structs, and logs rather than propagates. A broken
  provider degrades memory search; it does not break the agent.

  That isolation is a safety net, not a licence. It only works if your provider
  returns in bounded time and returns the right shape.

  ## The contract

  ### `search/2` returns a list of documents, always

  Not `{:ok, docs}`, not `nil`, not a stream — a plain list of
  `%LemonMemory.Document{}`. An empty list is the correct answer for "no
  matches", "backend unreachable", "query made no sense". The registry treats
  anything else as a provider failure and drops the whole result set.

  ### `search/2` must not raise on user input

  Queries come from agents and from people. They contain quotes, wildcards,
  boolean operators, emoji, and the occasional ten-thousand-character paste.
  Full-text engines are notoriously eager to reject those with a syntax error —
  sanitise the query rather than passing it through. (The built-in local
  provider strips FTS5 metacharacters and AND-joins the remaining terms.)

  ### `search/2` receives scoped options

  The same options `LemonMemory.SessionSearch` uses:

    * `:scope` — `:session`, `:agent`, `:workspace` or `:all`
    * `:scope_key` — the session key, agent id or workspace key to scope to; may
      be absent, in which case a scoped search must return `[]` rather than
      silently widening to everything
    * `:limit` — how many documents the caller wants
    * `:provider_id` — the id you were registered under, injected by the registry

  Unknown options must be ignored, not rejected: the platform adds keys over
  time and old providers must keep working.

  ### `put/2` returns `:ok` or `{:error, reason}`

  It is called on the run-finalisation path with a fully populated document.
  Anything other than `:ok`/`{:error, _}` is logged as a failure by the
  registry. `put/2` should be cheap; if your store is slow, buffer internally.

  ## Minimal implementation

      defmodule MyApp.MemoryProvider do
        @behaviour LemonMemory.Provider

        alias LemonMemory.Document

        @impl true
        def put(%Document{} = doc, _opts) do
          MyApp.Index.upsert(doc.doc_id, doc.prompt_summary <> " " <> doc.answer_summary)
        end

        @impl true
        def search(query, opts) do
          limit = Keyword.get(opts, :limit, 5)

          query
          |> MyApp.Index.query(limit: limit)
          |> Enum.map(&to_document/1)
        rescue
          _ -> []
        end
      end

  Register it when your application starts:

      LemonMemory.Providers.register_provider(%{
        id: "my-provider",
        module: MyApp.MemoryProvider,
        label: "My knowledge base",
        scopes: [:agent, :workspace, :all],
        timeout_ms: 1_500
      })

  ## Running the suite

      defmodule MyApp.MemoryProviderComplianceTest do
        use LemonPlatformTest.ProviderCase, async: false, provider: MyApp.MemoryProvider
      end

  ## Options

    * `:provider` — required, the provider module under test.
    * `:registry` — round-trip the provider through `LemonMemory.Providers`:
      register, confirm it appears in `status/1`, search through the fan-out,
      unregister. Default `true`; requires `:lemon_memory` to be started, and
      `async: false` because the registry is node-global.
    * `:document` — `{Module, :function}` returning a `%LemonMemory.Document{}`
      to hand to `put/2`, called with the test context. Defaults to a synthetic
      document; override when your provider needs particular fields.
    * `:queries` — extra query strings to probe `search/2` with, appended to the
      built-in hostile set.

  ## Known gaps in the behaviour

  `LemonMemory.Provider` is the thinnest behaviour in the platform, and the one
  whose `@callback`s say the least:

    * **`search/2`'s failure mode is undocumented.** The typespec is
      `[Document.t()]` with no error branch, so "backend down" and "no results"
      are the same answer. Providers cannot report degradation and the platform
      cannot distinguish an empty index from an unreachable one.
    * **`search_opts()` is `keyword()`.** Which keys are passed, and which a
      provider is obliged to honour, live in the moduledoc rather than the
      types. In particular nothing forces a provider to honour `:limit` — the
      registry re-trims after merging — so this suite checks that `:limit` is
      accepted, not that it is obeyed.
    * **`put/2` has no delete or update counterpart.** Retention is enforced by
      `LemonMemory.Store` for the local provider only; a registered external
      provider is never told that a document was pruned.
  """

  use ExUnit.CaseTemplate

  @hostile_queries [
    "",
    " ",
    "hello",
    "two words",
    "üñïçø∂é ☃ 日本語",
    ~s("quoted phrase"),
    "wildcard*",
    "foo AND bar",
    "foo OR (bar NOT baz)",
    "NEAR/2 tokens",
    "semi; colon: comma, dot. bang! question?",
    "-",
    "'",
    "\\",
    "%_",
    "1; DROP TABLE memory_documents;--"
  ]

  @doc """
  The query strings every provider is probed with.

  Deliberately full of full-text-search metacharacters: these are the inputs
  that turn an unsanitised query into a syntax error from the search engine.
  """
  @spec hostile_queries() :: [String.t()]
  def hostile_queries, do: @hostile_queries

  @doc """
  Builds a synthetic `LemonMemory.Document` for `put/2` probes.
  """
  @spec sample_document(keyword()) :: LemonMemory.Document.t()
  def sample_document(overrides \\ []) do
    now = System.system_time(:millisecond)
    unique = System.unique_integer([:positive])

    fields =
      Keyword.merge(
        [
          doc_id: "mem_platform_test_#{unique}",
          run_id: "run_platform_test_#{unique}",
          session_key: "agent:platform_test:main",
          agent_id: "platform_test",
          workspace_key: nil,
          scope: :session,
          started_at_ms: now,
          ingested_at_ms: now,
          prompt_summary: "contract kit probe #{unique}",
          answer_summary: "contract kit answer #{unique}",
          tools_used: ["probe"],
          provider: "contract-kit",
          model: "contract-kit",
          outcome: :success,
          meta: %{}
        ],
        overrides
      )

    struct!(LemonMemory.Document, fields)
  end

  using opts do
    provider = Keyword.fetch!(opts, :provider)
    registry? = Keyword.get(opts, :registry, true)
    document = Keyword.get(opts, :document)
    queries = Keyword.get(opts, :queries, [])
    label = Macro.to_string(provider)

    quote do
      @provider unquote(provider)
      @document_spec unquote(document)
      @extra_queries unquote(queries)

      describe unquote(label <> " behaviour declaration") do
        test "declares LemonMemory.Provider" do
          assert LemonPlatformTest.declares_behaviour?(@provider, LemonMemory.Provider),
                 "#{inspect(@provider)} must declare `@behaviour LemonMemory.Provider`"
        end

        test "exports every required callback" do
          assert LemonPlatformTest.missing_callbacks(@provider, LemonMemory.Provider) == []
        end
      end

      describe unquote(label <> " search/2") do
        test "returns a list of documents for hostile queries" do
          queries = LemonPlatformTest.ProviderCase.hostile_queries() ++ @extra_queries

          for query <- queries do
            documents = lemon_provider_search(query, limit: 3)

            assert is_list(documents),
                   "search/2 must return a list for #{inspect(query)}, got: #{inspect(documents)}"

            for document <- documents do
              assert %LemonMemory.Document{} = document,
                     "search/2 must return %LemonMemory.Document{} structs, got: #{inspect(document)}"
            end
          end
        end

        test "survives a very long query" do
          assert is_list(lemon_provider_search(String.duplicate("token ", 2_000), []))
        end

        test "accepts every scope, with and without a scope key" do
          for scope <- [:session, :agent, :workspace, :all] do
            assert is_list(lemon_provider_search("probe", scope: scope)),
                   "search/2 failed for scope #{inspect(scope)} without a scope key"

            assert is_list(
                     lemon_provider_search("probe", scope: scope, scope_key: "agent:x:main")
                   ),
                   "search/2 failed for scope #{inspect(scope)} with a scope key"
          end
        end

        test "ignores options it does not know" do
          assert is_list(
                   lemon_provider_search("probe",
                     limit: 1,
                     provider_id: "compliance",
                     some_future_option: :added_next_release
                   )
                 )
        end

        test "accepts no options at all" do
          assert is_list(lemon_provider_search("probe", []))
        end
      end

      describe unquote(label <> " put/2") do
        test "returns :ok or {:error, reason}", context do
          document =
            case @document_spec do
              nil -> LemonPlatformTest.ProviderCase.sample_document()
              spec -> LemonPlatformTest.resolve(spec, context)
            end

          assert %LemonMemory.Document{} = document

          result =
            try do
              @provider.put(document, provider_id: "compliance")
            rescue
              exception ->
                flunk("""
                put/2 raised:

                    #{Exception.message(exception)}

                Report storage failures as {:error, reason} instead.
                """)
            end

          assert result == :ok or match?({:error, _}, result),
                 "put/2 must return :ok or {:error, reason}, got: #{inspect(result)}"
        end
      end

      if unquote(registry?) do
        describe unquote(label <> " registration round-trip") do
          setup do
            :ok = LemonPlatformTest.ProviderCase.ensure_memory_started!()

            id = "compliance-#{System.unique_integer([:positive])}"
            on_exit(fn -> LemonMemory.Providers.unregister_provider(id) end)

            {:ok, provider_id: id}
          end

          test "the provider registry accepts, reports and drops the provider", %{provider_id: id} do
            spec = %{
              id: id,
              module: @provider,
              label: "compliance probe",
              scopes: [:session, :agent, :workspace, :all],
              timeout_ms: 2_000
            }

            assert LemonMemory.Providers.register_provider(spec) == :ok

            status = LemonMemory.Providers.status()
            registered = Enum.find(status.providers, &(&1.id == id))

            assert registered, "registered provider #{id} is missing from Providers.status/1"
            assert registered.enabled
            assert registered.module_loaded, "the registry could not load #{inspect(@provider)}"

            assert LemonMemory.Providers.unregister_provider(id) == :ok
            assert Enum.find(LemonMemory.Providers.status().providers, &(&1.id == id)) == nil
          end

          test "fan-out search through the registry returns documents", %{provider_id: id} do
            assert LemonMemory.Providers.register_provider(%{id: id, module: @provider}) == :ok

            documents = LemonMemory.Providers.search("compliance probe", scope: :all, limit: 3)

            assert is_list(documents)
            assert Enum.all?(documents, &match?(%LemonMemory.Document{}, &1))
          end
        end
      end

      defp lemon_provider_search(query, opts) do
        @provider.search(query, opts)
      rescue
        exception ->
          flunk("""
          search/2 raised on #{inspect(query, printable_limit: 80)}:

              #{Exception.message(exception)}

          Search is best-effort: return [] instead of raising.
          """)
      end
    end
  end

  @doc """
  Starts `:lemon_memory` if it is not already running.
  """
  @spec ensure_memory_started!() :: :ok
  def ensure_memory_started! do
    case Application.ensure_all_started(:lemon_memory) do
      {:ok, _apps} ->
        :ok

      {:error, reason} ->
        raise """
        LemonPlatformTest.ProviderCase needs the :lemon_memory application running
        to exercise the provider registry, but it failed to start: #{inspect(reason)}

        Start it in test_helper.exs, or pass `registry: false` to skip the
        registration round-trip.
        """
    end
  end
end
