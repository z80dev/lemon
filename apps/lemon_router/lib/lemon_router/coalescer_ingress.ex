defmodule LemonRouter.CoalescerIngress do
  @moduledoc false

  # Ingress, completion fencing and lifetime protocol shared by
  # `StreamCoalescer` and `ToolStatusCoalescer`.
  #
  # Population bound: a coalescer exists per conversation surface only while it
  # has work. It retires (`{:stop, :normal}`) once it has been idle for
  # `retire_after_ms/0` and its run is finalized, never started, or no longer
  # has a live producer (`RunProcess`, or an async task-surface subscriber).
  # Retirement closes the ingress generation, waits for its admission process so
  # every admitted message is already queued, and stops only with an empty
  # mailbox. Producers that raced it observe the closed generation and retry
  # against the replacement, and calls that reach a retired process retry
  # through a fresh lookup, so no admitted work is lost.

  require Logger

  alias LemonCore.Bus.Delivery

  # Per-message ingress budget: the bounded mailbox and the largest admitted
  # delivery message (envelope included).
  @default_max_queue 256
  @default_max_bytes 65_536

  # Idle grace before a finalized or orphaned coalescer stops. It covers the
  # router's completion grace windows (at most 1,500 ms in `RunProcess`) with
  # margin, so in-flight messages of a completed run still meet the completion
  # fence, while back-to-back runs in one conversation reuse the process.
  @default_retire_after_ms 5_000

  # Producers retry a closed generation for at most this many 1 ms steps; the
  # retirement handshake it waits for is a bounded mailbox check.
  @push_attempts 100
  @call_attempts 3
  @admitter_exit_timeout_ms 5_000

  # Metadata belongs to the coalescer's existing Registry entry. There is no
  # forwarding process or second event queue before its bounded mailbox.
  def register(registry, key, opts) do
    delivery =
      Delivery.new(self(),
        tagged: true,
        max_queue: Keyword.get(opts, :max_queue, @default_max_queue),
        max_bytes: Keyword.get(opts, :max_bytes, @default_max_bytes)
      )

    Registry.update_value(registry, key, fn _ ->
      %{delivery: delivery, completed: [], retiring: false}
    end)

    delivery
  end

  @doc """
  Pushes `message` into the coalescer registered under `key`.

  `start` (optional) starts a coalescer when none is registered; without it a
  missing coalescer means there is nothing to deliver to. Messages for a run
  in the completed fence are dropped. Returns `{:error, reason}` only when
  `start` fails.
  """
  def push(registry, key, run_id, message, start \\ nil),
    do: push(registry, key, run_id, message, start, @push_attempts)

  defp push(registry, _key, run_id, _message, _start, 0) do
    Logger.warning(
      "Coalescer ingress dropped a message after waiting for retirement " <>
        "registry=#{inspect(registry)} run_id=#{inspect(run_id)}"
    )

    :ok
  end

  defp push(registry, key, run_id, message, start, attempts) do
    case Registry.lookup(registry, key) do
      [{_pid, %{delivery: delivery, completed: completed}}] ->
        cond do
          run_id in completed ->
            :ok

          Delivery.send(delivery, message) == {:error, :closed} ->
            after_closed(registry, key, run_id, message, start, attempts, delivery)

          true ->
            :ok
        end

      # Registered but still initializing its ingress.
      [{_pid, _starting}] ->
        Process.sleep(1)
        push(registry, key, run_id, message, start, attempts - 1)

      [] when is_function(start, 0) ->
        case start.() do
          {:ok, _pid} -> push(registry, key, run_id, message, start, attempts - 1)
          {:error, _reason} = error -> error
        end

      [] ->
        :ok
    end
  end

  # A closed generation is either an overflow fence (recovery belongs to the
  # owner's resync), a rotation after completion, or a retirement in progress.
  defp after_closed(registry, key, run_id, message, start, attempts, delivery) do
    case Registry.lookup(registry, key) do
      [{_pid, %{delivery: ^delivery, retiring: true}}] ->
        Process.sleep(1)
        push(registry, key, run_id, message, start, attempts - 1)

      [{_pid, %{delivery: ^delivery}}] ->
        :ok

      _replaced_or_retired ->
        push(registry, key, run_id, message, start, attempts - 1)
    end
  end

  @doc """
  Calls the coalescer registered under `key`.

  Returns `{:ok, reply}`, `:none` when no coalescer is registered and `start`
  is nil, or `{:error, reason}` when `start` fails. A call that reaches a
  coalescer which retired (`:noproc` / `:normal` exit) was never handled, so it
  is retried against a fresh lookup. Other exits propagate to the caller.
  """
  def call(registry, key, request, timeout, start \\ nil),
    do: call(registry, key, request, timeout, start, @call_attempts)

  defp call(registry, key, request, timeout, start, attempts) do
    case lookup_or_start(registry, key, start) do
      {:ok, pid} ->
        try do
          {:ok, GenServer.call(pid, request, timeout)}
        catch
          :exit, {reason, _} when reason in [:noproc, :normal] and attempts > 1 ->
            call(registry, key, request, timeout, start, attempts - 1)
        end

      other ->
        other
    end
  end

  defp lookup_or_start(registry, key, start) do
    case Registry.lookup(registry, key) do
      [{pid, _value}] -> {:ok, pid}
      [] when is_function(start, 0) -> start.()
      [] -> :none
    end
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
    next = next_generation(delivery)

    Registry.update_value(registry, key, fn %{completed: completed} = value ->
      %{
        value
        | delivery: next,
          completed: Enum.take([run_id | Enum.reject(completed, &(&1 == run_id))], 128)
      }
    end)

    next
  end

  @doc "Idle grace before a finalized or orphaned coalescer retires."
  def retire_after_ms(opts) do
    case Keyword.get_lazy(opts, :retire_after_ms, fn ->
           Application.get_env(:lemon_router, :coalescer_retire_after_ms)
         end) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @default_retire_after_ms
    end
  end

  @doc "Arms the retirement check `after_ms` from now."
  def schedule_retire_check(after_ms) do
    Process.send_after(self(), :retire_check, after_ms)
  end

  @doc """
  Runs a due retirement check for a coalescer state with `:delivery`,
  `:last_activity_ms` and `:retire_after_ms` fields.

  `retirable?` says whether the state holds nothing a live producer still
  needs. Returns `{:stop, state}` when the coalescer has unregistered and must
  stop normally, otherwise `{:keep, state, admitted}` with the next check
  armed: `admitted` are messages the closed generation had already admitted,
  in order, which the caller must process before anything else.
  """
  def retire_check(state, registry, key, retirable?) do
    idle_ms = System.monotonic_time(:millisecond) - state.last_activity_ms

    cond do
      idle_ms < state.retire_after_ms ->
        schedule_retire_check(state.retire_after_ms - idle_ms)
        {:keep, state, []}

      mailbox_len() > 0 or not retirable?.(state) ->
        schedule_retire_check(state.retire_after_ms)
        {:keep, state, []}

      true ->
        retire(state, registry, key)
    end
  end

  defp retire(state, registry, key) do
    {_, _} = Registry.update_value(registry, key, &%{&1 | retiring: true})
    Delivery.close(state.delivery)

    # The admission process exits after any admission it already started, and
    # its last message reaches this mailbox before its exit signal.
    if admitter_exited?(state.delivery) and mailbox_len() == 0 do
      Registry.unregister(registry, key)
      {:stop, state}
    else
      # Work arrived during the handshake. Keep running on a new generation;
      # messages the closed generation already admitted still belong to us.
      admitted = drain_generation(state.delivery.gate, [])
      delivery = next_generation(state.delivery)
      Registry.update_value(registry, key, &%{&1 | delivery: delivery, retiring: false})
      schedule_retire_check(state.retire_after_ms)
      {:keep, %{state | delivery: delivery}, admitted}
    end
  end

  defp drain_generation(gate, acc) do
    receive do
      {:lemon_bus_delivery, ^gate, message} -> drain_generation(gate, [message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp admitter_exited?(%Delivery{admitter: admitter}) when is_pid(admitter) do
    ref = Process.monitor(admitter)

    receive do
      {:DOWN, ^ref, :process, ^admitter, _reason} -> true
    after
      @admitter_exit_timeout_ms ->
        Process.demonitor(ref, [:flush])
        false
    end
  end

  defp admitter_exited?(_delivery), do: true

  defp next_generation(delivery) do
    Delivery.new(self(),
      tagged: true,
      max_queue: delivery.max_queue,
      max_bytes: delivery.max_bytes
    )
  end

  defp mailbox_len do
    {:message_queue_len, len} = Process.info(self(), :message_queue_len)
    len
  end

  @doc """
  Whether the run that owns `run_id` (or, for a task surface, its async
  subscriber) may still produce output. A registry that cannot be read counts
  as alive: retirement fails closed.
  """
  def producer_alive?(nil, _surface), do: false

  def producer_alive?(run_id, surface) do
    Registry.lookup(LemonRouter.RunRegistry, run_id) != [] or
      Registry.select(LemonRouter.AsyncTaskSurfaceRegistry, [
        {{:_, :_, %{parent_run_id: run_id, surface: surface}}, [], [true]}
      ]) != []
  rescue
    ArgumentError -> true
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
