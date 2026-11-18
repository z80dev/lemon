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
  @env_keys [:enabled, :api_key, :base_url, :client, :user_peer]
  @os_env_keys ["HONCHO_API_KEY", "HONCHO_BASE_URL", "LEMON_HONCHO_ENABLED", "HONCHO_PEER"]

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

    test "a session with a known Honcho mapping searches that session, as its owner" do
      session = map_session()

      assert MemoryProvider.search("cache", scope: :session, scope_key: @session_key) == []

      assert_receive {:honcho_call, :session_search, {^session, "cache", opts}}, 1_000
      assert opts[:limit] == 5
      assert opts[:owner] == owner()
    end

    test "a session with no mapping returns [] and never widens to the workspace" do
      assert MemoryProvider.search("cache", scope: :session, scope_key: "never-seen") == []
      refute_receive {:honcho_call, _name, _payload}, 100
    end

    test "agent, workspace, all and unknown scopes cannot be partitioned by person" do
      map_session()

      for scope <- [:agent, :workspace, :all, :galaxy] do
        assert MemoryProvider.search("cache", scope: scope, scope_key: @session_key) == []
      end

      refute_receive {:honcho_call, _name, _payload}, 100
    end

    test "a scoped search with no scope key returns [] and calls nothing" do
      for scope <- [:session, :agent, :workspace] do
        assert MemoryProvider.search("cache", scope: scope) == []
      end

      refute_receive {:honcho_call, _name, _payload}, 100
    end

    test "an unproven memory claim returns [] and calls nothing" do
      map_session()

      assert MemoryProvider.search("cache",
               scope: :session,
               scope_key: @session_key,
               memory_context_key: "actor-a",
               memory_context_verified: true
             ) == []

      refute_receive {:honcho_call, _name, _payload}, 100
    end

    test "a blank query returns [] and calls nothing" do
      map_session()
      assert MemoryProvider.search("   ", scope: :session, scope_key: @session_key) == []
      refute_receive {:honcho_call, _name, _payload}, 100
    end

    # `search/2` has one channel and it is a list, so a withheld query is
    # reported the way every other unsearchable state is: `[]`, never an error
    # tuple, which the registry would discard along with the whole result set.
    test "a query that looks like a credential returns [] and calls nothing" do
      map_session()

      for query <- [@secret, @secret <> " " <> String.duplicate("a", 9_066)] do
        assert MemoryProvider.search(query, scope: :session, scope_key: @session_key) == []
      end

      refute_receive {:honcho_call, _name, _payload}, 100
    end

    test "a long query is clipped to 2,000 characters before it reaches Honcho" do
      map_session()
      search(String.duplicate("a", 9_066))

      assert_receive {:honcho_call, :session_search, {_session, query, _opts}}, 1_000
      assert String.length(query) == 2_000
    end

    test "the limit is honoured, capped and defaulted" do
      map_session()

      for {limit, sent} <- [{3, 3}, {10_000, 100}, {:lots, 5}] do
        search("cache", limit: limit)
        assert_receive {:honcho_call, :session_search, {_session, "cache", opts}}, 1_000
        assert opts[:limit] == sent
      end
    end

    test "unknown options are ignored rather than rejected" do
      map_session()
      search("cache", provider_id: "honcho", some_future_option: :added_next_release)

      assert_receive {:honcho_call, :session_search, {_session, "cache", _opts}}, 1_000
    end
  end

  describe "search/2 document mapping" do
    setup :configure_honcho

    setup do
      %{session: map_session()}
    end

    test "an owned Honcho message becomes a well-typed session document", %{session: session} do
      Stub.stub(:session_search, {:ok, [message(session)]})

      assert [%Document{} = document] = search("cache")

      assert document.doc_id == "hon_msg_1"
      assert document.ingested_at_ms == DateTime.to_unix(~U[2026-08-11 10:30:00Z], :millisecond)
      assert document.started_at_ms == document.ingested_at_ms
      assert document.run_id == ""
      assert document.session_key == @session_key
      assert document.agent_id == "demo"
      assert document.workspace_key == nil
      assert document.scope == :session
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
               session_id: session
             }
    end

    test "a hit not tagged for exactly this owner is dropped", %{session: session} do
      owned = message(session)

      foreign =
        for {key, identity, memory} <- [
              {"agent:demo:main", %{channel_id: "telegram", sender_id: "9"}, "legacy"},
              {"agent:other:main", nil, "legacy"},
              {"agent:demo:main", nil, "private:actor-a"}
            ] do
          other = LemonHoncho.Owner.new(manager_config(), key, identity, memory)

          %{owned | "id" => "msg_" <> other.digest}
          |> Map.put("metadata", LemonHoncho.Owner.metadata(other))
        end

      untagged = Map.delete(%{owned | "id" => "msg_legacy"}, "metadata")
      Stub.stub(:session_search, {:ok, [owned, untagged | foreign]})

      assert [%Document{doc_id: "hon_msg_1"}] = search("cache")
    end

    test "a message with no id keeps the same doc_id across searches", %{session: session} do
      Stub.stub(:session_search, {:ok, [Map.delete(message(session), "id")]})

      assert [first] = search("cache")
      assert [second] = search("cache")

      assert String.starts_with?(first.doc_id, "hon_")
      assert first.doc_id == second.doc_id
    end

    test "an unparseable timestamp still yields a sortable document", %{session: session} do
      Stub.stub(:session_search, {:ok, [%{message(session) | "created_at" => "whenever"}]})

      assert [document] = search("cache")
      assert is_integer(document.ingested_at_ms)
    end

    test "a long message is clipped to the document summary cap", %{session: session} do
      long = String.duplicate("a", Document.max_summary_bytes() * 2)
      Stub.stub(:session_search, {:ok, [%{message(session) | "content" => long}]})

      assert [document] = search("cache")
      assert String.length(document.answer_summary) == Document.max_summary_bytes()
    end
  end

  describe "search/2 failure modes" do
    setup :configure_honcho

    setup do
      map_session()
      :ok
    end

    test "a client error yields []" do
      Stub.stub(:session_search, {:error, {:transport, :nxdomain}})

      assert search("cache") == []
    end

    test "an API error yields []" do
      Stub.stub(:session_search, {:error, {:api_error, 500, "boom"}})

      assert search("cache") == []
    end

    test "a response that is not a list yields []" do
      Stub.stub(:session_search, {:ok, %{"results" => "surprise"}})

      assert search("cache") == []
    end

    test "a result that is not a tuple at all yields []" do
      Stub.stub(:session_search, :garbage)

      assert search("cache") == []
    end

    test "entries with no usable content are dropped rather than returned empty" do
      Stub.stub(:session_search, {:ok, ["a string", 42, %{"content" => nil}, %{}]})

      assert search("cache") == []
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

      session = honcho_session()
      assert_receive {:honcho_call, :add_messages, {^session, messages}}, 1_000
      owner = owner()
      metadata = LemonHoncho.Owner.metadata(owner)

      assert messages == [
               %{content: "why is the build slow?", peer_id: owner.user_peer, metadata: metadata},
               %{content: "The cache was cold.", peer_id: owner.ai_peer, metadata: metadata}
             ]
    end
  end

  ## Helpers

  # `Config.load/0` is what the provider reads, so the only way to configure it
  # is through the application env it resolves from.
  defp configure_honcho(_context) do
    Application.put_env(:lemon_honcho, :enabled, true)
    Application.put_env(:lemon_honcho, :api_key, "sk-provider-test")
    Application.put_env(:lemon_honcho, :user_peer, "user")

    :ok
  end

  # The provider asks the session manager whether a Lemon session key has a
  # Honcho session yet, so a mapping has to be established the way a real run
  # establishes one: by serving a turn.
  defp map_session do
    start_supervised!({SessionManager, config: manager_config(), client: Stub})

    SessionManager.context_for(%{cwd: @cwd, session_key: @session_key, session_scope: :main})

    session = honcho_session()

    assert SessionManager.honcho_session_id(SessionManager.entry_key(@session_key, owner())) ==
             {:ok, session}

    flush_calls()
    session
  end

  defp honcho_session do
    LemonHoncho.SessionName.resolve(manager_config(),
      cwd: @cwd,
      session_key: @session_key,
      owner: owner()
    )
  end

  defp owner, do: LemonHoncho.Owner.new(manager_config(), @session_key, nil, "legacy")

  defp search(query, opts \\ []) do
    MemoryProvider.search(query, [scope: :session, scope_key: @session_key] ++ opts)
  end

  defp flush_calls do
    receive do
      {:honcho_call, _name, _payload} -> flush_calls()
    after
      0 -> :ok
    end
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

  defp message(session) do
    %{
      "id" => "msg_1",
      "content" => "The cache was cold.",
      "peer_id" => "lemon",
      "session_id" => session,
      "created_at" => "2026-08-11T10:30:00Z",
      "metadata" => LemonHoncho.Owner.metadata(owner())
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
