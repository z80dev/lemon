defmodule LemonHoncho.ToolsCommonTest.StubClient do
  @moduledoc false
  # Enough of a Honcho for the session manager to finish a first refresh, which
  # is what resolves a session id and makes `scope/2`'s mapped branch reachable.
  # Nothing here is asserted on; the assertions are about what the manager
  # recorded, not about what it sent.

  @spec ensure_workspace(term()) :: {:ok, map()}
  def ensure_workspace(_config), do: {:ok, %{}}

  @spec ensure_peer(term(), String.t()) :: {:ok, map()}
  def ensure_peer(_config, _peer), do: {:ok, %{}}

  @spec ensure_session(term(), String.t(), list()) :: {:ok, map()}
  def ensure_session(_config, _session_id, _specs), do: {:ok, %{}}

  @spec set_peer_config(term(), String.t(), String.t(), map()) :: {:ok, map()}
  def set_peer_config(_config, _session_id, _peer, _flags), do: {:ok, %{}}

  @spec session_context(term(), String.t(), keyword()) :: {:ok, map()}
  def session_context(_config, _session_id, _opts) do
    {:ok, %{"summary" => %{"content" => "Discussed the flaky test."}}}
  end

  @spec peer_context(term(), String.t(), keyword()) :: {:ok, map()}
  def peer_context(_config, _peer, _opts), do: {:ok, %{"representation" => "Writes Elixir."}}

  @spec chat(term(), String.t(), String.t(), keyword()) :: {:ok, String.t()}
  def chat(_config, _peer, _query, _opts), do: {:ok, "They review diffs before prose."}
end

defmodule LemonHoncho.ToolsCommonTest do
  @moduledoc """
  `LemonHoncho.Tools.Common`, the plumbing the five Honcho tools share.

  These functions were five copies of each other until this module existed, and
  the two that mattered most were the ones hardest to see: the session-key
  precedence rule, which has to agree with `LemonHoncho.SessionManager`'s keying
  or a tool call lands on a different session than the injected context did, and
  the gate, which is where `LEMON_HONCHO_SAVE_MESSAGES=false` stops being a
  documented promise and becomes an enforced one. They are tested here directly
  rather than through five tools, so a change to either fails in one place with
  the reason attached.
  """

  use ExUnit.Case, async: false

  alias LemonHoncho.{Config, Owner, SessionManager, SessionName}
  alias LemonHoncho.Tools.Common
  alias LemonHoncho.ToolsCommonTest.StubClient

  @cwd "/tmp/lemon-honcho-common-test"
  @key "agent:common:main"

  # Configured, writable, tools enabled: the state every gate assertion below
  # varies one field of.
  @open %Config{api_key: "sk-test", user_peer: "user", ai_peer: "lemon"}

  setup do
    saved = Application.fetch_env(:lemon_honcho, :client)
    on_exit(fn -> restore(:client, saved) end)

    :ok
  end

  test "channel tool calls use the sender's owner peers; local tools the operator's" do
    config = %Config{@open | runtime_peer_prefix: "gateway_"}
    identity = %{channel_id: "discord", sender_id: "123"}
    key = "agent:demo:discord:default:dm:123"

    {:ok, channel} = Common.scope(config, session_key: key, channel_identity: identity)

    assert channel.owner.human == "gateway_discord_123"
    assert channel.owner == Owner.new(config, key, identity, "legacy")
    assert channel.peers == %{user: channel.owner.user_peer, ai: channel.owner.ai_peer}
    assert channel.peers.user =~ ~r/\Av2-u-gateway_discord_123-[0-9a-f]{32}\z/
    assert channel.peers.ai =~ ~r/\Av2-a-lemon-[0-9a-f]{32}\z/

    {:ok, local} = Common.scope(config, session_key: "untracked-cli")
    assert local.owner.human == config.user_peer
    refute local.peers.ai == channel.peers.ai
  end

  test "every part of the owner partitions the peers, assistant included" do
    base = Owner.new(@open, @key, nil, "legacy")

    for other <- [
          Owner.new(@open, "agent:other:main", nil, "legacy"),
          Owner.new(@open, @key, %{channel_id: "telegram", sender_id: "1"}, "legacy"),
          Owner.new(@open, @key, nil, "private:actor-a")
        ] do
      refute other.digest == base.digest
      refute other.user_peer == base.user_peer
      refute other.ai_peer == base.ai_peer
    end
  end

  test "a proven private context gets its own owner; an unproven claim gets no scope" do
    private = [
      session_key: @key,
      memory_context_key: "actor-a",
      invocation_context_key: "epoch-1",
      memory_context_verified: true
    ]

    assert {:ok, scope} = Common.scope(@open, private)
    assert scope.owner.memory == "private:actor-a"

    {:ok, legacy} = Common.scope(@open, session_key: @key)
    refute scope.session_id == legacy.session_id
    refute scope.peers.user == legacy.peers.user
    refute scope.peers.ai == legacy.peers.ai

    for claim <- [
          Keyword.delete(private, :invocation_context_key),
          Keyword.put(private, :memory_context_verified, false)
        ] do
      assert Common.scope(@open, claim) == {:error, :unproven_context}
    end
  end

  describe "gate/2" do
    test "an unconfigured Honcho is refused for both accesses" do
      config = %Config{}

      assert Common.gate(config) == {:error, :not_configured}
      assert Common.gate(config, :read) == {:error, :not_configured}
      assert Common.gate(config, :write) == {:error, :not_configured}
    end

    test "a disabled integration is unconfigured however good its credentials" do
      assert Common.gate(%Config{@open | enabled?: false}) == {:error, :not_configured}
    end

    test "context-only mode is refused for both accesses" do
      config = %Config{@open | recall_mode: :context}

      assert Common.gate(config, :read) == {:error, :context_only}
      assert Common.gate(config, :write) == {:error, :context_only}
    end

    test "uploads disabled refuses a write and permits a read" do
      config = %Config{@open | save_messages?: false}

      assert Common.gate(config, :read) == :ok
      assert Common.gate(config) == :ok
      assert Common.gate(config, :write) == {:error, :uploads_disabled}
    end

    test "an open integration permits both" do
      assert Common.gate(@open, :read) == :ok
      assert Common.gate(@open, :write) == :ok
    end

    # The order is the answer's usefulness, not the check's cost: an operator
    # who has set nothing at all should be told to set a key, not told that
    # uploads are off.
    test "the reason reported is the outermost one that applies" do
      config = %Config{recall_mode: :context, save_messages?: false}

      assert Common.gate(config, :write) == {:error, :not_configured}

      config = %Config{config | api_key: "sk-test"}

      assert Common.gate(config, :write) == {:error, :context_only}
    end

    test "gate/1 is gate/2 asking for read access" do
      Enum.each(
        [
          %Config{},
          @open,
          %Config{@open | save_messages?: false},
          %Config{@open | recall_mode: :context}
        ],
        fn config -> assert Common.gate(config) == Common.gate(config, :read) end
      )
    end
  end

  describe "session_key/1" do
    test "session_key wins over both of the others" do
      opts = [session_key: "chosen", session_id: "ignored", cwd: "/ignored"]

      assert Common.session_key(opts) == "chosen"
    end

    test "session_id is used when there is no session key" do
      assert Common.session_key(session_id: "run-7", cwd: "/ignored") == "run-7"
    end

    test "cwd is the last resort" do
      assert Common.session_key(cwd: @cwd) == @cwd
    end

    test "naming none of the three yields nil" do
      assert Common.session_key([]) == nil
      assert Common.session_key(model: "opus") == nil
    end

    # A gateway that always sets `:session_key` and sometimes sets it to "" is
    # the case this protects: keying on the blank string would collect every
    # anonymous run into one session's memory.
    test "a blank value falls through to the next in the order" do
      assert Common.session_key(session_key: "", session_id: "run-7") == "run-7"
      assert Common.session_key(session_key: "   ", session_id: "run-7") == "run-7"
      assert Common.session_key(session_key: "", session_id: "\n", cwd: @cwd) == @cwd
      assert Common.session_key(session_key: "", session_id: "", cwd: "") == nil
    end

    test "a value that is not a string is not a session key" do
      assert Common.session_key(session_key: :main, session_id: "run-7") == "run-7"
      assert Common.session_key(session_key: nil, session_id: 7, cwd: @cwd) == @cwd
    end
  end

  describe "present?/1" do
    test "a binary with something in it is present" do
      assert Common.present?("x")
      assert Common.present?(" x ")
      assert Common.present?(@cwd)
    end

    test "blank and non-binary values are absent" do
      refute Common.present?("")
      refute Common.present?("   ")
      refute Common.present?("\n\t ")
      refute Common.present?(nil)
      refute Common.present?(:main)
      refute Common.present?(7)
      refute Common.present?(["a"])
    end
  end

  defp owner, do: Owner.new(@open, @key, nil, "legacy")
  defp owner_peers, do: %{user: owner().user_peer, ai: owner().ai_peer}

  # The id the manager derives for `@key` served from `@cwd` by the operator.
  defp manager_derived_id do
    SessionName.resolve(@open, cwd: @cwd, session_key: @key, session_id: nil, owner: owner())
  end

  describe "client/0" do
    test "it follows the configured client seam" do
      Application.put_env(:lemon_honcho, :client, StubClient)
      assert Common.client() == StubClient
    end
  end

  describe "without a running session manager" do
    setup do
      stop_application_manager()
      :ok
    end

    test "latest_session_key/0 answers nil rather than raising" do
      assert Common.latest_session_key() == nil
    end

    test "scope/2 derives the session the manager would, with the owner's peers" do
      {:ok, scope} = Common.scope(@open, cwd: @cwd, session_key: @key)

      refute scope.mapped?
      assert scope.session_id == manager_derived_id()
      assert scope.peers == owner_peers()
    end
  end

  describe "with a session the manager has served" do
    setup do
      stop_application_manager()
      Application.put_env(:lemon_honcho, :client, StubClient)

      start_supervised!(
        {SessionManager,
         config: %Config{
           api_key: "sk-test",
           user_peer: "user",
           ai_peer: "lemon",
           first_turn_wait_ms: 2_000
         },
         client: StubClient}
      )

      # One turn of context is what resolves the Honcho session id for a key.
      serve(@key, @cwd)

      :ok
    end

    test "scope/2 uses the manager's session id and the owner's peers" do
      {:ok, scope} = Common.scope(@open, cwd: @cwd, session_key: @key)

      assert scope.mapped?
      assert {:ok, scope.session_id} == SessionManager.honcho_session_id(entry_key())
      assert scope.session_id == manager_derived_id()
      assert scope.peers == owner_peers()
    end

    # The whole point of the precedence rule: the key the manager served under
    # is the key the tool has to ask with, whatever else the opts carry.
    test "scope/2 follows the precedence rule to the served session" do
      {:ok, mapped} = Common.scope(@open, cwd: "/tmp/somewhere-else", session_key: @key)

      assert mapped.mapped?

      {:ok, unmapped} =
        Common.scope(@open, cwd: "/tmp/somewhere-else", session_key: "never-served")

      refute unmapped.mapped?
    end

    test "latest_session_key/0 returns the most recently served session" do
      # A later wall-clock reading is what makes this deterministic; the two
      # serves would otherwise be able to share a millisecond.
      Process.sleep(5)
      serve("agent:common:second", "/tmp/lemon-honcho-common-test-2")

      assert Common.latest_session_key() == "agent:common:second"
    end

    test "a tool whose opts name no session never borrows the most recent one" do
      {:ok, scope} = Common.scope(@open, [])

      refute scope.mapped?
      refute {:ok, scope.session_id} == SessionManager.honcho_session_id(entry_key())
    end
  end

  defp entry_key, do: SessionManager.entry_key(@key, owner())

  test "excerpt rendering shares fallback fields, labels, and clipping" do
    keys = {["content", "text"], ["peer_id", "author"]}
    hit = %{"content" => " ", "text" => "hello", "author" => "user", "timestamp" => "today"}

    assert Common.excerpt(hit, keys) == "user · today\nhello"

    assert Common.excerpt(%{"content" => String.duplicate("é", 1_001)}, keys) ==
             String.duplicate("é", 1_000)

    assert Common.excerpt(%{"unknown" => true}, keys) == inspect(%{"unknown" => true})
    assert Common.excerpt("raw", keys) == inspect("raw")
  end

  ## Helpers

  defp serve(key, cwd) do
    SessionManager.context_for(%{
      cwd: cwd,
      session_key: key,
      session_scope: :main,
      query: "why is the build slow?"
    })
  end

  # The application does not start a manager under `MIX_ENV=test`, but a stray
  # one from another test would answer these calls with its own sessions.
  defp stop_application_manager do
    if is_pid(Process.whereis(SessionManager)) do
      Supervisor.terminate_child(LemonHoncho.Supervisor, SessionManager)
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  defp restore(key, :error), do: Application.delete_env(:lemon_honcho, key)
  defp restore(key, {:ok, value}), do: Application.put_env(:lemon_honcho, key, value)
end
