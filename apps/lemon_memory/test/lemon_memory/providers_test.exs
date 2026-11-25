defmodule LemonMemory.ProvidersTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias LemonMemory.Document
  alias LemonMemory.Providers

  defmodule FakeProvider do
    @behaviour LemonMemory.Provider

    @impl true
    def put(doc, opts) do
      send(opts[:owner], {:fake_put, opts[:provider_id], doc.doc_id})
      :ok
    end
  end

  defmodule BrokenProvider do
    @behaviour LemonMemory.Provider

    @impl true
    def put(_doc, _opts), do: raise("private-provider-secret")
  end

  # Blocks far longer than any deadline under test, so the only thing that can
  # end the call is the registry enforcing this provider's own :timeout_ms.
  defmodule HangingProvider do
    @behaviour LemonMemory.Provider

    @impl true
    def put(_doc, _opts) do
      Process.sleep(:timer.seconds(30))
      :ok
    end
  end

  # Has an unrelated process kill the one it is running in. `:kill` is
  # untrappable and cannot be rescued or caught by the registry's call wrapper,
  # so this is the failure mode a link would propagate to the registry.
  # The blocking sleep means the kill always lands first.
  defmodule KilledProvider do
    @behaviour LemonMemory.Provider

    @impl true
    def put(_doc, _opts) do
      target = self()
      spawn(fn -> Process.exit(target, :kill) end)
      Process.sleep(:timer.seconds(30))
      :ok
    end
  end

  # A module that still exports `search/2` is never asked to search: providers
  # are write targets only.
  defmodule SearchingProvider do
    @behaviour LemonMemory.Provider

    @impl true
    def put(_doc, _opts), do: :ok

    def search(_query, opts) do
      send(opts[:owner], :provider_searched)
      []
    end
  end

  test "put fans out through isolated registry" do
    pid = start_registry()
    register(pid, "fake", FakeProvider)

    assert :ok = Providers.put(doc("put-doc"), server: pid, owner: self())

    :sys.get_state(pid)
    assert_receive {:fake_put, "fake", "put-doc"}
  end

  test "the registry exposes no search fan-out" do
    Code.ensure_loaded!(Providers)
    refute function_exported?(Providers, :search, 2)
    refute function_exported?(Providers, :search, 1)
  end

  test "a raising provider is logged and the registry survives" do
    pid = start_registry()
    register(pid, "fake", FakeProvider)
    register(pid, "broken", BrokenProvider)

    log =
      capture_log(fn ->
        assert :ok = Providers.put(doc("broken-doc"), server: pid, owner: self())
        :sys.get_state(pid)
      end)

    assert Process.alive?(pid)
    assert_received {:fake_put, "fake", "broken-doc"}
    assert log =~ "provider broken put failed"
  end

  test "each provider is dropped at its own :timeout_ms, not the slowest provider's" do
    pid = start_registry()
    register(pid, "generous", FakeProvider, timeout_ms: 5_000)
    register(pid, "hangs", HangingProvider, timeout_ms: 200)

    {elapsed_us, _log} =
      :timer.tc(fn ->
        capture_log(fn ->
          :ok = Providers.put(doc("timed-doc"), server: pid, owner: self())
          :sys.get_state(pid, 10_000)
        end)
      end)

    elapsed_ms = div(elapsed_us, 1_000)
    assert_received {:fake_put, "generous", "timed-doc"}
    assert elapsed_ms >= 150, "the 200ms provider was dropped early (#{elapsed_ms}ms)"
    assert elapsed_ms < 4_000, "the 200ms provider waited on the 5s provider (#{elapsed_ms}ms)"
  end

  test "a provider killed mid-put leaves the registry and its registrations intact" do
    pid = start_registry()

    for {id, module} <- [{"fake", FakeProvider}, {"killed", KilledProvider}],
        do: register(pid, id, module, timeout_ms: 5_000)

    log =
      capture_log(fn ->
        assert :ok = Providers.put(doc("kill-doc"), server: pid, owner: self())

        # Synchronising on the registry is itself the assertion: a call only
        # returns if the GenServer outlived the provider process that died.
        :sys.get_state(pid)
      end)

    assert Process.alive?(pid)
    assert_received {:fake_put, "fake", "kill-doc"}
    assert log =~ "provider killed put task failed"

    status = Providers.status(provider_specs: GenServer.call(pid, :provider_specs))
    assert Enum.sort(Enum.map(status.providers, & &1.id)) == ["fake", "killed", "local"]
  end

  test "a registered provider that exports search/2 is only written to" do
    pid = start_registry()
    register(pid, "searching", SearchingProvider)

    assert :ok = Providers.put(doc("write-only"), server: pid, owner: self())
    :sys.get_state(pid)
    refute_received :provider_searched
  end

  test "status redacts provider implementation details" do
    status =
      Providers.status(
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

  defp start_registry do
    name = :"memory_providers_test_#{System.unique_integer([:positive])}"
    {:ok, pid} = start_supervised({Providers, name: name})
    pid
  end

  defp register(pid, id, module, opts \\ []) do
    assert :ok =
             Providers.register_provider(
               pid,
               [id: id, module: module, scopes: [:workspace], source: "test"] ++ opts
             )
  end

  defp doc(id) do
    %Document{
      doc_id: id,
      run_id: "run-#{id}",
      session_key: "session-1",
      agent_id: "agent-1",
      workspace_key: "workspace-1",
      scope: :workspace,
      started_at_ms: 9,
      ingested_at_ms: 10,
      prompt_summary: "prompt",
      answer_summary: "answer"
    }
  end
end
