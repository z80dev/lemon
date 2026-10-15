defmodule LemonRouter.CoalescerIngress do
  @moduledoc false

  alias LemonCore.Bus.Delivery

  # Metadata belongs to the coalescer's existing Registry entry. There is no
  # forwarding process or second event queue before its bounded mailbox.
  def register(registry, key, opts) do
    delivery =
      Delivery.new(self(),
        tagged: true,
        max_queue: Keyword.get(opts, :max_queue, 256),
        max_bytes: Keyword.get(opts, :max_bytes, 65_536)
      )

    Registry.update_value(registry, key, fn _ -> %{delivery: delivery, completed: []} end)
    delivery
  end

  def push(registry, key, run_id, message) do
    case Registry.lookup(registry, key) do
      [{_pid, %{delivery: delivery, completed: completed}}] ->
        unless run_id in completed, do: Delivery.send(delivery, message)

      _ ->
        :ok
    end

    :ok
  end

  def completed?(registry, key, run_id) do
    case Registry.lookup(registry, key) do
      [{_pid, %{completed: completed}}] -> run_id in completed
      _ -> false
    end
  end

  # Rotation fences all already-admitted messages from the previous transport
  # generation. Recent terminal run IDs also reject late API callers; active
  # producers are run-owned and stop before subsequent conversation work begins.
  def complete(registry, key, delivery, run_id) do
    Delivery.close(delivery)

    next =
      Delivery.new(self(),
        tagged: true,
        max_queue: delivery.max_queue,
        max_bytes: delivery.max_bytes
      )

    Registry.update_value(registry, key, fn %{completed: completed} ->
      %{
        delivery: next,
        completed: Enum.take([run_id | Enum.reject(completed, &(&1 == run_id))], 128)
      }
    end)

    next
  end

  def observe_overflow(state) do
    if not state.overflowed and Delivery.closed?(state.delivery) do
      if state.flush_timer, do: Process.cancel_timer(state.flush_timer)
      resync(state.session_key, state.run_id)
      %{state | overflowed: true, flush_timer: nil}
    else
      state
    end
  end

  def resync(session_key, run_id) do
    if LemonCore.Bus.running?() do
      LemonCore.Bus.broadcast(
        LemonCore.Bus.session_topic(session_key),
        LemonCore.Event.new(:stream_resync, %{reason: :overflow}, %{
          session_key: session_key,
          run_id: run_id
        })
      )
    end

    :ok
  end
end
