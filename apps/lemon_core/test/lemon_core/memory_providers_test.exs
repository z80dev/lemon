defmodule LemonCore.MemoryProvidersTest do
  use ExUnit.Case, async: true

  alias LemonCore.MemoryDocument
  alias LemonCore.MemoryProviders

  defmodule FakeProvider do
    @behaviour LemonCore.MemoryProvider

    @impl true
    def put(doc, opts) do
      send(opts[:owner], {:fake_put, opts[:provider_id], doc.doc_id})
      :ok
    end

    @impl true
    def search(query, opts) do
      send(
        opts[:owner],
        {:fake_search, opts[:provider_id], query, opts[:scope], opts[:scope_key]}
      )

      [
        %MemoryDocument{
          doc_id: "external-doc",
          run_id: "run-external",
          session_key: "session-1",
          agent_id: "agent-1",
          workspace_key: "workspace-1",
          scope: :session,
          started_at_ms: 1,
          ingested_at_ms: 20,
          prompt_summary: "external prompt",
          answer_summary: "external answer"
        }
      ]
    end
  end

  defmodule BrokenProvider do
    @behaviour LemonCore.MemoryProvider

    @impl true
    def put(_doc, _opts), do: raise("private-provider-secret")

    @impl true
    def search(_query, _opts), do: raise("private-provider-secret")
  end

  test "search fans out to enabled providers and deduplicates results" do
    local_doc = doc("local-doc", 10)
    duplicate_external_doc = doc("local-doc", 30)

    specs = [
      %{id: "left", module: __MODULE__.StaticProvider, enabled: true, scopes: [:session]},
      %{id: "fake", module: FakeProvider, enabled: true, scopes: [:session]},
      %{id: "disabled", module: FakeProvider, enabled: false, scopes: [:session]}
    ]

    :persistent_term.put({__MODULE__.StaticProvider, :docs}, [
      local_doc,
      duplicate_external_doc
    ])

    on_exit(fn -> :persistent_term.erase({__MODULE__.StaticProvider, :docs}) end)

    results =
      MemoryProviders.search("deploy",
        provider_specs: specs,
        owner: self(),
        scope: :session,
        scope_key: "session-1",
        limit: 10
      )

    assert_receive {:fake_search, "fake", "deploy", :session, "session-1"}
    refute_received {:fake_search, "disabled", _, _, _}
    assert Enum.map(results, & &1.doc_id) == ["external-doc", "local-doc"]
  end

  test "provider failures do not fail search" do
    results =
      MemoryProviders.search("deploy",
        provider_specs: [
          %{id: "broken", module: BrokenProvider, enabled: true, scopes: [:session]},
          %{id: "fake", module: FakeProvider, enabled: true, scopes: [:session]}
        ],
        owner: self(),
        scope: :session,
        scope_key: "session-1",
        limit: 5
      )

    assert_receive {:fake_search, "fake", "deploy", :session, "session-1"}
    assert Enum.map(results, & &1.doc_id) == ["external-doc"]
  end

  test "put fans out through isolated registry" do
    name = :"memory_providers_test_#{System.unique_integer([:positive])}"
    {:ok, pid} = start_supervised({MemoryProviders, name: name})

    assert :ok =
             MemoryProviders.register_provider(pid,
               id: "fake",
               module: FakeProvider,
               scopes: [:workspace],
               source: "test"
             )

    doc = doc("put-doc", 10, scope: :workspace)
    assert :ok = MemoryProviders.put(doc, server: pid, owner: self())

    :sys.get_state(pid)
    assert_receive {:fake_put, "fake", "put-doc"}
  end

  test "status redacts provider implementation details" do
    status =
      MemoryProviders.status(
        provider_specs: [
          %{
            id: "team-memory",
            module: FakeProvider,
            enabled: true,
            scopes: [:workspace],
            source: "extension"
          }
        ]
      )

    assert status.provider_count == 1
    assert status.enabled_provider_count == 1
    assert [provider] = status.providers
    assert provider.id == "team-memory"
    assert provider.source == "extension"
    assert provider.scopes == ["workspace"]
    assert provider.module_loaded == true
    assert status.cleanup.includes_memory_contents == false
    assert status.cleanup.includes_raw_provider_config == false
    refute inspect(status) =~ "private-provider-secret"
  end

  defmodule StaticProvider do
    @behaviour LemonCore.MemoryProvider

    @impl true
    def put(_doc, _opts), do: :ok

    @impl true
    def search(_query, _opts) do
      :persistent_term.get({__MODULE__, :docs}, [])
    end
  end

  defp doc(id, ingested_at_ms, opts \\ []) do
    %MemoryDocument{
      doc_id: id,
      run_id: "run-#{id}",
      session_key: "session-1",
      agent_id: "agent-1",
      workspace_key: "workspace-1",
      scope: Keyword.get(opts, :scope, :session),
      started_at_ms: ingested_at_ms - 1,
      ingested_at_ms: ingested_at_ms,
      prompt_summary: "prompt",
      answer_summary: "answer"
    }
  end
end
