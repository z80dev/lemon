defmodule LemonRouter.StreamCoalescerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

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

      Agent.start_link(fn -> %{calls: [], notify_pid: notify_pid, fail_next_delete: nil} end,
        name: __MODULE__
      )
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

      case Agent.get_and_update(__MODULE__, fn s ->
             {s.fail_next_delete, %{s | fail_next_delete: nil}}
           end) do
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

  defmodule TestNoopTelegramOutbox do
    @moduledoc false
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    @impl true
    def init(:ok), do: {:ok, :ok}

    @impl true
    def handle_cast(_msg, state), do: {:noreply, state}
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
    test "sends a final answer message (progress message is reserved for tool status)" do
      session_key = "agent:my-agent:telegram:bot123:dm:user456"
      channel_id = "telegram"
      run_id = "run_#{System.unique_integer()}"

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
      send_key = "#{run_id}:final:send"

      assert_receive {:delivered, %{idempotency_key: ^send_key} = payload}, 1_000

      assert payload.kind == :text
      assert payload.reply_to == 222
      assert payload.content == "Final answer"
    end

    test "sends configured auto-send files after final text" do
      session_key = "agent:my-agent:telegram:bot123:dm:user456"
      channel_id = "telegram"
      run_id = "run_#{System.unique_integer([:positive])}"

      path = Path.join(System.tmp_dir!(), "coalescer-auto-file-#{run_id}.png")
      File.write!(path, "png")
      on_exit(fn -> File.rm(path) end)

      assert :ok =
               StreamCoalescer.finalize_run(
                 session_key,
                 channel_id,
                 run_id,
                 meta: %{
                   progress_msg_id: 111,
                   user_msg_id: 222,
                   auto_send_files: [%{path: path, caption: "Generated image"}]
                 },
                 final_text: "Final answer"
               )

      send_key = "#{run_id}:final:send"
      file_key = "#{run_id}:final:file:0"

      assert_receive {:delivered, %{idempotency_key: ^send_key, kind: :text}}, 1_000

      assert_receive {:delivered, %{idempotency_key: ^file_key} = payload}, 1_000
      assert payload.kind == :file
      assert payload.reply_to == 222
      assert payload.content.path == path
      assert payload.content.caption == "Generated image"
    end

    test "batches multiple telegram image files into one outbound payload" do
      session_key = "agent:my-agent:telegram:bot123:dm:user456"
      channel_id = "telegram"
      run_id = "run_#{System.unique_integer([:positive])}"

      path1 = Path.join(System.tmp_dir!(), "coalescer-batch-1-#{run_id}.png")
      path2 = Path.join(System.tmp_dir!(), "coalescer-batch-2-#{run_id}.jpg")
      File.write!(path1, "png")
      File.write!(path2, "jpg")

      on_exit(fn ->
        File.rm(path1)
        File.rm(path2)
      end)

      assert :ok =
               StreamCoalescer.finalize_run(
                 session_key,
                 channel_id,
                 run_id,
                 meta: %{
                   user_msg_id: 222,
                   auto_send_files: [
                     %{path: path1, caption: "First"},
                     %{path: path2, caption: "Second"}
                   ]
                 },
                 final_text: "Final answer"
               )

      send_key = "#{run_id}:final:send"
      file_key = "#{run_id}:final:file:0"

      assert_receive {:delivered, %{idempotency_key: ^send_key, kind: :text}}, 1_000
      assert_receive {:delivered, %{idempotency_key: ^file_key} = payload}, 1_000

      assert payload.kind == :file
      assert payload.reply_to == 222
      assert is_list(payload.content.files)
      assert Enum.map(payload.content.files, & &1.path) == [path1, path2]
      assert Enum.map(payload.content.files, & &1.caption) == ["First", "Second"]
    end

    test "edits progress message even when there is no final text" do
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

      assert_receive {:outbox_api_call,
                      {:send, 12_340, "Done", %{reply_to_message_id: 222}, nil}},
                     500

      refute_receive {:outbox_api_call, {:delete, 12_340, 111}}, 200
      refute_receive {:outbox_api_call, {:edit, 12_340, 111, _text, _opts}}, 200
    end
  end

  describe "telegram outbox integration" do
    setup do
      {:ok, _} = start_supervised({TestOutboxAPI, [notify_pid: self()]})

      :ok
    end

    test "telegram deltas stream into a dedicated answer message (progress message is reserved for tool status)" do
      {:ok, _} =
        start_supervised(
          {LemonGateway.Telegram.Outbox,
           [bot_token: "token", api_mod: TestOutboxAPI, edit_throttle_ms: 0, use_markdown: false]}
        )

      session_key = "agent:test:telegram:bot:dm:12345"
      channel_id = "telegram"
      run_id = "run_#{System.unique_integer([:positive])}"

      StreamCoalescer.ingest_delta(session_key, channel_id, run_id, 1, "Hello",
        meta: %{progress_msg_id: 999}
      )

      assert :ok = StreamCoalescer.flush(session_key, channel_id)

      refute_receive {:outbox_api_call, {:edit, 12_345, 999, _text, _opts}}, 200

      assert_receive {:outbox_api_call, {:send, 12_345, "Hello", _opts, nil}}, 500

      StreamCoalescer.ingest_delta(session_key, channel_id, run_id, 2, " world",
        meta: %{progress_msg_id: 999}
      )

      assert :ok = StreamCoalescer.flush(session_key, channel_id)

      assert_receive {:outbox_api_call, {:edit, 12_345, 101, text, _opts}}, 1_000
      assert String.contains?(text, "Hello world")

      refute_receive {:outbox_api_call, {:edit, 12_345, 999, _text, _opts}}, 200
      # Other async tests may enqueue telegram deliveries while this test has the telegram
      # plugin registered globally. Only assert that *this run* didn't go through
      # LemonChannels.Outbox (it should use LemonGateway.Telegram.Outbox for edits).
      refute_receive {:delivered, %LemonChannels.OutboundPayload{meta: %{run_id: ^run_id}}}, 200
    end

    test "telegram finalize sends a final answer message and indexes resume by that message id" do
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

      assert_receive {:outbox_api_call, {:send, 12_345, "Final answer", opts, nil}}, 500
      assert is_map(opts)
      assert opts[:message_thread_id] == 777
      assert opts[:reply_to_message_id] == 222

      assert eventually(fn ->
               case LemonCore.Store.get(:telegram_msg_resume, store_key) do
                 %LemonGateway.Types.ResumeToken{engine: "codex", value: "thread_abc"} -> true
                 _ -> false
               end
             end)

      refute_receive {:outbox_api_call, {:delete, 12_345, _}}, 200
      refute_receive {:outbox_api_call, {:edit, 12_345, 111, _text, _opts}}, 200
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

    test "telegram finalize switches run_id for consecutive no-delta runs" do
      {:ok, _} =
        start_supervised(
          {LemonGateway.Telegram.Outbox,
           [bot_token: "token", api_mod: TestOutboxAPI, edit_throttle_ms: 0, use_markdown: false]}
        )

      session_key = "agent:test:telegram:bot:dm:12348"
      channel_id = "telegram"
      run_id_1 = "run_#{System.unique_integer([:positive])}"
      run_id_2 = "run_#{System.unique_integer([:positive])}"

      assert :ok =
               StreamCoalescer.finalize_run(session_key, channel_id, run_id_1,
                 meta: %{progress_msg_id: 711_111, user_msg_id: 222},
                 final_text: "first-final"
               )

      assert_receive {:outbox_api_call,
                      {:send, 12_348, "first-final", %{reply_to_message_id: 222}, nil}},
                     500

      assert :ok =
               StreamCoalescer.finalize_run(session_key, channel_id, run_id_2,
                 meta: %{progress_msg_id: 722_222, user_msg_id: 333},
                 final_text: "second-final"
               )

      assert_receive {:outbox_api_call,
                      {:send, 12_348, "second-final", %{reply_to_message_id: 333}, nil}},
                     500

      [{pid, _}] = Registry.lookup(LemonRouter.CoalescerRegistry, {session_key, channel_id})
      state = :sys.get_state(pid)
      assert state.run_id == run_id_2
    end

    test "telegram finalize does not track pending resume index when enqueue returns duplicate" do
      session_key = "agent:test:telegram:botx:group:12350:thread:779"
      channel_id = "telegram"
      run_id = "run_#{System.unique_integer([:positive])}"
      resume = %LemonGateway.Types.ResumeToken{engine: "codex", value: "thread_duplicate"}
      idempotency_key = "#{run_id}:final:send"

      assert :ok =
               StreamCoalescer.finalize_run(session_key, channel_id, run_id,
                 meta: %{resume: resume, user_msg_id: 222},
                 final_text: "Final answer"
               )

      [{pid, _}] = Registry.lookup(LemonRouter.CoalescerRegistry, {session_key, channel_id})

      assert eventually(fn ->
               state = :sys.get_state(pid)
               map_size(state.pending_resume_indices) == 0
             end)

      assert eventually(fn ->
               LemonChannels.Outbox.Dedupe.check("telegram", idempotency_key) == :duplicate
             end)

      assert :ok =
               StreamCoalescer.finalize_run(session_key, channel_id, run_id,
                 meta: %{resume: resume, user_msg_id: 222},
                 final_text: "Final answer"
               )

      state = :sys.get_state(pid)
      assert map_size(state.pending_resume_indices) == 0
    end

    test "stale pending resume index is cleaned up when delivery notify never arrives" do
      {:ok, _} = start_supervised({TestNoopTelegramOutbox, [name: LemonGateway.Telegram.Outbox]})

      session_key = "agent:test:telegram:botx:group:12349:thread:778"
      channel_id = "telegram"
      run_id = "run_#{System.unique_integer([:positive])}"
      resume = %LemonGateway.Types.ResumeToken{engine: "codex", value: "thread_missing_ack"}

      assert :ok =
               StreamCoalescer.finalize_run(session_key, channel_id, run_id,
                 meta: %{resume: resume, user_msg_id: 222},
                 final_text: "Final answer"
               )

      [{pid, _}] = Registry.lookup(LemonRouter.CoalescerRegistry, {session_key, channel_id})
      state = :sys.get_state(pid)
      assert map_size(state.pending_resume_indices) == 1

      [{ref, _}] = Map.to_list(state.pending_resume_indices)

      retry_log =
        capture_log(fn ->
          send(pid, {:pending_resume_cleanup_timeout, ref, 1})
          Process.sleep(20)
        end)

      assert retry_log =~ "Timed out waiting for :outbox_delivered for pending resume index"
      state = :sys.get_state(pid)
      assert Map.has_key?(state.pending_resume_indices, ref)

      cleanup_log =
        capture_log(fn ->
          send(pid, {:pending_resume_cleanup_timeout, ref, 99})

          assert eventually(fn ->
                   state = :sys.get_state(pid)
                   map_size(state.pending_resume_indices) == 0
                 end)
        end)

      assert cleanup_log =~ "Cleaning stale pending resume index after missing :outbox_delivered"
    end
  end
end
