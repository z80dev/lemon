defmodule LemonRouter.RouterPendingCompactionTest do
  @moduledoc """
  Tests for the generic pending-compaction consumer in Router.

  Covers:
  - Generic marker consumption and deletion
  - Stale marker behavior
  - auto_compacted guard (no double-injection)
  """
  use ExUnit.Case, async: false

  alias LemonRouter.Router
  alias LemonCore.InboundMessage

  defmodule RunOrchestratorStub do
    def submit(request) do
      if pid = Process.get(:router_test_pid) do
        send(pid, {:orchestrator_submit, request})
      end

      Process.get(:router_submit_result, {:ok, "run_stub"})
    end
  end

  setup do
    start_if_needed(LemonRouter.RunRegistry, fn ->
      Registry.start_link(keys: :unique, name: LemonRouter.RunRegistry)
    end)

    start_if_needed(LemonRouter.SessionRegistry, fn ->
      Registry.start_link(keys: :unique, name: LemonRouter.SessionRegistry)
    end)

    previous_orchestrator = Application.get_env(:lemon_router, :run_orchestrator)
    Application.put_env(:lemon_router, :run_orchestrator, RunOrchestratorStub)

    Process.put(:router_test_pid, self())
    Process.delete(:router_submit_result)

    on_exit(fn ->
      case previous_orchestrator do
        nil -> Application.delete_env(:lemon_router, :run_orchestrator)
        mod -> Application.put_env(:lemon_router, :run_orchestrator, mod)
      end

      Process.delete(:router_test_pid)
      Process.delete(:router_submit_result)
    end)

    :ok
  end

  defp start_if_needed(name, start_fn) do
    if is_nil(Process.whereis(name)) do
      {:ok, _} = start_fn.()
    end
  end

  defp make_inbound(channel_id, peer_id, text, meta \\ %{}) do
    %InboundMessage{
      channel_id: channel_id,
      account_id: "default",
      peer: %{kind: :dm, id: peer_id, thread_id: nil},
      sender: %{id: "sender-1"},
      message: %{id: "1", text: text, timestamp: nil, reply_to_id: nil},
      raw: %{},
      meta: Map.merge(%{"agent_id" => "test-agent"}, meta)
    }
  end

  describe "maybe_apply_pending_compaction/3" do
    test "consumes a fresh pending_compaction marker and modifies the prompt" do
      session_key = "agent:test-agent:api:default:dm:pc_#{System.unique_integer([:positive])}"
      msg = make_inbound("api", "pc_test", "hello")
      meta = msg.meta || %{}

      # Seed run history for the session (key format: {session_key, timestamp_ms, run_id})
      LemonCore.Store.put(
        :run_history,
        {session_key, System.system_time(:millisecond), "run1"},
        %{summary: %{prompt: "What is 2+2?", answer: "4"}}
      )

      # Set a fresh pending compaction marker
      LemonCore.Store.put(:pending_compaction, session_key, %{
        reason: "near_limit",
        session_key: session_key,
        set_at_ms: System.system_time(:millisecond),
        input_tokens: 100_000,
        threshold_tokens: 90_000,
        context_window_tokens: 128_000
      })

      {new_msg, new_meta} = Router.maybe_apply_pending_compaction(msg, meta, session_key)

      # Marker should be deleted
      assert LemonCore.Store.get(:pending_compaction, session_key) == nil

      # Meta should be marked as auto_compacted
      assert new_meta[:auto_compacted] == true

      # Prompt should contain the compaction context
      assert new_msg.message.text =~ "previous conversation"
      assert new_msg.message.text =~ "What is 2+2?"
      assert new_msg.message.text =~ "hello"

      # Clean up — run_history keys are tuple-keyed; deleting all matching entries
      # isn't critical for test isolation since session_keys are unique per test.
    end

    test "deletes stale marker and does not modify the prompt" do
      session_key = "agent:test-agent:api:default:dm:stale_#{System.unique_integer([:positive])}"
      msg = make_inbound("api", "stale_test", "hi")
      meta = msg.meta || %{}

      # Set a stale marker (13 hours ago)
      stale_ms = System.system_time(:millisecond) - 13 * 60 * 60 * 1000

      LemonCore.Store.put(:pending_compaction, session_key, %{
        reason: "near_limit",
        session_key: session_key,
        set_at_ms: stale_ms,
        input_tokens: 100_000,
        threshold_tokens: 90_000,
        context_window_tokens: 128_000
      })

      {new_msg, new_meta} = Router.maybe_apply_pending_compaction(msg, meta, session_key)

      # Stale marker should be deleted
      assert LemonCore.Store.get(:pending_compaction, session_key) == nil

      # Prompt should NOT be modified
      assert new_msg.message.text == "hi"
      assert new_meta[:auto_compacted] != true
    end

    test "skips compaction when meta already has auto_compacted=true" do
      session_key = "agent:test-agent:api:default:dm:guard_#{System.unique_integer([:positive])}"
      msg = make_inbound("api", "guard_test", "hello")
      meta = Map.put(msg.meta || %{}, :auto_compacted, true)

      # Set a fresh marker
      LemonCore.Store.put(:pending_compaction, session_key, %{
        reason: "near_limit",
        session_key: session_key,
        set_at_ms: System.system_time(:millisecond),
        input_tokens: 100_000,
        threshold_tokens: 90_000,
        context_window_tokens: 128_000
      })

      {new_msg, new_meta} = Router.maybe_apply_pending_compaction(msg, meta, session_key)

      # Generic marker should be deleted to avoid double-injection on later turns.
      assert LemonCore.Store.get(:pending_compaction, session_key) == nil

      # Prompt should be unmodified
      assert new_msg.message.text == "hello"
      assert new_meta[:auto_compacted] == true

      # Marker should be deleted to avoid repeated futile attempts.
      assert LemonCore.Store.get(:pending_compaction, session_key) == nil
    end

    test "skips compaction when meta has string key auto_compacted=true" do
      session_key = "agent:test-agent:api:default:dm:strg_#{System.unique_integer([:positive])}"
      msg = make_inbound("api", "strg_test", "hello")
      meta = Map.put(msg.meta || %{}, "auto_compacted", true)

      LemonCore.Store.put(:pending_compaction, session_key, %{
        reason: "near_limit",
        session_key: session_key,
        set_at_ms: System.system_time(:millisecond),
        input_tokens: 100_000,
        threshold_tokens: 90_000,
        context_window_tokens: 128_000
      })

      {new_msg, _new_meta} = Router.maybe_apply_pending_compaction(msg, meta, session_key)

      # Prompt should be unmodified
      assert new_msg.message.text == "hello"

      # Generic marker should be deleted to avoid double-injection on later turns.
      assert LemonCore.Store.get(:pending_compaction, session_key) == nil
    end

    test "passes through cleanly when no marker exists" do
      session_key = "agent:test-agent:api:default:dm:none_#{System.unique_integer([:positive])}"
      msg = make_inbound("api", "none_test", "hello")
      meta = msg.meta || %{}

      {new_msg, new_meta} = Router.maybe_apply_pending_compaction(msg, meta, session_key)

      assert new_msg.message.text == "hello"
      assert new_meta[:auto_compacted] != true
    end

    test "handles empty run history gracefully (no compaction applied)" do
      session_key = "agent:test-agent:api:default:dm:empty_#{System.unique_integer([:positive])}"
      msg = make_inbound("api", "empty_test", "hello")
      meta = msg.meta || %{}

      LemonCore.Store.put(:pending_compaction, session_key, %{
        reason: "near_limit",
        session_key: session_key,
        set_at_ms: System.system_time(:millisecond),
        input_tokens: 100_000,
        threshold_tokens: 90_000,
        context_window_tokens: 128_000
      })

      {new_msg, new_meta} = Router.maybe_apply_pending_compaction(msg, meta, session_key)

      # With empty history, no compaction should be applied
      assert new_msg.message.text == "hello"
      assert new_meta[:auto_compacted] != true

      # Clean up
      _ = LemonCore.Store.delete(:pending_compaction, session_key)
    end
  end

  describe "handle_inbound/1 with pending compaction" do
    test "applies pending compaction before submitting to orchestrator for non-Telegram channel" do
      peer_id = "api_#{System.unique_integer([:positive])}"
      session_key = "agent:test-agent:api:default:dm:#{peer_id}"
      msg = make_inbound("api", peer_id, "continue please")

      # Seed run history (key format: {session_key, timestamp_ms, run_id})
      LemonCore.Store.put(
        :run_history,
        {session_key, System.system_time(:millisecond), "run1"},
        %{summary: %{prompt: "previous task", answer: "I completed the task"}}
      )

      LemonCore.Store.put(:pending_compaction, session_key, %{
        reason: "near_limit",
        session_key: session_key,
        set_at_ms: System.system_time(:millisecond),
        input_tokens: 100_000,
        threshold_tokens: 90_000,
        context_window_tokens: 128_000
      })

      assert :ok = Router.handle_inbound(msg)

      assert_receive {:orchestrator_submit, request}, 500

      # The prompt should have been modified with compaction context
      assert request.prompt =~ "previous conversation"
      assert request.prompt =~ "previous task"
      assert request.prompt =~ "continue please"
      assert request.meta[:auto_compacted] == true

      # Marker should be consumed
      assert LemonCore.Store.get(:pending_compaction, session_key) == nil

      # Clean up — run_history keys are tuple-keyed; deleting all matching entries
      # isn't critical for test isolation since session_keys are unique per test.
    end
  end

  describe "build_pending_compaction_prompt/2" do
    test "includes transcript and user text" do
      result = Router.build_pending_compaction_prompt("transcript here", "user question")
      assert result =~ "previous_conversation"
      assert result =~ "transcript here"
      assert result =~ "user question"
    end

    test "uses Continue. when user text is empty" do
      result = Router.build_pending_compaction_prompt("transcript here", "")
      assert result =~ "Continue."
      refute result =~ "User:"
    end
  end
end
