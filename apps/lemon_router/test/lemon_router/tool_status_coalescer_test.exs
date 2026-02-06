defmodule LemonRouter.ToolStatusCoalescerTest do
  use ExUnit.Case, async: false

  alias LemonRouter.ToolStatusCoalescer

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

    :ok
  end

  test "starts coalescer and accepts action events" do
    session_key = "agent:test:telegram:bot:dm:123"
    channel_id = "telegram"
    run_id = "run_#{System.unique_integer([:positive])}"

    action = %LemonGateway.Event.Action{
      id: "a1",
      kind: "tool",
      title: "Read: foo.txt",
      detail: %{}
    }

    ev = %LemonGateway.Event.ActionEvent{
      engine: "lemon",
      action: action,
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

    action = %LemonGateway.Event.Action{id: "n1", kind: "note", title: "thinking", detail: %{}}

    ev = %LemonGateway.Event.ActionEvent{
      engine: "lemon",
      action: action,
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

    action = %LemonGateway.Event.Action{id: "a1", kind: "tool", title: "Test tool", detail: %{}}

    ev = %LemonGateway.Event.ActionEvent{
      engine: "lemon",
      action: action,
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
end
