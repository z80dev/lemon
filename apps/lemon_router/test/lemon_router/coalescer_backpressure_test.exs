defmodule LemonRouter.CoalescerBackpressureTest do
  use ExUnit.Case, async: false

  alias LemonRouter.{StreamCoalescer, ToolStatusCoalescer}

  defmodule Dispatcher do
    def dispatch(intent) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:intent, intent})
      :ok
    end
  end

  setup do
    for registry <- [LemonRouter.CoalescerRegistry, LemonRouter.ToolStatusRegistry] do
      unless Process.whereis(registry) do
        start_supervised!(
          Supervisor.child_spec({Registry, keys: :unique, name: registry}, id: registry)
        )
      end
    end

    original = Application.get_env(:lemon_router, :dispatcher)
    Application.put_env(:lemon_router, :dispatcher, Dispatcher)
    :persistent_term.put({Dispatcher, :test_pid}, self())

    on_exit(fn ->
      :persistent_term.erase({Dispatcher, :test_pid})

      if is_nil(original),
        do: Application.delete_env(:lemon_router, :dispatcher),
        else: Application.put_env(:lemon_router, :dispatcher, original)
    end)

    :ok
  end

  test "answer mailbox overflow requires canonical final text and rejects obsolete transport generations" do
    session = session_key()
    pid = start_supervised!({StreamCoalescer, opts(session) ++ [min_chars: 1_000_000]})

    [{^pid, %{delivery: old}}] =
      Registry.lookup(LemonRouter.CoalescerRegistry, {session, "telegram"})

    :ok = LemonCore.Bus.subscribe(LemonCore.Bus.session_topic(session))
    :ok = :sys.suspend(pid)

    for seq <- 1..1000,
        do: StreamCoalescer.ingest_delta(session, "telegram", "run-1", seq, "delta")

    assert_bounded_mailbox(pid)
    :ok = :sys.resume(pid)
    assert %{overflowed: true} = :sys.get_state(pid)
    assert_receive %LemonCore.Event{type: :stream_resync, payload: %{reason: :overflow}}
    assert nil == StreamCoalescer.current_text(session, "telegram", "run-1")

    assert {:error, :resync_required} =
             StreamCoalescer.finalize_run(session, "telegram", "run-1", dispatch?: false)

    assert :ok =
             StreamCoalescer.finalize_run(session, "telegram", "run-1",
               final_text: "complete canonical answer",
               dispatch?: false
             )

    assert %{finalized: true, last_sent_text: "complete canonical answer", overflowed: false} =
             :sys.get_state(pid)

    # A message admitted by the old handle can race the resync marker. Its tag
    # must not mutate the recovered generation, even after another run starts.
    send(pid, {:lemon_bus_delivery, old.gate, {:delta, "run-1", 9999, "obsolete", %{}}})
    StreamCoalescer.ingest_delta(session, "telegram", "run-1", 10000, "late API call")
    assert %{finalized: true, last_sent_text: "complete canonical answer"} = :sys.get_state(pid)
    StreamCoalescer.ingest_delta(session, "telegram", "run-2", 1, "current")
    send(pid, {:lemon_bus_delivery, old.gate, {:delta, "run-1", 10001, "obsolete", %{}}})
    assert %{run_id: "run-2", full_text: "current", finalized: false} = :sys.get_state(pid)
    current = :sys.get_state(pid)

    assert :ok =
             StreamCoalescer.finalize_run(session, "telegram", "run-1",
               final_text: "obsolete final answer",
               dispatch?: false
             )

    assert :sys.get_state(pid) == current
  end

  test "replaceable tool progress coalesces into one action without retaining every update" do
    session = session_key()
    pid = start_supervised!({ToolStatusCoalescer, opts(session)})

    for n <- 1..1000 do
      ToolStatusCoalescer.ingest_action(session, "telegram", "run-1", action(n))
      state = :sys.get_state(pid)
      assert map_size(state.actions) == 1
      assert length(state.order) == 1
      refute state.overflowed
    end

    state = :sys.get_state(pid)
    assert state.actions["tool-1"].title == "Progress 1000"
    assert :ok = ToolStatusCoalescer.finalize_run(session, "telegram", "run-1", true)
    assert %{phase: :completed, ok: true} = :sys.get_state(pid).actions["tool-1"]
  end

  test "status overflow finalizes known actions with a fixed recovery indication and no late revival" do
    session = session_key()
    pid = start_supervised!({ToolStatusCoalescer, opts(session)})
    ToolStatusCoalescer.ingest_action(session, "telegram", "run-1", action(0))
    :sys.get_state(pid)

    [{^pid, %{delivery: old}}] =
      Registry.lookup(LemonRouter.ToolStatusRegistry, {session, "telegram"})

    :ok = :sys.suspend(pid)

    for n <- 1..1000,
        do: ToolStatusCoalescer.ingest_action(session, "telegram", "run-1", action(n))

    assert_bounded_mailbox(pid)
    :ok = :sys.resume(pid)
    assert %{overflowed: true} = :sys.get_state(pid)
    assert :ok = ToolStatusCoalescer.finalize_run(session, "telegram", "run-1", false)

    assert %{
             finalized: true,
             overflowed: false,
             actions: %{"tool-1" => %{phase: :completed, ok: false}}
           } = :sys.get_state(pid)

    assert_receive {:intent, %{kind: :tool_status_finalize, body: %{text: text}}}

    assert text ==
             "Progress updates were interrupted. Refresh session state for current tool results."

    send(pid, {:lemon_bus_delivery, old.gate, {:action, "run-1", action(9999), %{}}})
    ToolStatusCoalescer.ingest_action(session, "telegram", "run-1", action(10000))

    assert %{finalized: true, actions: %{"tool-1" => %{phase: :completed, ok: false}}} =
             :sys.get_state(pid)

    ToolStatusCoalescer.ingest_action(session, "telegram", "run-2", action(1))
    current = :sys.get_state(pid)
    assert current.run_id == "run-2"
    refute current.finalized
    assert :ok = ToolStatusCoalescer.finalize_run(session, "telegram", "run-1", true)
    assert :sys.get_state(pid) == current
  end

  test "run completion rotates transport gates without accumulating unbounded registry tombstones" do
    session = session_key()
    pid = start_supervised!({StreamCoalescer, opts(session)})

    for n <- 1..160 do
      assert :ok =
               StreamCoalescer.finalize_run(
                 session,
                 "telegram",
                 "run-#{n}",
                 final_text: "canonical",
                 dispatch?: false
               )
    end

    assert [{^pid, %{completed: completed}}] =
             Registry.lookup(
               LemonRouter.CoalescerRegistry,
               {session, "telegram"}
             )

    assert length(completed) == 128
    assert hd(completed) == "run-160"
    refute "run-1" in completed
    assert :erlang.external_size(completed) < 4096
  end

  defp opts(session) do
    [
      session_key: session,
      channel_id: "telegram",
      max_queue: 8,
      max_bytes: 1024,
      idle_ms: 60_000,
      max_latency_ms: 60_000
    ]
  end

  defp session_key,
    do: "agent:pressure-#{System.unique_integer([:positive])}:telegram:bot:dm:user"

  defp action(n) do
    %{
      engine: "lemon",
      action: %{id: "tool-1", kind: "tool", title: "Progress #{n}", detail: %{}},
      phase: :updated,
      ok: nil,
      message: nil,
      level: nil
    }
  end

  defp assert_bounded_mailbox(pid) do
    assert {:message_queue_len, count} = Process.info(pid, :message_queue_len)
    assert count <= 9
    assert {:messages, messages} = Process.info(pid, :messages)

    assert Enum.reduce(messages, 0, fn message, bytes ->
             bytes + :erlang.external_size(message)
           end) <= 8 * 1024 + 1024
  end
end
