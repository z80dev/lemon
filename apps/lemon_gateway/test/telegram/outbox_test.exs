defmodule LemonGateway.Telegram.OutboxTest do
  use ExUnit.Case, async: false

  alias LemonGateway.Telegram.Outbox

  defmodule MockOutboxAPI do
    @moduledoc "Basic mock API for Outbox tests"
    use Agent

    def start_link(opts) do
      notify_pid = opts[:notify_pid]

      Agent.start_link(
        fn -> %{calls: [], notify_pid: notify_pid, fail_next: nil} end,
        name: __MODULE__
      )
    end

    def set_notify_pid(pid) do
      Agent.update(__MODULE__, &%{&1 | notify_pid: pid})
    end

    def calls do
      Agent.get(__MODULE__, fn state -> Enum.reverse(state.calls) end)
    end

    def clear do
      Agent.update(__MODULE__, &%{&1 | calls: []})
    end

    def fail_next(error) do
      Agent.update(__MODULE__, &%{&1 | fail_next: error})
    end

    # The outbox may call send_message/5 with either:
    # - reply_to_message_id (legacy), or
    # - an opts map (preferred; supports thread_id + entities).
    def send_message(_token, chat_id, text, opts_or_reply_to \\ nil, parse_mode \\ nil) do
      record({:send, chat_id, text, opts_or_reply_to, parse_mode})
      maybe_fail_or_succeed(%{"ok" => true, "result" => %{"message_id" => 1}})
    end

    def edit_message_text(_token, chat_id, message_id, text, opts \\ nil) do
      record({:edit, chat_id, message_id, text, opts})
      maybe_fail_or_succeed(%{"ok" => true})
    end

    def delete_message(_token, chat_id, message_id) do
      record({:delete, chat_id, message_id})
      maybe_fail_or_succeed(%{"ok" => true})
    end

    defp maybe_fail_or_succeed(success_result) do
      fail_next = Agent.get(__MODULE__, & &1.fail_next)

      if fail_next do
        Agent.update(__MODULE__, &%{&1 | fail_next: nil})
        {:error, fail_next}
      else
        {:ok, success_result}
      end
    end

    defp record(call) do
      Agent.update(__MODULE__, fn state -> %{state | calls: [call | state.calls]} end)
      notify_pid = Agent.get(__MODULE__, & &1.notify_pid)
      if is_pid(notify_pid), do: send(notify_pid, {:outbox_api_call, call})
      :ok
    end
  end

  defmodule TimingMockAPI do
    @moduledoc "Mock API that records timestamps for timing tests"
    use Agent

    def start_link(opts) do
      notify_pid = opts[:notify_pid]

      Agent.start_link(
        fn -> %{calls: [], notify_pid: notify_pid} end,
        name: __MODULE__
      )
    end

    def set_notify_pid(pid) do
      Agent.update(__MODULE__, &%{&1 | notify_pid: pid})
    end

    def calls do
      Agent.get(__MODULE__, fn state -> Enum.reverse(state.calls) end)
    end

    def send_message(_token, chat_id, text, opts_or_reply_to \\ nil, _parse_mode \\ nil) do
      record({:send, chat_id, text, opts_or_reply_to, System.monotonic_time(:millisecond)})
      {:ok, %{"ok" => true, "result" => %{"message_id" => 1}}}
    end

    def edit_message_text(_token, chat_id, message_id, text, _opts \\ nil) do
      record({:edit, chat_id, message_id, text, System.monotonic_time(:millisecond)})
      {:ok, %{"ok" => true}}
    end

    defp record(call) do
      Agent.update(__MODULE__, fn state -> %{state | calls: [call | state.calls]} end)
      notify_pid = Agent.get(__MODULE__, & &1.notify_pid)
      if is_pid(notify_pid), do: send(notify_pid, {:outbox_api_call, call})
      :ok
    end
  end

  setup do
    # Stop any existing outbox
    if pid = Process.whereis(LemonGateway.Telegram.Outbox) do
      GenServer.stop(pid)
    end

    :ok
  end

  describe "coalescing" do
    setup do
      {:ok, _} = start_supervised({MockOutboxAPI, [notify_pid: self()]})
      :ok
    end

    test "coalesces rapid edits for the same key" do
      {:ok, _} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 50]}
        )

      key = {1, 2, :edit}

      Outbox.enqueue(key, 0, {:edit, 1, 2, %{text: "first"}})
      Outbox.enqueue(key, 0, {:edit, 1, 2, %{text: "second"}})
      Outbox.enqueue(key, 0, {:edit, 1, 2, %{text: "third"}})

      # Wait for the operation to be processed
      Process.sleep(100)

      calls = MockOutboxAPI.calls()
      # Only the final value should be sent due to coalescing
      assert length(calls) == 1
      assert hd(calls) == {:edit, 1, 2, "third", nil}
    end

    test "different keys are not coalesced" do
      {:ok, _} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 50]}
        )

      key1 = {1, 2, :edit}
      key2 = {1, 3, :edit}
      key3 = {2, 2, :edit}

      Outbox.enqueue(key1, 0, {:edit, 1, 2, %{text: "msg1"}})
      Outbox.enqueue(key2, 0, {:edit, 1, 3, %{text: "msg2"}})
      Outbox.enqueue(key3, 0, {:edit, 2, 2, %{text: "msg3"}})

      # Wait for all operations to complete
      Process.sleep(200)

      # All three operations should be executed (different keys = no coalescing)
      calls = MockOutboxAPI.calls()
      assert length(calls) == 3
      assert {:edit, 1, 2, "msg1", nil} in calls
      assert {:edit, 1, 3, "msg2", nil} in calls
      assert {:edit, 2, 2, "msg3", nil} in calls
    end

    test "coalesces send operations for the same key" do
      {:ok, _} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 50]}
        )

      key = {1, :send}

      Outbox.enqueue(key, 0, {:send, 1, %{text: "first"}})
      Outbox.enqueue(key, 0, {:send, 1, %{text: "second"}})
      Outbox.enqueue(key, 0, {:send, 1, %{text: "final"}})

      # Wait for the operation to be processed
      Process.sleep(100)

      calls = MockOutboxAPI.calls()
      # Only the final value should be sent due to coalescing
      assert length(calls) == 1
      assert hd(calls) == {:send, 1, "final", %{}, nil}
    end

    test "coalescing preserves queue order for first occurrence" do
      {:ok, _} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 50]}
        )

      key1 = {1, 1, :edit}
      key2 = {1, 2, :edit}
      key3 = {1, 3, :edit}

      # Enqueue in order: key1, key2, key3, then update key1 and key2
      Outbox.enqueue(key1, 0, {:edit, 1, 1, %{text: "first-1"}})
      Outbox.enqueue(key2, 0, {:edit, 1, 2, %{text: "first-2"}})
      Outbox.enqueue(key3, 0, {:edit, 1, 3, %{text: "first-3"}})
      Outbox.enqueue(key1, 0, {:edit, 1, 1, %{text: "updated-1"}})
      Outbox.enqueue(key2, 0, {:edit, 1, 2, %{text: "updated-2"}})

      # Wait for all operations to complete
      Process.sleep(200)

      # Operations should be executed in original order (key1, key2, key3)
      # But with updated values for key1 and key2
      calls = MockOutboxAPI.calls()
      assert length(calls) == 3
      assert Enum.at(calls, 0) == {:edit, 1, 1, "updated-1", nil}
      assert Enum.at(calls, 1) == {:edit, 1, 2, "updated-2", nil}
      assert Enum.at(calls, 2) == {:edit, 1, 3, "first-3", nil}
    end

    test "only the final coalesced operation is executed" do
      {:ok, _} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 30]}
        )

      key = {1, 2, :edit}

      Outbox.enqueue(key, 0, {:edit, 1, 2, %{text: "first"}})
      Outbox.enqueue(key, 0, {:edit, 1, 2, %{text: "second"}})
      Outbox.enqueue(key, 0, {:edit, 1, 2, %{text: "third"}})

      # Wait for the operation to be processed
      assert_receive {:outbox_api_call, {:edit, 1, 2, "third", nil}}, 200

      calls = MockOutboxAPI.calls()
      # Only one call should have been made (the final coalesced one)
      assert length(calls) == 1
      assert hd(calls) == {:edit, 1, 2, "third", nil}
    end
  end

  describe "enqueue_with_notify/6" do
    setup do
      {:ok, _} = start_supervised({MockOutboxAPI, [notify_pid: self()]})
      :ok
    end

    test "notifies on success when edit_throttle_ms = 0" do
      {:ok, _} =
        start_supervised(
          {Outbox,
           [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 0, use_markdown: false]}
        )

      ref = make_ref()

      Outbox.enqueue_with_notify({1, :send}, 0, {:send, 1, %{text: "hi"}}, self(), ref)

      assert_receive {:outbox_delivered, ^ref, {:ok, _result}}, 200
    end

    test "notifies on success when edit_throttle_ms > 0" do
      {:ok, _} =
        start_supervised(
          {Outbox,
           [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 25, use_markdown: false]}
        )

      ref = make_ref()

      Outbox.enqueue_with_notify({1, :send}, 0, {:send, 1, %{text: "hi"}}, self(), ref)

      assert_receive {:outbox_delivered, ^ref, {:ok, _result}}, 500
    end
  end

  describe "throttling with edit_throttle_ms = 0" do
    setup do
      {:ok, _} = start_supervised({MockOutboxAPI, [notify_pid: self()]})
      :ok
    end

    test "executes operations immediately without queueing" do
      {:ok, _} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 0]}
        )

      Outbox.enqueue({1, 2, :edit}, 0, {:edit, 1, 2, %{text: "immediate1"}})
      Outbox.enqueue({1, 3, :edit}, 0, {:edit, 1, 3, %{text: "immediate2"}})
      Outbox.enqueue({1, 4, :edit}, 0, {:edit, 1, 4, %{text: "immediate3"}})

      # Give GenServer time to process the casts
      Process.sleep(50)

      # All calls should be executed immediately
      calls = MockOutboxAPI.calls()
      assert length(calls) == 3
      assert {:edit, 1, 2, "immediate1", nil} in calls
      assert {:edit, 1, 3, "immediate2", nil} in calls
      assert {:edit, 1, 4, "immediate3", nil} in calls
    end

    test "does not coalesce operations when throttle is 0" do
      {:ok, _} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 0]}
        )

      key = {1, 2, :edit}

      Outbox.enqueue(key, 0, {:edit, 1, 2, %{text: "first"}})
      Outbox.enqueue(key, 0, {:edit, 1, 2, %{text: "second"}})
      Outbox.enqueue(key, 0, {:edit, 1, 2, %{text: "third"}})

      Process.sleep(50)

      # All three edits should be executed (no coalescing)
      calls = MockOutboxAPI.calls()
      assert length(calls) == 3
      assert Enum.at(calls, 0) == {:edit, 1, 2, "first", nil}
      assert Enum.at(calls, 1) == {:edit, 1, 2, "second", nil}
      assert Enum.at(calls, 2) == {:edit, 1, 2, "third", nil}
    end

    test "queue remains empty with zero throttle" do
      {:ok, _} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 0]}
        )

      Outbox.enqueue({1, 2, :edit}, 0, {:edit, 1, 2, %{text: "test"}})
      Process.sleep(50)

      state = :sys.get_state(LemonGateway.Telegram.Outbox)
      assert state.queue == []
      assert state.ops == %{}
    end
  end

  describe "throttle timing accuracy" do
    setup do
      {:ok, _} = start_supervised({TimingMockAPI, [notify_pid: self()]})
      :ok
    end

    test "respects throttle delay between operations" do
      throttle_ms = 100

      {:ok, _} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: TimingMockAPI, edit_throttle_ms: throttle_ms]}
        )

      start_time = System.monotonic_time(:millisecond)

      # Enqueue 3 operations for different keys
      Outbox.enqueue({1, 1, :edit}, 0, {:edit, 1, 1, %{text: "op1"}})
      Outbox.enqueue({1, 2, :edit}, 0, {:edit, 1, 2, %{text: "op2"}})
      Outbox.enqueue({1, 3, :edit}, 0, {:edit, 1, 3, %{text: "op3"}})

      # Wait for all operations to complete with generous timeout
      Process.sleep(throttle_ms * 4 + 50)

      end_time = System.monotonic_time(:millisecond)
      total_time = end_time - start_time

      calls = TimingMockAPI.calls()
      assert length(calls) == 3

      # With 3 operations and throttle_ms between each, total time should be at least 2 * throttle_ms
      # (first op executes immediately, then 2 throttle delays)
      min_expected = 2 * throttle_ms - 30

      assert total_time >= min_expected,
             "Expected total time >= #{min_expected}ms for 3 operations with #{throttle_ms}ms throttle, got #{total_time}ms"
    end

    test "first operation executes immediately" do
      {:ok, _} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: TimingMockAPI, edit_throttle_ms: 200]}
        )

      start_time = System.monotonic_time(:millisecond)
      Outbox.enqueue({1, 1, :edit}, 0, {:edit, 1, 1, %{text: "first"}})

      # Wait for the first message with enough timeout
      assert_receive {:outbox_api_call, {:edit, 1, 1, "first", ts}}, 100

      # First operation should execute quickly (within 50ms)
      assert ts - start_time < 50
    end
  end

  describe "queue ordering" do
    setup do
      {:ok, _} = start_supervised({MockOutboxAPI, [notify_pid: self()]})
      :ok
    end

    test "operations are processed in FIFO order" do
      {:ok, _} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 20]}
        )

      Outbox.enqueue({1, 1, :edit}, 0, {:edit, 1, 1, %{text: "first"}})
      Outbox.enqueue({1, 2, :edit}, 0, {:edit, 1, 2, %{text: "second"}})
      Outbox.enqueue({1, 3, :edit}, 0, {:edit, 1, 3, %{text: "third"}})

      # Wait for all operations to complete
      Process.sleep(150)

      calls = MockOutboxAPI.calls()
      assert length(calls) == 3
      assert Enum.at(calls, 0) == {:edit, 1, 1, "first", nil}
      assert Enum.at(calls, 1) == {:edit, 1, 2, "second", nil}
      assert Enum.at(calls, 2) == {:edit, 1, 3, "third", nil}
    end

    test "mixed send and edit operations maintain order" do
      {:ok, _} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 20]}
        )

      Outbox.enqueue({1, :send}, 0, {:send, 1, %{text: "send1"}})
      Outbox.enqueue({1, 1, :edit}, 0, {:edit, 1, 1, %{text: "edit1"}})
      Outbox.enqueue({2, :send}, 0, {:send, 2, %{text: "send2"}})

      Process.sleep(150)

      calls = MockOutboxAPI.calls()
      assert length(calls) == 3
      assert Enum.at(calls, 0) == {:send, 1, "send1", %{}, nil}
      assert Enum.at(calls, 1) == {:edit, 1, 1, "edit1", nil}
      assert Enum.at(calls, 2) == {:send, 2, "send2", %{}, nil}
    end

    test "priority ordering - lower priority numbers execute first" do
      # Priority ordering: lower numbers = higher priority
      {:ok, _} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 20]}
        )

      # Enqueue in order: low, high, medium priority
      Outbox.enqueue({1, 1, :edit}, 10, {:edit, 1, 1, %{text: "low priority"}})
      Outbox.enqueue({1, 2, :edit}, 1, {:edit, 1, 2, %{text: "high priority"}})
      Outbox.enqueue({1, 3, :edit}, 5, {:edit, 1, 3, %{text: "medium priority"}})

      Process.sleep(150)

      calls = MockOutboxAPI.calls()
      assert length(calls) == 3
      # Should be sorted by priority: high (1), medium (5), low (10)
      assert Enum.at(calls, 0) == {:edit, 1, 2, "high priority", nil}
      assert Enum.at(calls, 1) == {:edit, 1, 3, "medium priority", nil}
      assert Enum.at(calls, 2) == {:edit, 1, 1, "low priority", nil}
    end
  end

  describe "send operation with nil engine" do
    setup do
      {:ok, _} = start_supervised({MockOutboxAPI, [notify_pid: self()]})
      :ok
    end

    test "send without engine uses generic truncation" do
      {:ok, _} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 0]}
        )

      Outbox.enqueue({1, :send}, 0, {:send, 1, %{text: "Hello world", engine: nil}})

      Process.sleep(50)

      calls = MockOutboxAPI.calls()
      assert length(calls) == 1
      assert {:send, 1, "Hello world", %{}, nil} in calls
    end

    test "send with explicit nil engine still works" do
      {:ok, _} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 0]}
        )

      Outbox.enqueue({1, :send}, 0, {:send, 1, %{text: "test message", engine: nil}})

      Process.sleep(50)

      calls = MockOutboxAPI.calls()
      assert [{:send, 1, "test message", %{}, nil}] = calls
    end

    test "send without engine key in payload" do
      {:ok, _} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 0]}
        )

      # No :engine key at all
      Outbox.enqueue({1, :send}, 0, {:send, 1, %{text: "no engine key"}})

      Process.sleep(50)

      calls = MockOutboxAPI.calls()
      assert [{:send, 1, "no engine key", %{}, nil}] = calls
    end

    test "send with reply_to_message_id" do
      {:ok, _} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 0]}
        )

      Outbox.enqueue(
        {1, :send},
        0,
        {:send, 1, %{text: "reply", reply_to_message_id: 123, engine: nil}}
      )

      Process.sleep(50)

      calls = MockOutboxAPI.calls()
      assert [{:send, 1, "reply", %{reply_to_message_id: 123}, nil}] = calls
    end

    test "send with string keys in payload" do
      {:ok, _} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 0]}
        )

      Outbox.enqueue(
        {1, :send},
        0,
        {:send, 1, %{"text" => "string key", "reply_to_message_id" => 456}}
      )

      Process.sleep(50)

      calls = MockOutboxAPI.calls()
      assert [{:send, 1, "string key", %{reply_to_message_id: 456}, nil}] = calls
    end
  end

  describe "edit operation with engine" do
    setup do
      {:ok, _} = start_supervised({MockOutboxAPI, [notify_pid: self()]})
      :ok
    end

    test "edit with nil engine uses generic truncation" do
      {:ok, _} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 0]}
        )

      Outbox.enqueue({1, 2, :edit}, 0, {:edit, 1, 2, %{text: "edit text", engine: nil}})

      Process.sleep(50)

      calls = MockOutboxAPI.calls()
      assert [{:edit, 1, 2, "edit text", nil}] = calls
    end

    test "edit without engine key in payload" do
      {:ok, _} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 0]}
        )

      Outbox.enqueue({1, 2, :edit}, 0, {:edit, 1, 2, %{text: "no engine"}})

      Process.sleep(50)

      calls = MockOutboxAPI.calls()
      assert [{:edit, 1, 2, "no engine", nil}] = calls
    end

    test "edit with non-atom engine falls back to generic truncation" do
      {:ok, _} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 0]}
        )

      # Non-atom engine (e.g., string) should use generic truncation
      Outbox.enqueue({1, 2, :edit}, 0, {:edit, 1, 2, %{text: "test", engine: "not_an_atom"}})

      Process.sleep(50)

      calls = MockOutboxAPI.calls()
      assert [{:edit, 1, 2, "test", nil}] = calls
    end
  end

  describe "state transitions during drain cycle" do
    setup do
      {:ok, _} = start_supervised({MockOutboxAPI, [notify_pid: self()]})
      :ok
    end

    test "next_at is reset when queue becomes empty" do
      {:ok, _} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 30]}
        )

      Outbox.enqueue({1, 1, :edit}, 0, {:edit, 1, 1, %{text: "single op"}})

      # Wait for the operation to complete
      assert_receive {:outbox_api_call, {:edit, 1, 1, "single op", nil}}, 100

      # Wait for the next drain cycle to notice empty queue
      Process.sleep(50)

      state = :sys.get_state(LemonGateway.Telegram.Outbox)
      assert state.queue == []
      assert state.ops == %{}
      assert state.next_at == 0
    end

    test "next_at is set after processing an operation when more are queued" do
      {:ok, _} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 200]}
        )

      Outbox.enqueue({1, 1, :edit}, 0, {:edit, 1, 1, %{text: "op1"}})
      Outbox.enqueue({1, 2, :edit}, 0, {:edit, 1, 2, %{text: "op2"}})

      # Wait for first operation to process
      assert_receive {:outbox_api_call, {:edit, 1, 1, "op1", nil}}, 100

      state = :sys.get_state(LemonGateway.Telegram.Outbox)
      # next_at should be set (not 0) because we have more operations
      # Note: next_at is based on System.monotonic_time which can be negative
      assert state.next_at != 0
      # First key should be removed from queue and ops
      refute Map.has_key?(state.ops, {1, 1, :edit})
    end

    test "operations are correctly throttled" do
      {:ok, _} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 100]}
        )

      Outbox.enqueue({1, 1, :edit}, 0, {:edit, 1, 1, %{text: "op1"}})

      # Wait for first op
      assert_receive {:outbox_api_call, {:edit, 1, 1, "op1", nil}}, 100

      # Enqueue more before throttle expires
      Outbox.enqueue({1, 2, :edit}, 0, {:edit, 1, 2, %{text: "op2"}})

      # The operation should still respect throttle - should NOT receive within 50ms
      refute_receive {:outbox_api_call, {:edit, 1, 2, "op2", nil}}, 50

      # But should eventually arrive
      assert_receive {:outbox_api_call, {:edit, 1, 2, "op2", nil}}, 150
    end

    test "operations added during drain are processed correctly" do
      {:ok, _} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 50]}
        )

      # Start with one operation
      Outbox.enqueue({1, 1, :edit}, 0, {:edit, 1, 1, %{text: "initial"}})

      # Wait for it to process
      assert_receive {:outbox_api_call, {:edit, 1, 1, "initial", nil}}, 100

      # Add more operations
      Outbox.enqueue({1, 2, :edit}, 0, {:edit, 1, 2, %{text: "added1"}})
      Outbox.enqueue({1, 3, :edit}, 0, {:edit, 1, 3, %{text: "added2"}})

      # They should be processed in order
      assert_receive {:outbox_api_call, {:edit, 1, 2, "added1", nil}}, 150
      assert_receive {:outbox_api_call, {:edit, 1, 3, "added2", nil}}, 150
    end
  end

  describe "concurrent operations from multiple threads" do
    setup do
      {:ok, _} = start_supervised({MockOutboxAPI, [notify_pid: self()]})
      :ok
    end

    test "handles concurrent enqueue from multiple processes" do
      {:ok, _} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 5]}
        )

      parent = self()
      num_processes = 5
      ops_per_process = 3

      # Spawn multiple processes that enqueue concurrently
      tasks =
        for i <- 1..num_processes do
          Task.async(fn ->
            for j <- 1..ops_per_process do
              key = {i, j, :edit}
              Outbox.enqueue(key, 0, {:edit, i, j, %{text: "proc#{i}-op#{j}"}})
            end

            send(parent, {:done, i})
          end)
        end

      # Wait for all tasks to complete enqueueing
      for _ <- 1..num_processes do
        assert_receive {:done, _}, 1000
      end

      Task.await_many(tasks)

      # Wait for all operations to be processed
      total_ops = num_processes * ops_per_process
      Process.sleep(total_ops * 10 + 100)

      calls = MockOutboxAPI.calls()
      # All operations should be processed
      assert length(calls) == total_ops
    end

    test "concurrent coalescing operations are handled correctly" do
      {:ok, _} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 200]}
        )

      # Same key from multiple processes - should coalesce
      # Use a longer throttle to ensure all enqueues happen before first drain completes
      shared_key = {1, 1, :edit}
      num_processes = 10

      tasks =
        for i <- 1..num_processes do
          Task.async(fn ->
            Outbox.enqueue(shared_key, 0, {:edit, 1, 1, %{text: "update-#{i}"}})
          end)
        end

      Task.await_many(tasks)

      # Wait for processing
      Process.sleep(300)

      calls = MockOutboxAPI.calls()
      # Due to coalescing, we should have significantly fewer calls than num_processes
      # The exact number depends on timing, but it should be much less than 10
      assert length(calls) <= 3,
             "Expected at most 3 calls due to coalescing, got #{length(calls)}"

      # All calls should be for the same key with one of the update texts
      for {:edit, 1, 1, text, _} <- calls do
        assert String.starts_with?(text, "update-")
      end
    end

    test "concurrent operations with different keys are all processed" do
      {:ok, _} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 3]}
        )

      num_operations = 20

      tasks =
        for i <- 1..num_operations do
          Task.async(fn ->
            key = {i, i, :edit}
            Outbox.enqueue(key, 0, {:edit, i, i, %{text: "msg-#{i}"}})
          end)
        end

      Task.await_many(tasks)

      # Wait for all operations to be processed
      Process.sleep(num_operations * 8 + 100)

      calls = MockOutboxAPI.calls()
      assert length(calls) == num_operations

      # Verify all messages were processed
      texts = Enum.map(calls, fn {:edit, _, _, text, _} -> text end) |> Enum.sort()
      expected = Enum.map(1..num_operations, &"msg-#{&1}") |> Enum.sort()
      assert texts == expected
    end
  end

  describe "start_link behavior" do
    test "returns :ignore when bot_token is missing" do
      previous = Application.get_env(:lemon_gateway, :telegram)
      cfg_pid = Process.whereis(LemonGateway.Config)
      cfg_state = if is_pid(cfg_pid), do: :sys.get_state(LemonGateway.Config), else: nil

      try do
        Application.put_env(:lemon_gateway, :telegram, %{})

        # Ensure the base config (loaded from the user's local TOML) can't leak a bot token
        # into this test. Outbox.start_link/1 consults LemonGateway.Config first.
        if is_pid(cfg_pid) do
          :sys.replace_state(LemonGateway.Config, fn state ->
            Map.delete(state, :telegram)
          end)
        end

        result = Outbox.start_link([])
        assert result == :ignore
      after
        if is_pid(cfg_pid) and is_map(cfg_state) do
          :sys.replace_state(LemonGateway.Config, fn _ -> cfg_state end)
        end

        if is_nil(previous) do
          Application.delete_env(:lemon_gateway, :telegram)
        else
          Application.put_env(:lemon_gateway, :telegram, previous)
        end
      end
    end

    test "returns :ignore when bot_token is empty string" do
      result = Outbox.start_link(bot_token: "")
      assert result == :ignore
    end

    test "returns :ignore when bot_token is nil" do
      result = Outbox.start_link(bot_token: nil)
      assert result == :ignore
    end

    test "starts successfully with valid bot_token" do
      {:ok, _} = start_supervised({MockOutboxAPI, [notify_pid: self()]})

      {:ok, pid} =
        start_supervised({Outbox, [bot_token: "valid_token", api_mod: MockOutboxAPI]})

      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "accepts string keys for bot_token in config" do
      {:ok, _} = start_supervised({MockOutboxAPI, [notify_pid: self()]})

      {:ok, pid} =
        start_supervised({Outbox, [{"bot_token", "string_key_token"}, {:api_mod, MockOutboxAPI}]})

      assert is_pid(pid)
    end
  end

  describe "handle_info for unknown messages" do
    setup do
      {:ok, _} = start_supervised({MockOutboxAPI, [notify_pid: self()]})
      :ok
    end

    test "ignores unknown messages" do
      {:ok, pid} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 50]}
        )

      # Send random messages
      send(pid, :random_message)
      send(pid, {:unexpected, :tuple})
      send(pid, "string message")

      # Process should still be alive and functional
      Process.sleep(20)
      assert Process.alive?(pid)

      # Should still work normally
      Outbox.enqueue({1, 1, :edit}, 0, {:edit, 1, 1, %{text: "still works"}})
      assert_receive {:outbox_api_call, {:edit, 1, 1, "still works", nil}}, 200
    end
  end

  describe "edge cases" do
    setup do
      {:ok, _} = start_supervised({MockOutboxAPI, [notify_pid: self()]})
      :ok
    end

    test "handles empty text" do
      {:ok, _} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 0]}
        )

      Outbox.enqueue({1, :send}, 0, {:send, 1, %{text: ""}})
      Process.sleep(50)

      calls = MockOutboxAPI.calls()
      assert [{:send, 1, "", %{}, nil}] = calls
    end

    test "handles missing text key - uses empty string" do
      {:ok, _} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 0]}
        )

      Outbox.enqueue({1, :send}, 0, {:send, 1, %{}})
      Process.sleep(50)

      calls = MockOutboxAPI.calls()
      assert [{:send, 1, "", %{}, nil}] = calls
    end

    test "handles very long keys" do
      {:ok, _} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 0]}
        )

      long_key = {String.duplicate("a", 1000), 12345, :edit}
      Outbox.enqueue(long_key, 0, {:edit, 1, 2, %{text: "long key test"}})

      Process.sleep(50)

      calls = MockOutboxAPI.calls()
      assert [{:edit, 1, 2, "long key test", nil}] = calls
    end

    test "handles large chat_id and message_id" do
      {:ok, _} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 0]}
        )

      large_chat_id = 9_999_999_999_999
      large_msg_id = 8_888_888_888_888

      Outbox.enqueue(
        {large_chat_id, large_msg_id, :edit},
        0,
        {:edit, large_chat_id, large_msg_id, %{text: "large ids"}}
      )

      Process.sleep(50)

      calls = MockOutboxAPI.calls()
      assert [{:edit, ^large_chat_id, ^large_msg_id, "large ids", nil}] = calls
    end

    test "uses default edit_throttle_ms when not specified" do
      {:ok, _} =
        start_supervised({Outbox, [bot_token: "token", api_mod: MockOutboxAPI]})

      state = :sys.get_state(LemonGateway.Telegram.Outbox)
      # Default is 400ms as per @default_edit_throttle
      assert state.edit_throttle_ms == 400
    end
  end

  describe "delete operation" do
    setup do
      {:ok, _} = start_supervised({MockOutboxAPI, [notify_pid: self()]})
      :ok
    end

    test "executes delete operation" do
      {:ok, _} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 0]}
        )

      Outbox.enqueue({1, 123, :delete}, -1, {:delete, 1, 123})
      Process.sleep(50)

      calls = MockOutboxAPI.calls()
      assert [{:delete, 1, 123}] = calls
    end

    test "delete operations have highest priority by default" do
      {:ok, _} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 20]}
        )

      # Enqueue send (priority 1), edit (priority 0), then delete (priority -1)
      Outbox.enqueue({1, :send}, nil, {:send, 1, %{text: "send msg"}})
      Outbox.enqueue({1, 2, :edit}, nil, {:edit, 1, 2, %{text: "edit msg"}})
      Outbox.enqueue({1, 3, :delete}, nil, {:delete, 1, 3})

      Process.sleep(150)

      calls = MockOutboxAPI.calls()
      assert length(calls) == 3
      # Delete should execute first (priority -1), then edit (0), then send (1)
      assert Enum.at(calls, 0) == {:delete, 1, 3}
      assert Enum.at(calls, 1) == {:edit, 1, 2, "edit msg", nil}
      assert Enum.at(calls, 2) == {:send, 1, "send msg", %{}, nil}
    end

    test "delete drops any pending edit for the same chat/message" do
      {:ok, pid} =
        start_supervised(
          {Outbox,
           [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 50, use_markdown: false]}
        )

      # Make the test deterministic by preventing auto-drain scheduling until we've enqueued
      # both ops. (schedule_drain/1 only triggers when next_at == 0)
      :sys.replace_state(pid, fn state ->
        %{state | next_at: System.monotonic_time(:millisecond) + 60_000}
      end)

      edit_key = {1, 2, :edit}
      delete_key = {1, 2, :delete}

      Outbox.enqueue(edit_key, 0, {:edit, 1, 2, %{text: "should be dropped"}})
      Outbox.enqueue(delete_key, -1, {:delete, 1, 2})

      state = :sys.get_state(pid)
      refute Map.has_key?(state.ops, edit_key)
      assert Enum.all?(state.queue, fn {k, _p} -> k != edit_key end)

      :sys.replace_state(pid, fn state -> %{state | next_at: 0} end)
      send(pid, :drain)

      assert_receive {:outbox_api_call, {:delete, 1, 2}}, 200
      refute_receive {:outbox_api_call, {:edit, 1, 2, _text, _opts}}, 50
    end
  end

  describe "retry logic" do
    setup do
      {:ok, _} = start_supervised({MockOutboxAPI, [notify_pid: self()]})
      :ok
    end

    test "retries on server error (5xx)" do
      {:ok, _} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 0]}
        )

      # First call will fail with 500 error
      MockOutboxAPI.fail_next({:http_error, 500, "Internal Server Error"})

      Outbox.enqueue({1, 2, :edit}, 0, {:edit, 1, 2, %{text: "retry me"}})

      # First attempt happens immediately (fails), then retry after backoff
      Process.sleep(50)
      first_calls = MockOutboxAPI.calls()
      assert length(first_calls) == 1

      # Wait for retry (base backoff is 1000ms)
      Process.sleep(1200)
      calls = MockOutboxAPI.calls()
      # Should have retried and succeeded
      assert length(calls) == 2
      assert Enum.at(calls, 0) == {:edit, 1, 2, "retry me", nil}
      assert Enum.at(calls, 1) == {:edit, 1, 2, "retry me", nil}
    end

    test "respects retry_after from 429 response" do
      {:ok, _} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 0]}
        )

      # First call will fail with 429 error with retry_after
      retry_after_body =
        Jason.encode!(%{"error_code" => 429, "parameters" => %{"retry_after" => 1}})

      MockOutboxAPI.fail_next({:http_error, 429, retry_after_body})

      Outbox.enqueue({1, 2, :edit}, 0, {:edit, 1, 2, %{text: "rate limited"}})

      # First attempt happens immediately (fails)
      Process.sleep(50)
      first_calls = MockOutboxAPI.calls()
      assert length(first_calls) == 1

      # Wait for retry (should wait at least 1 second from retry_after)
      Process.sleep(1200)
      calls = MockOutboxAPI.calls()
      # Should have retried after the retry_after period
      assert length(calls) == 2
    end

    test "retry state is tracked in GenServer state" do
      {:ok, _} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 0]}
        )

      # Fail first attempt
      MockOutboxAPI.fail_next({:http_error, 500, "Server Error"})
      Outbox.enqueue({1, 2, :edit}, 0, {:edit, 1, 2, %{text: "track retry"}})

      # Wait for initial failure
      Process.sleep(50)

      # Check that retry_state has been updated
      state = :sys.get_state(LemonGateway.Telegram.Outbox)
      assert Map.has_key?(state.retry_state, {1, 2, :edit})
      assert state.retry_state[{1, 2, :edit}] == 1
    end

    test "does not retry on client errors (4xx except 429)" do
      {:ok, _} =
        start_supervised(
          {Outbox, [bot_token: "token", api_mod: MockOutboxAPI, edit_throttle_ms: 0]}
        )

      # Fail with 400 error (not retryable)
      MockOutboxAPI.fail_next({:http_error, 400, "Bad Request"})
      Outbox.enqueue({1, 2, :edit}, 0, {:edit, 1, 2, %{text: "no retry"}})

      Process.sleep(50)

      # Should only have one call (no retry for 4xx errors except 429)
      calls = MockOutboxAPI.calls()
      assert length(calls) == 1

      # Wait to ensure no retry happens
      Process.sleep(1200)
      calls_after = MockOutboxAPI.calls()
      assert length(calls_after) == 1
    end
  end
end
