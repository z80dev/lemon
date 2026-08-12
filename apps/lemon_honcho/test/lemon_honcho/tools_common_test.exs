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

  alias LemonHoncho.{Config, SessionManager, SessionName}
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

  describe "peers/2" do
    test "no key yields the configured pair" do
      assert Common.peers(@open, nil) == %{user: "user", ai: "lemon"}
    end

    test "a key the manager has never seen yields the configured pair" do
      assert Common.peers(@open, "never-served") == %{user: "user", ai: "lemon"}
    end
  end

  describe "derived_session_id/2" do
    test "it derives the id the session manager itself would derive" do
      opts = [cwd: @cwd, session_key: @key]

      assert Common.derived_session_id(@open, opts) ==
               SessionName.resolve(@open, cwd: @cwd, session_key: @key, session_id: nil)
    end

    test "it always returns a usable id, even with nothing to go on" do
      assert is_binary(Common.derived_session_id(@open, []))
      assert Common.derived_session_id(@open, []) != ""
    end
  end

  describe "client/0" do
    test "it defaults to the real client and follows the test seam" do
      Application.delete_env(:lemon_honcho, :client)
      assert Common.client() == LemonHoncho.Client

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

    test "scope/2 derives the session and falls back to the configured peers" do
      scope = Common.scope(@open, cwd: @cwd, session_key: @key)

      refute scope.mapped?
      assert scope.session_id == Common.derived_session_id(@open, cwd: @cwd, session_key: @key)
      assert scope.peers == %{user: "user", ai: "lemon"}
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

    test "scope/2 uses the manager's session id and the peers it recorded" do
      scope = Common.scope(@open, cwd: @cwd, session_key: @key)

      assert scope.mapped?
      assert {:ok, scope.session_id} == SessionManager.honcho_session_id(@key)
      assert scope.peers == %{user: "user", ai: "lemon"}
    end

    # The whole point of the precedence rule: the key the manager served under
    # is the key the tool has to ask with, whatever else the opts carry.
    test "scope/2 follows the precedence rule to the served session" do
      mapped = Common.scope(@open, cwd: "/tmp/somewhere-else", session_key: @key)

      assert mapped.mapped?

      unmapped = Common.scope(@open, cwd: "/tmp/somewhere-else", session_key: "never-served")

      refute unmapped.mapped?
    end

    test "latest_session_key/0 returns the most recently served session" do
      # A later wall-clock reading is what makes this deterministic; the two
      # serves would otherwise be able to share a millisecond.
      Process.sleep(5)
      serve("agent:common:second", "/tmp/lemon-honcho-common-test-2")

      assert Common.latest_session_key() == "agent:common:second"
    end

    test "latest_session_key/0 is the fallback when the opts name no session" do
      scope = Common.scope(@open, [])

      assert scope.mapped?
      assert {:ok, scope.session_id} == SessionManager.honcho_session_id(@key)
    end
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
