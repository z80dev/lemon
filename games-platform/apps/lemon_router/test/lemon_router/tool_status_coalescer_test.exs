defmodule LemonRouter.ToolStatusCoalescerTest do
  alias Elixir.LemonRouter, as: LemonRouter
  use ExUnit.Case, async: false

  alias Elixir.LemonRouter.ToolStatusCoalescer

  defmodule ToolStatusCoalescerTestTelegramPlugin do
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
      {:ok, %{"ok" => true, "result" => %{"message_id" => 1001}}}
    end
  end

  setup do
    if is_nil(Process.whereis(Elixir.LemonRouter.ToolStatusRegistry)) do
      {:ok, _} = Registry.start_link(keys: :unique, name: Elixir.LemonRouter.ToolStatusRegistry)
    end

    if is_nil(Process.whereis(Elixir.LemonRouter.ToolStatusSupervisor)) do
      {:ok, _} =
        DynamicSupervisor.start_link(
          strategy: :one_for_one,
          name: Elixir.LemonRouter.ToolStatusSupervisor
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

    :persistent_term.put({__MODULE__.ToolStatusCoalescerTestTelegramPlugin, :test_pid}, self())

    existing = LemonChannels.Registry.get_plugin("telegram")
    _ = LemonChannels.Registry.unregister("telegram")

    :ok =
      LemonChannels.Registry.register(__MODULE__.ToolStatusCoalescerTestTelegramPlugin)

    on_exit(fn ->
      _ =
        :persistent_term.erase({__MODULE__.ToolStatusCoalescerTestTelegramPlugin, :test_pid})

      if is_pid(Process.whereis(LemonChannels.Registry)) do
        _ = LemonChannels.Registry.unregister("telegram")

        if is_atom(existing) and not is_nil(existing) do
          _ = LemonChannels.Registry.register(existing)
        end
      end
    end)

    :ok
  end

  test "starts coalescer and accepts action events" do
    session_key = "agent:test:telegram:bot:dm:123"
    channel_id = "telegram"
    run_id = "run_#{System.unique_integer([:positive])}"

    ev = %{
      engine: "lemon",
      action: %{
        id: "a1",
        kind: "tool",
        title: "Read: foo.txt",
        detail: %{}
      },
      phase: :started,
      ok: nil,
      message: nil,
      level: nil
    }

    assert :ok =
             ToolStatusCoalescer.ingest_action(session_key, channel_id, run_id, ev,
               meta: %{status_msg_id: 123}
             )

    assert [{_pid, _}] =
             Registry.lookup(Elixir.LemonRouter.ToolStatusRegistry, {session_key, channel_id})
  end

  test "filters note actions" do
    session_key = "agent:test2:telegram:bot:dm:456"
    channel_id = "telegram"
    run_id = "run_#{System.unique_integer([:positive])}"

    ev = %{
      engine: "lemon",
      action: %{id: "n1", kind: "note", title: "thinking", detail: %{}},
      phase: :completed,
      ok: true,
      message: nil,
      level: nil
    }

    assert :ok = ToolStatusCoalescer.ingest_action(session_key, channel_id, run_id, ev)
    assert :ok = ToolStatusCoalescer.flush(session_key, channel_id)
  end

  test "does not overwrite status_msg_id with nil meta updates" do
    session_key = "agent:test3:telegram:bot:dm:789"
    channel_id = "telegram"
    run_id = "run_#{System.unique_integer([:positive])}"

    ev = %{
      engine: "lemon",
      action: %{id: "a1", kind: "tool", title: "Test tool", detail: %{}},
      phase: :started,
      ok: nil,
      message: nil,
      level: nil
    }

    assert :ok =
             ToolStatusCoalescer.ingest_action(session_key, channel_id, run_id, ev,
               meta: %{status_msg_id: 111}
             )

    [{pid, _}] = Registry.lookup(Elixir.LemonRouter.ToolStatusRegistry, {session_key, channel_id})
    state = :sys.get_state(pid)
    assert state.meta[:status_msg_id] == 111

    assert :ok =
             ToolStatusCoalescer.ingest_action(session_key, channel_id, run_id, ev,
               meta: %{status_msg_id: nil}
             )

    state2 = :sys.get_state(pid)
    assert state2.meta[:status_msg_id] == 111
  end

  test "finalize_run marks running actions as completed" do
    session_key = "agent:finalize:telegram:bot:dm:321"
    channel_id = "telegram"
    run_id = "run_#{System.unique_integer([:positive])}"

    started = %{
      engine: "lemon",
      action: %{id: "a1", kind: "tool", title: "Test tool", detail: %{}},
      phase: :started,
      ok: nil,
      message: nil,
      level: nil
    }

    assert :ok = ToolStatusCoalescer.ingest_action(session_key, channel_id, run_id, started)

    [{pid, _}] = Registry.lookup(Elixir.LemonRouter.ToolStatusRegistry, {session_key, channel_id})
    state = :sys.get_state(pid)
    assert state.actions["a1"].phase == :started

    assert :ok = ToolStatusCoalescer.finalize_run(session_key, channel_id, run_id, true)

    assert eventually(fn ->
             state2 = :sys.get_state(pid)
             state2.actions["a1"].phase == :completed and state2.actions["a1"].ok == true
           end)
  end

  test "telegram tool status creates a new message when only progress_msg_id is present (no status_msg_id)" do
    session_key = "agent:tool-status:telegram:bot:group:12345:thread:777"
    channel_id = "telegram"
    run_id = "run_#{System.unique_integer([:positive])}"
    progress_msg_id = 9001

    started = %{
      engine: "lemon",
      action: %{id: "a1", kind: "tool", title: "Read: foo.txt", detail: %{}},
      phase: :started,
      ok: nil,
      message: nil,
      level: nil
    }

    # When only progress_msg_id is provided (without status_msg_id),
    # the coalescer should create a new status message instead of trying to edit the user's message
    assert :ok =
             ToolStatusCoalescer.ingest_action(session_key, channel_id, run_id, started,
               meta: %{user_msg_id: 9, progress_msg_id: progress_msg_id}
             )

    assert :ok = ToolStatusCoalescer.flush(session_key, channel_id)

    # Should create a new text message (not edit) since status_msg_id is nil
    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      channel_id: "telegram",
                      kind: :text,
                      peer: %{id: "12345", thread_id: "777"},
                      reply_to: 9,
                      meta: %{run_id: ^run_id}
                    }},
                   1_000

    # Wait until the coalescer captures status_msg_id from the outbox delivery ack.
    [{pid, _}] = Registry.lookup(Elixir.LemonRouter.ToolStatusRegistry, {session_key, channel_id})

    status_id =
      Enum.reduce_while(1..50, nil, fn _, _ ->
        state = :sys.get_state(pid)
        id = state.meta[:status_msg_id]

        if is_integer(id) do
          {:halt, id}
        else
          Process.sleep(10)
          {:cont, nil}
        end
      end)

    assert status_id == 1001

    # Now subsequent updates should edit the status message
    completed = %{started | phase: :completed, ok: true}
    assert :ok = ToolStatusCoalescer.ingest_action(session_key, channel_id, run_id, completed)
    assert :ok = ToolStatusCoalescer.flush(session_key, channel_id)

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      channel_id: "telegram",
                      kind: :edit,
                      peer: %{id: "12345", thread_id: "777"},
                      content: %{message_id: 1001, text: text},
                      meta: %{run_id: ^run_id}
                    }},
                   1_000

    assert String.contains?(text, "Tool calls:")
  end

  test "finalize_run does not create status output when there are no tool actions" do
    session_key = "agent:tool-status:telegram:bot:group:12345:thread:777"
    channel_id = "telegram"
    run_id = "run_#{System.unique_integer([:positive])}"
    progress_msg_id = 9002

    # finalize_run should be a no-op when no tool actions were ingested.
    assert :ok =
             ToolStatusCoalescer.finalize_run(session_key, channel_id, run_id, true,
               meta: %{user_msg_id: 9, progress_msg_id: progress_msg_id}
             )

    refute_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      channel_id: "telegram",
                      meta: %{run_id: ^run_id}
                    }},
                   300
  end

  test "finalize_run does not emit synthetic done on failed runs without tool actions" do
    session_key = "agent:tool-status:telegram:bot:group:12345:thread:777"
    channel_id = "telegram"
    run_id = "run_#{System.unique_integer([:positive])}"

    assert :ok =
             ToolStatusCoalescer.finalize_run(session_key, channel_id, run_id, false,
               meta: %{user_msg_id: 9, progress_msg_id: 9003}
             )

    refute_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      channel_id: "telegram",
                      meta: %{run_id: ^run_id}
                    }},
                   300
  end

  test "telegram tool status falls back to a dedicated status message when progress_msg_id is nil" do
    session_key = "agent:tool-status:telegram:bot:group:12345:thread:777"
    channel_id = "telegram"
    run_id = "run_#{System.unique_integer([:positive])}"

    started = %{
      engine: "lemon",
      action: %{id: "a1", kind: "tool", title: "Read: foo.txt", detail: %{}},
      phase: :started,
      ok: nil,
      message: nil,
      level: nil
    }

    assert :ok =
             ToolStatusCoalescer.ingest_action(session_key, channel_id, run_id, started,
               meta: %{user_msg_id: 9}
             )

    assert :ok = ToolStatusCoalescer.flush(session_key, channel_id)

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      channel_id: "telegram",
                      kind: :text,
                      peer: %{id: "12345", thread_id: "777"},
                      reply_to: 9,
                      meta: %{reply_markup: reply_markup}
                    }},
                   1_000

    assert reply_markup == %{
             "inline_keyboard" => [
               [
                 %{
                   "text" => "cancel",
                   "callback_data" => "lemon:cancel:#{run_id}"
                 }
               ]
             ]
           }

    # Wait until the coalescer captures status_msg_id from the outbox delivery ack.
    [{pid, _}] = Registry.lookup(Elixir.LemonRouter.ToolStatusRegistry, {session_key, channel_id})

    status_id =
      Enum.reduce_while(1..50, nil, fn _, _ ->
        state = :sys.get_state(pid)
        id = state.meta[:status_msg_id]

        if is_integer(id) do
          {:halt, id}
        else
          Process.sleep(10)
          {:cont, nil}
        end
      end)

    assert status_id == 1001

    assert :ok = ToolStatusCoalescer.finalize_run(session_key, channel_id, run_id, true)

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      channel_id: "telegram",
                      kind: :edit,
                      peer: %{id: "12345", thread_id: "777"},
                      content: %{message_id: 1001},
                      meta: %{reply_markup: %{"inline_keyboard" => []}, run_id: ^run_id}
                    }},
                   1_000
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
end
