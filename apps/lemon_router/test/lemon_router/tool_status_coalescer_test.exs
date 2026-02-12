defmodule LemonRouter.ToolStatusCoalescerTest do
  use ExUnit.Case, async: false

  alias LemonRouter.ToolStatusCoalescer

  defmodule TestOutboxAPI do
    @moduledoc false
    use Agent

    def start_link(opts) do
      notify_pid = opts[:notify_pid]
      Agent.start_link(fn -> %{calls: [], notify_pid: notify_pid} end, name: __MODULE__)
    end

    def calls, do: Agent.get(__MODULE__, fn s -> Enum.reverse(s.calls) end)

    def clear, do: Agent.update(__MODULE__, &%{&1 | calls: []})

    def send_message(_token, chat_id, text, opts_or_reply_to \\ nil, parse_mode \\ nil) do
      record({:send, chat_id, text, opts_or_reply_to, parse_mode})
      {:ok, %{"ok" => true, "result" => %{"message_id" => 1001}}}
    end

    def edit_message_text(_token, chat_id, message_id, text, opts \\ nil) do
      record({:edit, chat_id, message_id, text, opts})
      {:ok, %{"ok" => true}}
    end

    def delete_message(_token, chat_id, message_id) do
      record({:delete, chat_id, message_id})
      {:ok, %{"ok" => true}}
    end

    defp record(call) do
      Agent.update(__MODULE__, fn s -> %{s | calls: [call | s.calls]} end)
      notify_pid = Agent.get(__MODULE__, & &1.notify_pid)
      if is_pid(notify_pid), do: send(notify_pid, {:outbox_api_call, call})
      :ok
    end
  end

  setup do
    if is_nil(Process.whereis(LemonRouter.ToolStatusRegistry)) do
      {:ok, _} = Registry.start_link(keys: :unique, name: LemonRouter.ToolStatusRegistry)
    end

    if is_nil(Process.whereis(LemonRouter.ToolStatusSupervisor)) do
      {:ok, _} =
        DynamicSupervisor.start_link(
          strategy: :one_for_one,
          name: LemonRouter.ToolStatusSupervisor
        )
    end

    # Keep legacy tests deterministic: they don't depend on the Telegram outbox.
    if pid = Process.whereis(LemonGateway.Telegram.Outbox) do
      GenServer.stop(pid)
    end

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
             Registry.lookup(LemonRouter.ToolStatusRegistry, {session_key, channel_id})
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

    [{pid, _}] = Registry.lookup(LemonRouter.ToolStatusRegistry, {session_key, channel_id})
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

    [{pid, _}] = Registry.lookup(LemonRouter.ToolStatusRegistry, {session_key, channel_id})
    state = :sys.get_state(pid)
    assert state.actions["a1"].phase == :started

    assert :ok = ToolStatusCoalescer.finalize_run(session_key, channel_id, run_id, true)

    assert eventually(fn ->
             state2 = :sys.get_state(pid)
             state2.actions["a1"].phase == :completed and state2.actions["a1"].ok == true
           end)
  end

  test "telegram status uses LemonGateway.Telegram.Outbox (create then edit), preserving thread_id" do
    {:ok, _} = start_supervised({TestOutboxAPI, [notify_pid: self()]})

    {:ok, _} =
      start_supervised(
        {LemonGateway.Telegram.Outbox,
         [bot_token: "token", api_mod: TestOutboxAPI, edit_throttle_ms: 0, use_markdown: false]}
      )

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

    # Wait until the coalescer captures status_msg_id from the outbox delivery ack.
    [{pid, _}] = Registry.lookup(LemonRouter.ToolStatusRegistry, {session_key, channel_id})

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

    calls = TestOutboxAPI.calls()
    assert {:send, 12_345, _text, opts, nil} = hd(calls)
    assert is_map(opts)
    assert opts[:message_thread_id] == 777
    assert opts[:reply_to_message_id] == 9

    completed = %{started | phase: :completed, ok: true}
    assert :ok = ToolStatusCoalescer.ingest_action(session_key, channel_id, run_id, completed)
    assert :ok = ToolStatusCoalescer.flush(session_key, channel_id)

    assert_receive {:outbox_api_call, {:edit, 12_345, 1001, _text, nil}}, 500
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
