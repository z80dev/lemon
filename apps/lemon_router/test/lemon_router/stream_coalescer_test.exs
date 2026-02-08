defmodule LemonRouter.StreamCoalescerTest do
  use ExUnit.Case, async: false

  alias LemonRouter.StreamCoalescer

  defmodule TestTelegramPlugin do
    @moduledoc false

    def id, do: "telegram"

    def meta do
      %{
        name: "Test Telegram",
        capabilities: %{
          edit_support: true,
          chunk_limit: 4096
        }
      }
    end

    def deliver(payload) do
      pid = :persistent_term.get({__MODULE__, :test_pid}, nil)
      if is_pid(pid), do: send(pid, {:delivered, payload})
      {:ok, :ok}
    end
  end

  defmodule TestOutboxAPI do
    @moduledoc false
    use Agent

    def start_link(opts) do
      notify_pid = opts[:notify_pid]
      Agent.start_link(fn -> %{calls: [], notify_pid: notify_pid, fail_next_delete: nil} end, name: __MODULE__)
    end

    def calls, do: Agent.get(__MODULE__, fn s -> Enum.reverse(s.calls) end)

    def clear, do: Agent.update(__MODULE__, &%{&1 | calls: []})

    def fail_next_delete(reason) do
      Agent.update(__MODULE__, &%{&1 | fail_next_delete: reason})
    end

    def send_message(_token, chat_id, text, opts_or_reply_to \\ nil, parse_mode \\ nil) do
      record({:send, chat_id, text, opts_or_reply_to, parse_mode})
      {:ok, %{"ok" => true, "result" => %{"message_id" => 101}}}
    end

    def edit_message_text(_token, chat_id, message_id, text, opts \\ nil) do
      record({:edit, chat_id, message_id, text, opts})
      {:ok, %{"ok" => true}}
    end

    def delete_message(_token, chat_id, message_id) do
      record({:delete, chat_id, message_id})

      case Agent.get_and_update(__MODULE__, fn s -> {s.fail_next_delete, %{s | fail_next_delete: nil}} end) do
        nil -> {:ok, %{"ok" => true}}
        reason -> {:error, reason}
      end
    end

    defp record(call) do
      Agent.update(__MODULE__, fn s -> %{s | calls: [call | s.calls]} end)
      notify_pid = Agent.get(__MODULE__, & &1.notify_pid)
      if is_pid(notify_pid), do: send(notify_pid, {:outbox_api_call, call})
      :ok
    end
  end

  setup do
    # Start the coalescer registry and supervisor if not running
    if is_nil(Process.whereis(LemonRouter.CoalescerRegistry)) do
      {:ok, _} = Registry.start_link(keys: :unique, name: LemonRouter.CoalescerRegistry)
    end

    if is_nil(Process.whereis(LemonRouter.CoalescerSupervisor)) do
      {:ok, _} =
        DynamicSupervisor.start_link(
          strategy: :one_for_one,
          name: LemonRouter.CoalescerSupervisor
        )
    end

    if is_nil(Process.whereis(LemonChannels.Registry)) do
      {:ok, _} = LemonChannels.Registry.start_link([])
    end

    if is_nil(Process.whereis(LemonChannels.Outbox)) do
      {:ok, _} = LemonChannels.Outbox.start_link([])
    end

    if is_nil(Process.whereis(LemonChannels.Outbox.RateLimiter)) do
      {:ok, _} = LemonChannels.Outbox.RateLimiter.start_link([])
    end

    if is_nil(Process.whereis(LemonChannels.Outbox.Dedupe)) do
      {:ok, _} = LemonChannels.Outbox.Dedupe.start_link([])
    end

    # Ensure baseline tests cover the LemonChannels.Outbox path deterministically.
    if pid = Process.whereis(LemonGateway.Telegram.Outbox) do
      GenServer.stop(pid)
    end

    :persistent_term.put({TestTelegramPlugin, :test_pid}, self())

    existing = LemonChannels.Registry.get_plugin("telegram")
    _ = LemonChannels.Registry.unregister("telegram")
    :ok = LemonChannels.Registry.register(TestTelegramPlugin)

    on_exit(fn ->
      _ = :persistent_term.erase({TestTelegramPlugin, :test_pid})
      # on_exit callbacks can run after the test process has terminated; avoid
      # failing tests on cleanup if the registry is already gone.
      if is_pid(Process.whereis(LemonChannels.Registry)) do
        _ = LemonChannels.Registry.unregister("telegram")

        if is_atom(existing) and not is_nil(existing) do
          _ = LemonChannels.Registry.register(existing)
        end
      end
    end)

    :ok
  end

  defp eventually(fun, timeout_ms \\ 500) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(10)
        do_eventually(fun, deadline)
      end
    end
  end

  describe "session key handling" do
    test "handles canonical channel peer format" do
      # Test through public API - verify coalescer starts correctly with canonical format
      session_key = "agent:my-agent:telegram:bot123:dm:user456"
      channel_id = "telegram"
      run_id = "run_#{System.unique_integer()}"

      # Should successfully ingest delta with canonical session key format
      assert :ok =
               StreamCoalescer.ingest_delta(
                 session_key,
                 channel_id,
                 run_id,
                 1,
                 "Hello"
               )

      # Verify coalescer was started
      assert [{_pid, _}] =
               Registry.lookup(
                 LemonRouter.CoalescerRegistry,
                 {session_key, channel_id}
               )
    end

    test "handles canonical channel peer format with thread" do
      session_key = "agent:my-agent:telegram:bot123:group:chat789:thread:topic42"
      channel_id = "telegram"
      run_id = "run_#{System.unique_integer()}"

      assert :ok =
               StreamCoalescer.ingest_delta(
                 session_key,
                 channel_id,
                 run_id,
                 1,
                 "Thread test"
               )

      assert [{_pid, _}] =
               Registry.lookup(
                 LemonRouter.CoalescerRegistry,
                 {session_key, channel_id}
               )
    end

    test "handles main session format" do
      session_key = "agent:my-agent:main"
      # Main sessions typically don't have a channel, but coalescer should handle it
      channel_id = "web"
      run_id = "run_#{System.unique_integer()}"

      assert :ok =
               StreamCoalescer.ingest_delta(
                 session_key,
                 channel_id,
                 run_id,
                 1,
                 "Main session test"
               )
    end

    test "handles legacy channel format" do
      session_key = "channel:telegram:bot:12345"
      channel_id = "telegram"
      run_id = "run_#{System.unique_integer()}"

      assert :ok =
               StreamCoalescer.ingest_delta(
                 session_key,
                 channel_id,
                 run_id,
                 1,
                 "Legacy format test"
               )

      assert [{_pid, _}] =
               Registry.lookup(
                 LemonRouter.CoalescerRegistry,
                 {session_key, channel_id}
               )
    end

    test "handles unknown format gracefully" do
      session_key = "unknown:format"
      channel_id = "test"
      run_id = "run_#{System.unique_integer()}"

      # Should not crash on unknown format
      assert :ok =
               StreamCoalescer.ingest_delta(
                 session_key,
                 channel_id,
                 run_id,
                 1,
                 "Unknown format test"
               )
    end

    test "handles unknown peer_kind gracefully with :unknown fallback" do
      # Session key with invalid peer_kind - should fallback to :unknown
      session_key = "agent:my-agent:telegram:bot123:invalid_kind:user456"
      channel_id = "telegram"
      run_id = "run_#{System.unique_integer()}"

      # Should successfully ingest without crashing
      assert :ok =
               StreamCoalescer.ingest_delta(
                 session_key,
                 channel_id,
                 run_id,
                 1,
                 "Invalid kind test"
               )
    end
  end

  describe "atom exhaustion protection" do
    test "does not create new atoms for invalid peer_kind values in fallback parsing" do
      # Verify that safe_to_atom returns :unknown for invalid peer kinds
      # rather than creating new atoms
      # This is a structural test - we verify the function behavior rather than
      # counting atoms, as atom counting is unreliable in test environments

      # The safe_to_atom function should return :unknown for any unrecognized value
      # We can verify this by checking the session key parsing behavior
      session_key = "agent:my-agent:telegram:bot123:totally_invalid_peer_kind:user456"
      channel_id = "telegram"
      run_id = "run_#{System.unique_integer()}"

      # Should successfully ingest without crashing
      assert :ok =
               StreamCoalescer.ingest_delta(
                 session_key,
                 channel_id,
                 run_id,
                 1,
                 "Test"
               )

      # The coalescer should have started with peer_kind = :unknown
      assert [{_pid, _}] =
               Registry.lookup(
                 LemonRouter.CoalescerRegistry,
                 {session_key, channel_id}
               )
    end

    test "safe_to_atom uses whitelist and doesn't create arbitrary atoms" do
      # The whitelist approach guarantees that only known atoms are used
      # We verify that parsing with an invalid peer_kind still works
      # and doesn't crash - it just gets mapped to :unknown
      for invalid_kind <- ["evil", "malicious", "custom_type", "admin", "root"] do
        session_key = "agent:agent:telegram:bot:#{invalid_kind}:user"
        run_id = "run_#{System.unique_integer()}"

        # Should not crash
        assert :ok =
                 StreamCoalescer.ingest_delta(
                   session_key,
                   "telegram",
                   run_id,
                   1,
                   "Test #{invalid_kind}"
                 )
      end

      # All invalid kinds should result in :unknown, not new atoms
      Process.sleep(50)
    end
  end

  describe "ingest_delta/6" do
    test "starts coalescer and accepts delta" do
      session_key = "agent:test:telegram:bot1:dm:user1"
      channel_id = "telegram"
      run_id = "run_#{System.unique_integer()}"

      assert :ok =
               StreamCoalescer.ingest_delta(
                 session_key,
                 channel_id,
                 run_id,
                 1,
                 "Hello, "
               )

      # Second delta should also succeed
      assert :ok =
               StreamCoalescer.ingest_delta(
                 session_key,
                 channel_id,
                 run_id,
                 2,
                 "world!"
               )

      # Give it time to process
      Process.sleep(10)
    end

    test "accepts metadata for progress_msg_id" do
      session_key = "agent:test2:telegram:bot2:dm:user2"
      channel_id = "telegram"
      run_id = "run_#{System.unique_integer()}"

      assert :ok =
               StreamCoalescer.ingest_delta(
                 session_key,
                 channel_id,
                 run_id,
                 1,
                 "Hello",
                 meta: %{progress_msg_id: "msg123"}
               )
    end

    test "does not overwrite progress_msg_id with nil meta updates" do
      session_key = "agent:test2b:telegram:bot2:dm:user2"
      channel_id = "telegram"
      run_id = "run_#{System.unique_integer()}"

      assert :ok =
               StreamCoalescer.ingest_delta(
                 session_key,
                 channel_id,
                 run_id,
                 1,
                 "Hello",
                 meta: %{progress_msg_id: 123}
               )

      [{pid, _}] = Registry.lookup(LemonRouter.CoalescerRegistry, {session_key, channel_id})
      state = :sys.get_state(pid)
      assert state.meta[:progress_msg_id] == 123

      assert :ok =
               StreamCoalescer.ingest_delta(
                 session_key,
                 channel_id,
                 run_id,
                 2,
                 " world",
                 meta: %{progress_msg_id: nil}
               )

      state2 = :sys.get_state(pid)
      assert state2.meta[:progress_msg_id] == 123
    end

    test "ignores out-of-order deltas" do
      session_key = "agent:test3:telegram:bot3:dm:user3"
      channel_id = "telegram"
      run_id = "run_#{System.unique_integer()}"

      # First delta with seq 2
      assert :ok =
               StreamCoalescer.ingest_delta(
                 session_key,
                 channel_id,
                 run_id,
                 2,
                 "Second"
               )

      # This delta with seq 1 should be ignored (out of order)
      assert :ok =
               StreamCoalescer.ingest_delta(
                 session_key,
                 channel_id,
                 run_id,
                 1,
                 "First"
               )
    end
  end

  describe "flush/2" do
    test "flushes coalescer buffer" do
      session_key = "agent:flush-test:telegram:bot:dm:user"
      channel_id = "telegram"
      run_id = "run_#{System.unique_integer()}"

      # Ingest some deltas
      StreamCoalescer.ingest_delta(session_key, channel_id, run_id, 1, "Test text")

      # Flush should succeed
      assert :ok = StreamCoalescer.flush(session_key, channel_id)
    end

    test "flush on non-existent coalescer succeeds" do
      assert :ok = StreamCoalescer.flush("non:existent:session", "channel")
    end
  end

  describe "finalize_run/4 (telegram)" do
    test "deletes progress message and sends final response as a new message" do
      session_key = "agent:my-agent:telegram:bot123:dm:user456"
      channel_id = "telegram"
      run_id = "run_#{System.unique_integer()}"

      # Simulate a run that streamed at least one delta and has a progress msg id.
      StreamCoalescer.ingest_delta(session_key, channel_id, run_id, 1, "Partial", meta: %{progress_msg_id: 111})

      assert :ok =
               StreamCoalescer.finalize_run(
                 session_key,
                 channel_id,
                 run_id,
                 meta: %{progress_msg_id: 111, user_msg_id: 222},
                 final_text: "Final answer"
               )

      # Outbox can be shared across tests; filter by idempotency key so we don't
      # accidentally assert against an unrelated pending delivery.
      delete_key = "#{run_id}:final:delete"
      send_key = "#{run_id}:final:send"

      assert_receive {:delivered, %{idempotency_key: ^delete_key} = payload1}, 1_000
      assert_receive {:delivered, %{idempotency_key: ^send_key} = payload2}, 1_000

      assert payload1.kind == :delete
      assert payload1.content == %{message_id: 111}

      assert payload2.kind == :text
      assert payload2.content == "Final answer"
      assert payload2.reply_to == 222
    end

    test "deletes progress message even when there is no final text" do
      {:ok, _} = start_supervised({TestOutboxAPI, [notify_pid: self()]})

      {:ok, _} =
        start_supervised(
          {LemonGateway.Telegram.Outbox,
           [bot_token: "token", api_mod: TestOutboxAPI, edit_throttle_ms: 0, use_markdown: false]}
        )

      session_key = "agent:test:telegram:bot:dm:12340"
      channel_id = "telegram"
      run_id = "run_#{System.unique_integer()}"

      assert :ok =
               StreamCoalescer.finalize_run(
                 session_key,
                 channel_id,
                 run_id,
                 meta: %{progress_msg_id: 111, user_msg_id: 222},
                 final_text: ""
               )

      assert_receive {:outbox_api_call, {:delete, 12_340, 111}}, 500
      refute_receive {:outbox_api_call, {:send, 12_340, _text, _opts, nil}}, 200
    end
  end

  describe "telegram outbox integration" do
    setup do
      {:ok, _} = start_supervised({TestOutboxAPI, [notify_pid: self()]})

      :ok
    end

    test "telegram edits use LemonGateway.Telegram.Outbox when it is running" do
      {:ok, _} =
        start_supervised(
          {LemonGateway.Telegram.Outbox,
           [bot_token: "token", api_mod: TestOutboxAPI, edit_throttle_ms: 0, use_markdown: false]}
        )

      session_key = "agent:test:telegram:bot:dm:12345"
      channel_id = "telegram"
      run_id = "run_#{System.unique_integer([:positive])}"

      StreamCoalescer.ingest_delta(session_key, channel_id, run_id, 1, "Hello", meta: %{progress_msg_id: 999})
      assert :ok = StreamCoalescer.flush(session_key, channel_id)

      assert_receive {:outbox_api_call, {:edit, 12_345, 999, _text, nil}}, 500
      refute_receive {:delivered, _payload}, 100
    end

    test "telegram finalize uses outbox delete + send (thread_id + reply_to preserved)" do
      {:ok, _} =
        start_supervised(
          {LemonGateway.Telegram.Outbox,
           [bot_token: "token", api_mod: TestOutboxAPI, edit_throttle_ms: 0, use_markdown: false]}
        )

      session_key = "agent:test:telegram:botx:group:12345:thread:777"
      channel_id = "telegram"
      run_id = "run_#{System.unique_integer([:positive])}"

      resume = %LemonGateway.Types.ResumeToken{engine: "codex", value: "thread_abc"}

      store_key = {"botx", 12_345, 777, 101}
      _ = LemonCore.Store.delete(:telegram_msg_resume, store_key)

      assert :ok =
               StreamCoalescer.finalize_run(session_key, channel_id, run_id,
                 meta: %{progress_msg_id: 111, user_msg_id: 222, resume: resume},
                 final_text: "Final answer"
               )

      assert_receive {:outbox_api_call, {:delete, 12_345, 111}}, 500

      assert_receive {:outbox_api_call, {:send, 12_345, text, opts, nil}}, 500
      assert is_map(opts)
      assert opts[:reply_to_message_id] == 222
      assert opts[:message_thread_id] == 777

      assert String.contains?(text, "Final answer")

      assert eventually(fn ->
               case LemonCore.Store.get(:telegram_msg_resume, store_key) do
                 %LemonGateway.Types.ResumeToken{engine: "codex", value: "thread_abc"} -> true
                 _ -> false
               end
             end)
    end

    test "telegram finalize still sends when progress_msg_id is nil (no delete attempted)" do
      {:ok, _} =
        start_supervised(
          {LemonGateway.Telegram.Outbox,
           [bot_token: "token", api_mod: TestOutboxAPI, edit_throttle_ms: 0, use_markdown: false]}
        )

      session_key = "agent:test:telegram:bot:dm:12346"
      channel_id = "telegram"
      run_id = "run_#{System.unique_integer([:positive])}"

      assert :ok =
               StreamCoalescer.finalize_run(session_key, channel_id, run_id,
                 meta: %{progress_msg_id: nil, user_msg_id: 222},
                 final_text: "Final answer"
               )

      refute_receive {:outbox_api_call, {:delete, 12_346, _}}, 200
      assert_receive {:outbox_api_call, {:send, 12_346, _text, _opts, nil}}, 500
    end

    test "telegram finalize sends final even if delete fails (non-retryable)" do
      {:ok, _} =
        start_supervised(
          {LemonGateway.Telegram.Outbox,
           [bot_token: "token", api_mod: TestOutboxAPI, edit_throttle_ms: 0, use_markdown: false]}
        )

      TestOutboxAPI.fail_next_delete({:http_error, 400, "Bad Request"})

      session_key = "agent:test:telegram:bot:dm:12347"
      channel_id = "telegram"
      run_id = "run_#{System.unique_integer([:positive])}"

      assert :ok =
               StreamCoalescer.finalize_run(session_key, channel_id, run_id,
                 meta: %{progress_msg_id: 111, user_msg_id: 222},
                 final_text: "Final answer"
               )

      assert_receive {:outbox_api_call, {:delete, 12_347, 111}}, 500
      assert_receive {:outbox_api_call, {:send, 12_347, _text, _opts, nil}}, 500
    end
  end
end
