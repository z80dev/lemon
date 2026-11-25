defmodule LemonHoncho.MemoryProviderTest.Stub do
  @moduledoc false
  # A Honcho whose answers each test chooses, and which forwards every call it
  # receives to the test process so "which endpoint was asked" can be asserted
  # directly. It is installed through the same
  # `Application.get_env(:lemon_honcho, :client, ...)` seam the session manager
  # reads, because a second seam is a second thing to remember.

  use Agent

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts) do
    owner = Keyword.fetch!(opts, :owner)

    Agent.start_link(fn -> owner end, name: __MODULE__)
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

  defp record(name, payload) do
    send(Agent.get(__MODULE__, & &1), {:honcho_call, name, payload})
    {:ok, []}
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

  # The compliance suite above runs against an *unconfigured* Honcho, which is
  # the state a fresh checkout is in. The stub client is installed here as
  # well, so that a machine with real credentials in its environment still
  # cannot make this test file talk to a live Honcho.
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

  defp honcho_session do
    LemonHoncho.SessionName.resolve(manager_config(),
      cwd: @cwd,
      session_key: @session_key,
      owner: owner()
    )
  end

  defp owner, do: LemonHoncho.Owner.new(manager_config(), @session_key, nil, "legacy")

  defp manager_config do
    %Config{
      api_key: "sk-provider-test",
      user_peer: "user",
      ai_peer: "lemon",
      session_strategy: :per_directory,
      first_turn_wait_ms: 2_000
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
