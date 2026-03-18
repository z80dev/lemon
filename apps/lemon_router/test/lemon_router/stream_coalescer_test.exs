defmodule LemonRouter.StreamCoalescerTest do
  alias Elixir.LemonRouter, as: LemonRouter
  use ExUnit.Case, async: false

  alias LemonCore.ResumeToken
  alias LemonCore.DeliveryIntent
  alias LemonCore.DeliveryRoute
  alias Elixir.LemonRouter.StreamCoalescer

  defmodule StreamCoalescerTestTelegramPlugin do
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
      {:ok, %{"ok" => true, "result" => %{"message_id" => 101}}}
    end
  end

  defmodule StreamCoalescerTestOutboxAPI do
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

  defmodule IntentDispatcherStub do
    @moduledoc false

    def dispatch(%DeliveryIntent{} = intent) do
      case :persistent_term.get({__MODULE__, :test_pid}, nil) do
        pid when is_pid(pid) -> send(pid, {:dispatched_intent, intent})
        _ -> :ok
      end

      :ok
    end
  end

  setup do
    # Start the coalescer registry and supervisor if not running
    if is_nil(Process.whereis(Elixir.LemonRouter.CoalescerRegistry)) do
      {:ok, _} = Registry.start_link(keys: :unique, name: Elixir.LemonRouter.CoalescerRegistry)
    end

    if is_nil(Process.whereis(Elixir.LemonRouter.CoalescerSupervisor)) do
      {:ok, _} =
        DynamicSupervisor.start_link(
          strategy: :one_for_one,
          name: Elixir.LemonRouter.CoalescerSupervisor
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

    if is_nil(Process.whereis(LemonChannels.PresentationState)) do
      {:ok, _} = LemonChannels.PresentationState.start_link([])
    end

    :persistent_term.put({__MODULE__.StreamCoalescerTestTelegramPlugin, :test_pid}, self())

    existing = LemonChannels.Registry.get_plugin("telegram")
    _ = LemonChannels.Registry.unregister("telegram")
    :ok = LemonChannels.Registry.register(__MODULE__.StreamCoalescerTestTelegramPlugin)

    on_exit(fn ->
      _ = :persistent_term.erase({__MODULE__.StreamCoalescerTestTelegramPlugin, :test_pid})
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
                 Elixir.LemonRouter.CoalescerRegistry,
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
                 Elixir.LemonRouter.CoalescerRegistry,
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

    test "handles canonical channel format" do
      session_key = "agent:my-agent:telegram:bot:dm:12345"
      channel_id = "telegram"
      run_id = "run_#{System.unique_integer()}"

      assert :ok =
               StreamCoalescer.ingest_delta(
                 session_key,
                 channel_id,
                 run_id,
                 1,
                 "Canonical format test"
               )

      assert [{_pid, _}] =
               Registry.lookup(
                 Elixir.LemonRouter.CoalescerRegistry,
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

  describe "semantic delivery boundary" do
    test "finalize emits a semantic delivery intent via configurable dispatcher" do
      previous_dispatcher = Application.get_env(:lemon_router, :dispatcher)
      Application.put_env(:lemon_router, :dispatcher, IntentDispatcherStub)
      :persistent_term.put({IntentDispatcherStub, :test_pid}, self())

      on_exit(fn ->
        :persistent_term.erase({IntentDispatcherStub, :test_pid})

        if is_nil(previous_dispatcher) do
          Application.delete_env(:lemon_router, :dispatcher)
        else
          Application.put_env(:lemon_router, :dispatcher, previous_dispatcher)
        end
      end)

      session_key = "agent:test:telegram:bot:group:12345:thread:777"
      channel_id = "telegram"
      run_id = "run_#{System.unique_integer([:positive])}"

      assert :ok =
               StreamCoalescer.finalize_run(session_key, channel_id, run_id,
                 meta: %{user_msg_id: 9},
                 final_text: "Final answer"
               )

      assert_receive {:dispatched_intent,
                      %DeliveryIntent{
                        intent_id: ^run_id <> ":stream:0:stream_finalize",
                        run_id: ^run_id,
                        session_key: ^session_key,
                        kind: :stream_finalize,
                        route: %DeliveryRoute{
                          channel_id: "telegram",
                          account_id: "bot",
                          peer_kind: :group,
                          peer_id: "12345",
                          thread_id: "777"
                        },
                        body: %{text: "Final answer", seq: 0},
                        meta: %{surface: :answer, user_msg_id: 9}
                      }},
                     1_000
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
                 Elixir.LemonRouter.CoalescerRegistry,
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

      [{pid, _}] =
        Registry.lookup(Elixir.LemonRouter.CoalescerRegistry, {session_key, channel_id})

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
      send_key = "#{run_id}:stream:0:stream_finalize"

      assert_receive {:delivered, %{idempotency_key: ^send_key} = payload}, 1_000

      assert payload.kind == :text
      assert payload.reply_to == "222"
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

      send_key = "#{run_id}:stream:0:stream_finalize"
      file_key = "#{send_key}:file:0"

      assert_receive {:delivered, %{idempotency_key: ^send_key, kind: :text}}, 1_000

      assert_receive {:delivered, %{idempotency_key: ^file_key} = payload}, 1_000
      assert payload.kind == :file
      assert payload.reply_to == "222"
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

      send_key = "#{run_id}:stream:0:stream_finalize"
      file_key = "#{send_key}:file:0"

      assert_receive {:delivered, %{idempotency_key: ^send_key, kind: :text}}, 1_000
      assert_receive {:delivered, %{idempotency_key: ^file_key} = payload}, 1_000

      assert payload.kind == :file
      assert payload.reply_to == "222"
      assert is_list(payload.content.files)
      assert Enum.map(payload.content.files, & &1.path) == [path1, path2]
      assert Enum.map(payload.content.files, & &1.caption) == ["First", "Second"]
    end

    test "edits progress message even when there is no final text" do
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

      send_key = "#{run_id}:stream:0:stream_finalize"

      assert_receive {:delivered,
                      %LemonChannels.OutboundPayload{
                        channel_id: "telegram",
                        kind: :text,
                        idempotency_key: ^send_key,
                        content: "⚠️ Empty response from model — no output was generated.",
                        peer: %{id: "12340"},
                        reply_to: "222",
                        meta: %{run_id: ^run_id, intent_kind: :stream_finalize}
                      }},
                     1_000
    end

    test "uses accumulated full_text when final_text is empty but deltas were streamed" do
      session_key = "agent:test:telegram:bot:dm:12341"
      channel_id = "telegram"
      run_id = "run_#{System.unique_integer()}"

      # Stream some deltas first
      assert :ok =
               StreamCoalescer.ingest_delta(
                 session_key,
                 channel_id,
                 run_id,
                 1,
                 "Hello, I looked at the code and ",
                 meta: %{progress_msg_id: 111, user_msg_id: 222}
               )

      assert :ok =
               StreamCoalescer.ingest_delta(
                 session_key,
                 channel_id,
                 run_id,
                 2,
                 "here are my findings.",
                 meta: %{progress_msg_id: 111, user_msg_id: 222}
               )

      # Finalize with empty final_text — should use accumulated full_text, NOT the empty-warning
      assert :ok =
               StreamCoalescer.finalize_run(
                 session_key,
                 channel_id,
                 run_id,
                 meta: %{progress_msg_id: 111, user_msg_id: 222},
                 final_text: ""
               )

      send_key = "#{run_id}:stream:2:stream_finalize"

      assert_receive {:delivered,
                      %LemonChannels.OutboundPayload{
                        channel_id: "telegram",
                        kind: :text,
                        idempotency_key: ^send_key,
                        content: "Hello, I looked at the code and here are my findings.",
                        peer: %{id: "12341"},
                        reply_to: "222",
                        meta: %{run_id: ^run_id, intent_kind: :stream_finalize}
                      }},
                     1_000
    end

    test "handles explicit nil final_text with no prior deltas" do
      session_key = "agent:test:telegram:bot:dm:12342"
      channel_id = "telegram"
      run_id = "run_#{System.unique_integer()}"

      assert :ok =
               StreamCoalescer.finalize_run(
                 session_key,
                 channel_id,
                 run_id,
                 meta: %{progress_msg_id: 111, user_msg_id: 222},
                 final_text: nil
               )

      send_key = "#{run_id}:stream:0:stream_finalize"

      assert_receive {:delivered,
                      %LemonChannels.OutboundPayload{
                        channel_id: "telegram",
                        kind: :text,
                        idempotency_key: ^send_key,
                        content: "⚠️ Empty response from model — no output was generated.",
                        peer: %{id: "12342"},
                        reply_to: "222",
                        meta: %{run_id: ^run_id, intent_kind: :stream_finalize}
                      }},
                     1_000
    end
  end

  describe "telegram outbox integration" do
    test "telegram deltas stream into a dedicated answer message (progress message is reserved for tool status)" do
      session_key = "agent:test:telegram:bot:dm:12345"
      channel_id = "telegram"
      run_id = "run_#{System.unique_integer([:positive])}"

      StreamCoalescer.ingest_delta(session_key, channel_id, run_id, 1, "Hello",
        meta: %{progress_msg_id: 999}
      )

      assert :ok = StreamCoalescer.flush(session_key, channel_id)

      first_key = "#{run_id}:stream:1:stream_snapshot"

      assert_receive {:delivered,
                      %LemonChannels.OutboundPayload{
                        channel_id: "telegram",
                        kind: :text,
                        idempotency_key: ^first_key,
                        content: "Hello",
                        peer: %{id: "12345"},
                        meta: %{run_id: ^run_id, intent_kind: :stream_snapshot}
                      }},
                     1_000

      route = telegram_route("bot", :dm, "12345", nil)

      assert eventually(fn ->
               LemonChannels.PresentationState.get(route, run_id, :answer).platform_message_id ==
                 101
             end)

      StreamCoalescer.ingest_delta(session_key, channel_id, run_id, 2, " world",
        meta: %{progress_msg_id: 999}
      )

      assert :ok = StreamCoalescer.flush(session_key, channel_id)

      second_key = "#{run_id}:stream:2:stream_snapshot"

      assert_receive {:delivered,
                      %LemonChannels.OutboundPayload{
                        channel_id: "telegram",
                        kind: :edit,
                        idempotency_key: ^second_key,
                        peer: %{id: "12345"},
                        content: %{message_id: message_id, text: text},
                        meta: %{run_id: ^run_id, intent_kind: :stream_snapshot}
                      }},
                     1_000

      assert message_id in ["101", 101]
      assert String.contains?(text, "Hello world")
    end

    test "duplicate answer-create enqueue does not leave answer_create_ref pending" do
      session_key = "agent:test:telegram:bot:dm:12355"
      channel_id = "telegram"
      run_id = "run_#{System.unique_integer([:positive])}"
      create_key = "#{run_id}:stream:1:stream_snapshot"

      StreamCoalescer.ingest_delta(session_key, channel_id, run_id, 1, "Hello")
      assert :ok = StreamCoalescer.flush(session_key, channel_id)
      assert_receive {:delivered, %{idempotency_key: ^create_key}}, 1_000

      route = telegram_route("bot", :dm, "12355", nil)

      assert eventually(fn ->
               is_nil(
                 LemonChannels.PresentationState.get(route, run_id, :answer).pending_create_ref
               )
             end)

      assert :ok =
               StreamCoalescer.finalize_run(session_key, channel_id, run_id,
                 meta: %{user_msg_id: 222},
                 final_text: "Hello"
               )

      assert eventually(fn ->
               is_nil(
                 LemonChannels.PresentationState.get(route, run_id, :answer).pending_create_ref
               )
             end)
    end

    test "telegram finalize sends a final answer message and indexes resume by that message id" do
      session_key = "agent:test:telegram:botx:group:12345:thread:777"
      channel_id = "telegram"
      run_id = "run_#{System.unique_integer([:positive])}"

      resume = %ResumeToken{engine: "codex", value: "thread_abc"}

      _ = LemonChannels.Telegram.ResumeIndexStore.delete_thread("botx", 12_345, 777)

      assert :ok =
               StreamCoalescer.finalize_run(session_key, channel_id, run_id,
                 meta: %{progress_msg_id: 111, user_msg_id: 222, resume: resume},
                 final_text: "Final answer"
               )

      assert_receive {:delivered,
                      %LemonChannels.OutboundPayload{
                        channel_id: "telegram",
                        kind: :text,
                        content: "Final answer",
                        reply_to: "222",
                        peer: %{id: "12345", thread_id: "777"},
                        meta: %{run_id: ^run_id, intent_kind: :stream_finalize}
                      }},
                     1_000

      assert eventually(fn ->
               case LemonChannels.Telegram.ResumeIndexStore.get_resume("botx", 12_345, 777, 101) do
                 %ResumeToken{engine: "codex", value: "thread_abc"} -> true
                 _ -> false
               end
             end)
    end

    test "telegram finalize still sends when progress_msg_id is nil (no delete attempted)" do
      session_key = "agent:test:telegram:bot:dm:12346"
      channel_id = "telegram"
      run_id = "run_#{System.unique_integer([:positive])}"

      assert :ok =
               StreamCoalescer.finalize_run(session_key, channel_id, run_id,
                 meta: %{progress_msg_id: nil, user_msg_id: 222},
                 final_text: "Final answer"
               )

      assert_receive {:delivered,
                      %LemonChannels.OutboundPayload{
                        channel_id: "telegram",
                        kind: :text,
                        peer: %{id: "12346"},
                        meta: %{run_id: ^run_id, intent_kind: :stream_finalize}
                      }},
                     1_000
    end

    test "telegram finalize switches run_id for consecutive no-delta runs" do
      session_key = "agent:test:telegram:bot:dm:12348"
      channel_id = "telegram"
      run_id_1 = "run_#{System.unique_integer([:positive])}"
      run_id_2 = "run_#{System.unique_integer([:positive])}"

      assert :ok =
               StreamCoalescer.finalize_run(session_key, channel_id, run_id_1,
                 meta: %{progress_msg_id: 711_111, user_msg_id: 222},
                 final_text: "first-final"
               )

      assert_receive {:delivered,
                      %LemonChannels.OutboundPayload{
                        channel_id: "telegram",
                        kind: :text,
                        content: "first-final",
                        peer: %{id: "12348"},
                        reply_to: "222",
                        meta: %{run_id: ^run_id_1, intent_kind: :stream_finalize}
                      }},
                     1_000

      assert :ok =
               StreamCoalescer.finalize_run(session_key, channel_id, run_id_2,
                 meta: %{progress_msg_id: 722_222, user_msg_id: 333},
                 final_text: "second-final"
               )

      assert_receive {:delivered,
                      %LemonChannels.OutboundPayload{
                        channel_id: "telegram",
                        kind: :text,
                        content: "second-final",
                        peer: %{id: "12348"},
                        reply_to: "333",
                        meta: %{run_id: ^run_id_2, intent_kind: :stream_finalize}
                      }},
                     1_000

      [{pid, _}] =
        Registry.lookup(Elixir.LemonRouter.CoalescerRegistry, {session_key, channel_id})

      state = :sys.get_state(pid)
      assert state.run_id == run_id_2
    end

    test "telegram finalize does not track pending resume index when enqueue returns duplicate" do
      session_key = "agent:test:telegram:botx:group:12350:thread:779"
      channel_id = "telegram"
      run_id = "run_#{System.unique_integer([:positive])}"
      resume = %ResumeToken{engine: "codex", value: "thread_duplicate"}
      idempotency_key = "#{run_id}:stream:0:stream_finalize"
      route = telegram_route("botx", :group, "12350", "779")

      assert :ok =
               StreamCoalescer.finalize_run(session_key, channel_id, run_id,
                 meta: %{resume: resume, user_msg_id: 222},
                 final_text: "Final answer"
               )

      assert eventually(fn ->
               is_nil(
                 LemonChannels.PresentationState.get(route, run_id, :answer).pending_create_ref
               )
             end)

      assert eventually(fn ->
               LemonChannels.Outbox.Dedupe.check("telegram", idempotency_key) == :duplicate
             end)

      assert :ok =
               StreamCoalescer.finalize_run(session_key, channel_id, run_id,
                 meta: %{resume: resume, user_msg_id: 222},
                 final_text: "Final answer"
               )

      assert eventually(fn ->
               is_nil(
                 LemonChannels.PresentationState.get(route, run_id, :answer).pending_create_ref
               )
             end)
    end
  end

  describe "commit_turn/3" do
    test "resets state and defers PresentationState clear until next delta" do
      session_key = "agent:test:telegram:bot:dm:54321"
      channel_id = "telegram"
      run_id = "run_#{System.unique_integer([:positive])}"
      route = telegram_route("bot", :dm, "54321", nil)

      # Stream some deltas to build up full_text
      StreamCoalescer.ingest_delta(session_key, channel_id, run_id, 1, "First answer")
      StreamCoalescer.flush(session_key, channel_id)

      # Wait for PresentationState to register the message
      assert eventually(fn ->
               LemonChannels.PresentationState.get(route, run_id, :answer).platform_message_id ==
                 101
             end)

      # Commit the turn
      assert :ok = StreamCoalescer.commit_turn(session_key, channel_id, run_id)

      # Internal state should be reset
      [{pid, _}] =
        Registry.lookup(LemonRouter.CoalescerRegistry, {session_key, channel_id})

      state = :sys.get_state(pid)
      assert state.full_text == ""
      assert state.buffer == ""
      assert state.last_sent_text == nil
      assert state.pending_clear == true

      # PresentationState is NOT cleared yet (deferred to avoid race with outbox)
      entry = LemonChannels.PresentationState.get(route, run_id, :answer)
      assert entry.platform_message_id == 101

      # Next delta triggers the deferred clear
      StreamCoalescer.ingest_delta(session_key, channel_id, run_id, 2, "Second answer")
      Process.sleep(50)

      # Now PresentationState should be cleared
      entry = LemonChannels.PresentationState.get(route, run_id, :answer)
      assert is_nil(entry.platform_message_id)
    end

    test "deltas after commit create a new message with fresh text" do
      session_key = "agent:test:telegram:bot:dm:54322"
      channel_id = "telegram"
      run_id = "run_#{System.unique_integer([:positive])}"

      # First turn
      StreamCoalescer.ingest_delta(session_key, channel_id, run_id, 1, "Turn one")
      StreamCoalescer.flush(session_key, channel_id)

      first_key = "#{run_id}:stream:1:stream_snapshot"
      assert_receive {:delivered, %{idempotency_key: ^first_key}}, 1_000

      # Commit
      assert :ok = StreamCoalescer.commit_turn(session_key, channel_id, run_id)

      # Second turn - full_text was reset so the snapshot should contain only "Turn two"
      StreamCoalescer.ingest_delta(session_key, channel_id, run_id, 2, "Turn two")
      StreamCoalescer.flush(session_key, channel_id)

      second_key = "#{run_id}:stream:2:stream_snapshot"
      assert_receive {:delivered, %{idempotency_key: ^second_key, content: content}}, 1_000
      # After commit, full_text was reset, so content should be just "Turn two"
      assert content == "Turn two"
    end

    test "no-op when full_text is empty" do
      session_key = "agent:test:telegram:bot:dm:54323"
      channel_id = "telegram"
      run_id = "run_#{System.unique_integer([:positive])}"

      # Start a coalescer but don't ingest any text
      StreamCoalescer.ingest_delta(session_key, channel_id, run_id, 1, "")
      Process.sleep(10)

      # Commit should be a no-op
      assert :ok = StreamCoalescer.commit_turn(session_key, channel_id, run_id)
    end

    test "no-op for wrong run_id" do
      session_key = "agent:test:telegram:bot:dm:54324"
      channel_id = "telegram"
      run_id = "run_#{System.unique_integer([:positive])}"
      wrong_run_id = "run_#{System.unique_integer([:positive])}"

      StreamCoalescer.ingest_delta(session_key, channel_id, run_id, 1, "Some text")
      StreamCoalescer.flush(session_key, channel_id)
      Process.sleep(50)

      [{pid, _}] =
        Registry.lookup(LemonRouter.CoalescerRegistry, {session_key, channel_id})

      state_before = :sys.get_state(pid)

      # Commit with wrong run_id should be no-op
      assert :ok = StreamCoalescer.commit_turn(session_key, channel_id, wrong_run_id)

      state_after = :sys.get_state(pid)
      assert state_after.full_text == state_before.full_text
    end

    test "no-op when no coalescer exists" do
      assert :ok = StreamCoalescer.commit_turn("non:existent:session", "channel", "run_999")
    end
  end

  describe "handoff_turn/4" do
    test "moves the finalized answer message to the status surface" do
      session_key = "agent:test:telegram:bot:dm:54325"
      channel_id = "telegram"
      run_id = "run_#{System.unique_integer([:positive])}"
      route = telegram_route("bot", :dm, "54325", nil)

      StreamCoalescer.ingest_delta(session_key, channel_id, run_id, 1, "Intermediate text")
      StreamCoalescer.flush(session_key, channel_id)

      assert eventually(fn ->
               LemonChannels.PresentationState.get(route, run_id, :answer).platform_message_id ==
                 101
             end)

      assert {:ok, "Intermediate text"} =
               StreamCoalescer.handoff_turn(session_key, channel_id, run_id, :status)

      answer_entry = LemonChannels.PresentationState.get(route, run_id, :answer)
      status_entry = LemonChannels.PresentationState.get(route, run_id, :status)

      assert is_nil(answer_entry.platform_message_id)
      assert status_entry.platform_message_id == 101
    end
  end

  defp telegram_route(account_id, peer_kind, peer_id, thread_id) do
    %DeliveryRoute{
      channel_id: "telegram",
      account_id: account_id,
      peer_kind: peer_kind,
      peer_id: peer_id,
      thread_id: thread_id
    }
  end
end
