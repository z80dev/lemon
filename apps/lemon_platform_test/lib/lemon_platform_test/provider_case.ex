defmodule LemonPlatformTest.ProviderCase do
  @moduledoc """
  Compliance suite for `LemonMemory.Provider` implementations.

  ## What a provider is

  A memory provider is a place a finished run's memory is written to.
  `LemonMemory` ships one — `LemonMemory.Providers.Local`, backed by SQLite —
  and fans every finished run's `LemonMemory.Document` out to any others you
  register: a vector database, a wiki, a remote memory service.

  Providers are write targets only. Recall reads the owned local index, which
  applies ownership before its result limit; a provider's own search belongs
  behind its own explicitly owner-scoped tools.

  One callback. `put/2` receives a `LemonMemory.Document` when a run finishes.
  `LemonMemory.Providers` calls it in an isolated process with a per-provider
  timeout, rescues exceptions, and logs rather than propagates failures. A
  broken provider loses its own copy of memory; it does not break the agent.

  ## The contract

  ### `put/2` returns `:ok` or `{:error, reason}`

  It is called on the run-finalisation path with a fully populated document.
  Anything other than `:ok`/`{:error, _}` is logged as a failure by the
  registry. `put/2` should be cheap; if your store is slow, buffer internally.

  ### Unknown options are ignored, not rejected

  `put/2` receives `:provider_id` (the id you were registered under). The
  platform adds keys over time and old providers must keep working.

  ## Minimal implementation

      defmodule MyApp.MemoryProvider do
        @behaviour LemonMemory.Provider

        alias LemonMemory.Document

        @impl true
        def put(%Document{} = doc, _opts) do
          MyApp.Index.upsert(doc.doc_id, doc.prompt_summary <> " " <> doc.answer_summary)
        end
      end

  Register it when your application starts:

      LemonMemory.Providers.register_provider(%{
        id: "my-provider",
        module: MyApp.MemoryProvider,
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
      register, confirm it appears in `status/1`, unregister. Default `true`;
      requires `:lemon_memory` to be started, and `async: false` because the
      registry is node-global.
    * `:document` — `{Module, :function}` returning a `%LemonMemory.Document{}`
      to hand to `put/2`, called with the test context. Defaults to a synthetic
      document; override when your provider needs particular fields.

  ## Known gaps in the behaviour

    * **`put/2` has no delete or update counterpart.** Retention is enforced by
      `LemonMemory.Store` for the local provider only; a registered external
      provider is never told that a document was pruned.
  """

  use ExUnit.CaseTemplate

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

  @doc false
  @spec assert_put_result!(term()) :: :ok
  def assert_put_result!(result) do
    assert result == :ok or match?({:error, _}, result),
           "put/2 must return :ok or {:error, reason}, got: #{inspect(result)}"

    :ok
  end

  using opts do
    LemonPlatformTest.require_dep!("ProviderCase", LemonMemory.Provider, :lemon_memory)

    provider = Keyword.fetch!(opts, :provider)
    registry? = Keyword.get(opts, :registry, true)
    document = Keyword.get(opts, :document)
    label = Macro.to_string(provider)

    quote do
      @provider unquote(provider)
      @document_spec unquote(document)

      describe unquote(label <> " behaviour declaration") do
        test "declares LemonMemory.Provider" do
          assert LemonPlatformTest.declares_behaviour?(@provider, LemonMemory.Provider),
                 "#{inspect(@provider)} must declare `@behaviour LemonMemory.Provider`"
        end

        test "exports every required callback" do
          assert LemonPlatformTest.missing_callbacks(@provider, LemonMemory.Provider) == []
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

          LemonPlatformTest.ProviderCase.assert_put_result!(result)
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
        end
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
