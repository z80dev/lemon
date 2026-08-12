defmodule LemonHoncho.MemoryProviderTest.Stub do
  @moduledoc false
  # A Honcho whose answers each test chooses, and which forwards every call it
  # receives to the test process so "which endpoint was asked" can be asserted
  # directly. It is installed through the same
  # `Application.get_env(:lemon_honcho, :client, ...)` seam the session manager
  # reads, because a second seam is a second thing to remember.

  use Agent

  @default {:ok, []}

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts) do
    owner = Keyword.fetch!(opts, :owner)

    Agent.start_link(fn -> %{owner: owner, responses: %{}} end, name: __MODULE__)
  end

  @doc "Sets what the named endpoint answers for the rest of the test."
  @spec stub(atom(), term()) :: :ok
  def stub(name, response) do
    Agent.update(__MODULE__, &put_in(&1.responses[name], response))
  end

  ## Session-manager surface — enough for a session to initialize.

  def ensure_workspace(_config), do: {:ok, %{}}
  def ensure_peer(_config, _peer), do: {:ok, %{}}
  def ensure_session(_config, _session_id, _specs), do: {:ok, %{}}
  def set_peer_config(_config, _session, _peer, _flags), do: {:ok, %{}}
  def session_context(_config, _session_id, _opts), do: {:ok, %{}}
  def peer_context(_config, _peer, _opts), do: {:ok, %{}}
  def chat(_config, _peer, _query, _opts), do: {:ok, nil}

  def add_messages(_config, session_id, messages) do
    record(:add_messages, {session_id, messages})
  end

  ## Search surface — what the memory provider uses.

  def session_search(_config, session_id, query, opts) do
    record(:session_search, {session_id, query, opts})
  end

  def workspace_search(_config, query, opts) do
    record(:workspace_search, {query, opts})
  end

  defp record(name, payload) do
    {owner, response} =
      Agent.get(__MODULE__, &{&1.owner, Map.get(&1.responses, name, @default)})

    send(owner, {:honcho_call, name, payload})
    response
  end
end

defmodule LemonHoncho.MemoryProviderTest do
  use LemonPlatformTest.ProviderCase, async: false, provider: LemonHoncho.MemoryProvider

  alias LemonHoncho.Config
  alias LemonHoncho.MemoryProvider
  alias LemonHoncho.MemoryProviderTest.Stub
  alias LemonHoncho.SessionManager
  alias LemonMemory.Document

  @cwd "/tmp/lemon-honcho-provider"
  @session_key "agent:demo:main"
  @honcho_session "lemon-honcho-provider"
  @env_keys [:enabled, :api_key, :base_url, :client]
  @os_env_keys ["HONCHO_API_KEY", "HONCHO_BASE_URL", "LEMON_HONCHO_ENABLED"]

  # The shape `LemonMemory.Safety.contains_secret?/1` actually matches: a
  # `name: value` pair whose name is one of its credential words.
  @secret "api_key: hunter2please"

  # The compliance suite above runs against an *unconfigured* Honcho, which is
  # the state a fresh checkout is in and the one where returning `[]` for
  # everything matters most. The stub client is installed here as well, so that
  # a machine with real credentials in its environment still cannot make this
  # test file talk to a live Honcho.
  setup do
    previous = Enum.map(@env_keys, &{&1, Application.fetch_env(:lemon_honcho, &1)})
    previous_os = Enum.map(@os_env_keys, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, &restore_env/1)
      Enum.each(previous_os, &restore_os_env/1)
    end)

    # `Config.load/0` reads the operating system environment before the
    # application env, so an exported HONCHO_API_KEY on the developer's machine
    # would otherwise decide what this file tests — and point it at a live
    # Honcho.
    Enum.each(@os_env_keys, &System.delete_env/1)

    stop_application_manager()
    start_supervised!({Stub, owner: self()})

    Application.put_env(:lemon_honcho, :client, Stub)
    Application.put_env(:lemon_honcho, :enabled, false)
    Application.delete_env(:lemon_honcho, :api_key)
    Application.delete_env(:lemon_honcho, :base_url)

    :ok
  end

  describe "search/2 when Honcho is not configured" do
    test "returns [] without calling the client" do
      assert MemoryProvider.search("cache", scope: :all) == []
      refute_receive {:honcho_call, _name, _payload}, 100
    end
  end

  describe "search/2 routing" do
    setup :configure_honcho

    test "a session with a known Honcho mapping searches that session" do
      map_session()

      assert MemoryProvider.search("cache", scope: :session, scope_key: @session_key) == []

      assert_receive {:honcho_call, :session_search, {@honcho_session, "cache", opts}}, 1_000
      assert opts[:limit] == 5
    end

    test "a session with no mapping widens to the workspace rather than inventing one" do
      assert MemoryProvider.search("cache", scope: :session, scope_key: "never-seen") == []

      assert_receive {:honcho_call, :workspace_search, {"cache", _opts}}, 1_000
    end

    test "agent, workspace and all scopes search the whole workspace" do
      for scope <- [:agent, :workspace, :all] do
        MemoryProvider.search("cache", scope: scope, scope_key: "demo")

        assert_receive {:honcho_call, :workspace_search, {"cache", _opts}}, 1_000
      end
    end

    test "a scoped search with no scope key returns [] and calls nothing" do
      for scope <- [:session, :agent, :workspace] do
        assert MemoryProvider.search("cache", scope: scope) == []
      end

      refute_receive {:honcho_call, _name, _payload}, 100
    end

    test "a blank query returns [] and calls nothing" do
      assert MemoryProvider.search("   ", scope: :all) == []
      refute_receive {:honcho_call, _name, _payload}, 100
    end

    # `search/2` has one channel and it is a list, so a withheld query is
    # reported the way every other unsearchable state is: `[]`, never an error
    # tuple, which the registry would discard along with the whole result set.
    test "a query that looks like a credential returns [] and calls nothing" do
      for query <- [@secret, @secret <> " " <> String.duplicate("a", 9_066)] do
        assert MemoryProvider.search(query, scope: :all) == []
      end

      refute_receive {:honcho_call, _name, _payload}, 100
    end

    test "a long query is clipped to 2,000 characters before it reaches Honcho" do
      assert MemoryProvider.search(String.duplicate("a", 9_066), scope: :all) == []

      assert_receive {:honcho_call, :workspace_search, {query, _opts}}, 1_000
      assert String.length(query) == 2_000
    end

    test "the limit is honoured, capped and defaulted" do
      assert MemoryProvider.search("cache", scope: :all, limit: 3) == []
      assert_receive {:honcho_call, :workspace_search, {"cache", [limit: 3]}}, 1_000

      assert MemoryProvider.search("cache", scope: :all, limit: 10_000) == []
      assert_receive {:honcho_call, :workspace_search, {"cache", [limit: 100]}}, 1_000

      assert MemoryProvider.search("cache", scope: :all, limit: :lots) == []
      assert_receive {:honcho_call, :workspace_search, {"cache", [limit: 5]}}, 1_000
    end

    test "unknown options are ignored rather than rejected" do
      assert MemoryProvider.search("cache",
               scope: :all,
               provider_id: "honcho",
               some_future_option: :added_next_release
             ) == []

      assert_receive {:honcho_call, :workspace_search, {"cache", _opts}}, 1_000
    end
  end

  describe "search/2 document mapping" do
    setup :configure_honcho

    test "a Honcho message becomes a well-typed document" do
      Stub.stub(:workspace_search, {:ok, [message()]})

      assert [%Document{} = document] = MemoryProvider.search("cache", scope: :all)

      assert is_binary(document.doc_id)
      assert document.doc_id == "hon_msg_1"
      assert is_integer(document.ingested_at_ms)
      assert document.ingested_at_ms == DateTime.to_unix(~U[2026-08-11 10:30:00Z], :millisecond)
      assert document.started_at_ms == document.ingested_at_ms
      assert document.run_id == ""
      assert document.session_key == @honcho_session
      assert document.agent_id == ""
      assert document.workspace_key == nil
      assert document.scope == :global
      assert document.prompt_summary == ""
      assert document.answer_summary == "The cache was cold."
      assert document.tools_used == []
      assert document.provider == "honcho"
      assert document.model == nil
      assert document.outcome == :unknown

      assert document.meta == %{
               source: "honcho",
               peer_id: "lemon",
               message_id: "msg_1",
               session_id: @honcho_session
             }
    end

    test "a session-scoped hit is keyed by the Lemon session key, not Honcho's" do
      map_session()
      Stub.stub(:session_search, {:ok, [message()]})

      assert [%Document{} = document] =
               MemoryProvider.search("cache", scope: :session, scope_key: @session_key)

      assert document.session_key == @session_key
      assert document.scope == :session
    end

    test "an agent-scoped hit carries the agent id the search was scoped to" do
      Stub.stub(:workspace_search, {:ok, [message()]})

      assert [%Document{} = document] =
               MemoryProvider.search("cache", scope: :agent, scope_key: "demo")

      assert document.agent_id == "demo"
      assert document.scope == :agent
    end

    test "a message with no id keeps the same doc_id across searches" do
      Stub.stub(:workspace_search, {:ok, [Map.delete(message(), "id")]})

      assert [first] = MemoryProvider.search("cache", scope: :all)
      assert [second] = MemoryProvider.search("cache", scope: :all)

      assert String.starts_with?(first.doc_id, "hon_")
      assert first.doc_id == second.doc_id
    end

    test "an unparseable timestamp still yields a sortable document" do
      Stub.stub(:workspace_search, {:ok, [%{message() | "created_at" => "whenever"}]})

      assert [document] = MemoryProvider.search("cache", scope: :all)
      assert is_integer(document.ingested_at_ms)
    end

    test "a long message is clipped to the document summary cap" do
      long = String.duplicate("a", Document.max_summary_bytes() * 2)
      Stub.stub(:workspace_search, {:ok, [%{message() | "content" => long}]})

      assert [document] = MemoryProvider.search("cache", scope: :all)
      assert String.length(document.answer_summary) == Document.max_summary_bytes()
    end
  end

  describe "search/2 failure modes" do
    setup :configure_honcho

    test "a client error yields []" do
      Stub.stub(:workspace_search, {:error, {:transport, :nxdomain}})

      assert MemoryProvider.search("cache", scope: :all) == []
    end

    test "an API error yields []" do
      Stub.stub(:workspace_search, {:error, {:api_error, 500, "boom"}})

      assert MemoryProvider.search("cache", scope: :all) == []
    end

    test "a response that is not a list yields []" do
      Stub.stub(:workspace_search, {:ok, %{"results" => "surprise"}})

      assert MemoryProvider.search("cache", scope: :all) == []
    end

    test "a result that is not a tuple at all yields []" do
      Stub.stub(:workspace_search, :garbage)

      assert MemoryProvider.search("cache", scope: :all) == []
    end

    test "entries with no usable content are dropped rather than returned empty" do
      Stub.stub(:workspace_search, {:ok, ["a string", 42, %{"content" => nil}, %{}]})

      assert MemoryProvider.search("cache", scope: :all) == []
    end
  end

  describe "put/2" do
    test "returns :ok and calls nothing when Honcho is not configured" do
      start_supervised!({SessionManager, config: %Config{}, client: Stub})

      assert MemoryProvider.put(document(), provider_id: "honcho") == :ok
      refute_receive {:honcho_call, _name, _payload}, 150
    end

    test "returns :ok when no session manager is running at all" do
      assert MemoryProvider.put(document(), provider_id: "honcho") == :ok
    end

    test "hands the document to the session manager when Honcho is configured" do
      start_supervised!({SessionManager, config: manager_config(), client: Stub})

      assert MemoryProvider.put(document(), provider_id: "honcho") == :ok

      assert_receive {:honcho_call, :add_messages, {@honcho_session, messages}}, 1_000

      assert messages == [
               %{content: "why is the build slow?", peer_id: "user"},
               %{content: "The cache was cold.", peer_id: "lemon"}
             ]
    end
  end

  ## Helpers

  # `Config.load/0` is what the provider reads, so the only way to configure it
  # is through the application env it resolves from.
  defp configure_honcho(_context) do
    Application.put_env(:lemon_honcho, :enabled, true)
    Application.put_env(:lemon_honcho, :api_key, "sk-provider-test")

    :ok
  end

  # The provider asks the session manager whether a Lemon session key has a
  # Honcho session yet, so a mapping has to be established the way a real run
  # establishes one: by serving a turn.
  defp map_session do
    start_supervised!({SessionManager, config: manager_config(), client: Stub})

    SessionManager.context_for(%{cwd: @cwd, session_key: @session_key, session_scope: :main})

    assert SessionManager.honcho_session_id(@session_key) == {:ok, @honcho_session}
  end

  defp manager_config do
    %Config{
      api_key: "sk-provider-test",
      user_peer: "user",
      ai_peer: "lemon",
      session_strategy: :per_directory,
      first_turn_wait_ms: 2_000
    }
  end

  defp message do
    %{
      "id" => "msg_1",
      "content" => "The cache was cold.",
      "peer_id" => "lemon",
      "session_id" => @honcho_session,
      "created_at" => "2026-08-11T10:30:00Z"
    }
  end

  defp document do
    Document.new(
      session_key: @session_key,
      agent_id: "demo",
      workspace_key: @cwd,
      prompt_summary: "why is the build slow?",
      answer_summary: "The cache was cold."
    )
  end

  defp restore_env({key, {:ok, value}}), do: Application.put_env(:lemon_honcho, key, value)
  defp restore_env({key, :error}), do: Application.delete_env(:lemon_honcho, key)

  defp restore_os_env({key, nil}), do: System.delete_env(key)
  defp restore_os_env({key, value}), do: System.put_env(key, value)

  # The application starts its own manager under the registered name; these
  # tests need that name for a manager wired to the stub.
  defp stop_application_manager do
    if is_pid(Process.whereis(SessionManager)) do
      Supervisor.terminate_child(LemonHoncho.Supervisor, SessionManager)
    end

    :ok
  catch
    :exit, _reason -> :ok
  end
end
