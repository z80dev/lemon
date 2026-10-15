defmodule LemonCore.Bus.Delivery do
  @moduledoc """
  Nonblocking, node-local admission for transient event delivery.

  A handle is shared by every producer/topic targeting a consumer. Before sending,
  admission checks the actual mailbox length and the encoded size of the message,
  including excess binary backing retained by sub-binaries. `max_bytes` is a
  per-message limit, not an aggregate retained-byte quota. This
  bounds admitted mailbox entries to `max_queue` plus one overflow notification;
  unrelated messages and publishers bypassing this handle are not bounded here.

  Pressure (including concurrent admission contention) permanently fences the
  handle and sends one small caller-supplied recovery notification. There is no
  waiting, task, acknowledgement protocol, or retained event buffer. Recovery must
  close the old handle, unsubscribe, and subscribe using a new handle after reading
  authoritative state. Accepted events already in the mailbox remain ordered only
  within their publisher; consumers must fence stale events during reconciliation.
  Dead consumers require no cleanup process or global registration.

  Use `tagged: true` for consumers that recover in the same process. Both events
  and recovery notifications become `{:lemon_bus_delivery, gate_ref, message}`;
  accept them only when `matches?(current_handle, gate_ref)`. This rejects the
  possible in-flight old send racing with handle replacement. The byte limit
  includes this envelope. Recovery control messages are capped at 1024 encoded
  bytes; `terminal/2` optionally reserves one additional 1024-byte terminal slot.
  """

  import Kernel, except: [send: 2]

  @enforce_keys [:pid, :gate, :max_queue, :max_bytes, :overflow_message]
  defstruct [:pid, :gate, :max_queue, :max_bytes, :overflow_message, tagged: false]
  @type t :: %__MODULE__{}

  def new(pid, opts \\ []) when is_pid(pid) and node(pid) == node() do
    max_queue = Keyword.get(opts, :max_queue, 256)
    max_bytes = Keyword.get(opts, :max_bytes, 1_048_576)

    if not (is_integer(max_queue) and max_queue > 0 and is_integer(max_bytes) and max_bytes > 0) do
      raise ArgumentError, "delivery limits must be positive integers"
    end

    delivery = %__MODULE__{
      pid: pid,
      gate: :atomics.new(3, signed: false),
      max_queue: max_queue,
      max_bytes: max_bytes,
      overflow_message: Keyword.get(opts, :overflow_message, {:stream_resync, :overflow}),
      tagged: Keyword.get(opts, :tagged, false)
    }

    if not fits?(envelope(delivery, delivery.overflow_message), 1024) do
      raise ArgumentError, "overflow notification must fit within 1024 encoded bytes"
    end

    delivery
  end

  @doc "Permanently fences this handle without sending a recovery notification."
  def close(%__MODULE__{gate: gate}) do
    :atomics.put(gate, 2, 1)
    :ok
  end

  @doc "Fences delivery and emits its one-shot recovery notification."
  def resync(%__MODULE__{} = delivery), do: overflow(delivery)

  @doc """
  Reserves one small owner-terminal notification after a fenced delivery.
  This adds at most one entry beyond the queue and overflow notification.
  It never reopens delivery; subsequent terminal or progress sends are ignored.
  """
  def terminal(%__MODULE__{} = delivery, message) do
    message = envelope(delivery, message)

    if fits?(message, 1024) and
         :atomics.compare_exchange(delivery.gate, 3, 0, 1) == :ok do
      Kernel.send(delivery.pid, message)
    end

    :ok
  end

  def closed?(%__MODULE__{gate: gate}), do: :atomics.get(gate, 2) != 0

  @doc "Checks a tagged envelope against the current consumer-owned handle."
  def matches?(%__MODULE__{gate: gate}, gate), do: true
  def matches?(_delivery, _gate), do: false

  def send(%__MODULE__{} = delivery, message) do
    cond do
      :atomics.get(delivery.gate, 2) != 0 ->
        {:error, :closed}

      :atomics.compare_exchange(delivery.gate, 1, 0, 1) != :ok ->
        overflow(delivery)

      true ->
        try do
          admit(delivery, message)
        after
          :atomics.put(delivery.gate, 1, 0)
        end
    end
  end

  defp admit(delivery, message) do
    message = envelope(delivery, message)

    case Process.info(delivery.pid, :message_queue_len) do
      nil ->
        close(delivery)
        {:error, :closed}

      {:message_queue_len, size} ->
        cond do
          :atomics.get(delivery.gate, 2) != 0 ->
            {:error, :closed}

          size >= delivery.max_queue ->
            overflow(delivery)

          not fits?(message, delivery.max_bytes) ->
            overflow(delivery)

          true ->
            Kernel.send(delivery.pid, message)
            :ok
        end
    end
  end

  defp overflow(delivery) do
    if :atomics.compare_exchange(delivery.gate, 2, 0, 1) == :ok do
      Kernel.send(delivery.pid, envelope(delivery, delivery.overflow_message))
    end

    {:error, :overflow}
  end

  # external_size counts a sub-binary's visible bytes, not its retained parent.
  # Reject excessive backing before send rather than copying every payload.
  defp fits?(message, limit) do
    encoded = :erlang.external_size(message)
    encoded <= limit and backing_budget(message, limit - encoded) >= 0
  end

  defp backing_budget(_value, budget) when budget < 0, do: budget

  defp backing_budget(value, budget) when is_binary(value),
    do: budget - (:binary.referenced_byte_size(value) - byte_size(value))

  defp backing_budget([head | tail], budget),
    do: backing_budget(tail, backing_budget(head, budget))

  defp backing_budget(value, budget) when is_tuple(value),
    do: tuple_backing_budget(value, tuple_size(value), budget)

  defp backing_budget(value, budget) when is_map(value),
    do: map_backing_budget(:maps.iterator(value), budget)

  defp backing_budget(_value, budget), do: budget

  defp tuple_backing_budget(_value, _index, budget) when budget < 0, do: budget
  defp tuple_backing_budget(_value, 0, budget), do: budget

  defp tuple_backing_budget(value, index, budget),
    do: tuple_backing_budget(value, index - 1, backing_budget(elem(value, index - 1), budget))

  defp map_backing_budget(_iterator, budget) when budget < 0, do: budget

  defp map_backing_budget(iterator, budget) do
    case :maps.next(iterator) do
      :none ->
        budget

      {key, value, next} ->
        map_backing_budget(next, backing_budget(value, backing_budget(key, budget)))
    end
  end

  defp envelope(%{tagged: true, gate: gate}, message), do: {:lemon_bus_delivery, gate, message}
  defp envelope(_delivery, message), do: message
end
