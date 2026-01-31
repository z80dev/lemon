defmodule AgentCore.EventStream do
  @moduledoc """
  Async event stream for streaming Agent responses with OTP-compliant lifecycle management.

  This module provides a producer/consumer pattern for streaming events
  from agent execution with the following BEAM/OTP guarantees:

  ## Features

  - **Owner Monitoring**: Streams are linked to an owner process and automatically
    cancel when the owner dies.
  - **Task Linking**: Streaming tasks can be attached and are properly shutdown
    when the stream is canceled.
  - **Bounded Queues**: Configurable queue limits prevent unbounded memory growth.
  - **Backpressure**: `push/2` returns `:ok | {:error, :overflow}` for flow control.
  - **Cancellation**: Explicit `cancel/2` API for clean stream termination.
  - **Timeouts**: Configurable stream timeout with automatic cancellation.

  ## Usage

      # Start a stream with options
      {:ok, stream} = EventStream.start_link(
        owner: self(),
        max_queue: 1000,
        timeout: 300_000
      )

      # Producer pushes events (with backpressure)
      case EventStream.push(stream, {:tool_call, %{name: "read_file"}}) do
        :ok -> :continue
        {:error, :overflow} -> :stop_producing
      end

      # Or use async push for fire-and-forget
      EventStream.push_async(stream, {:agent_start})

      # Consumer reads events
      stream
      |> EventStream.events()
      |> Enum.each(fn event -> IO.inspect(event) end)

      # Get the final result
      {:ok, messages} = EventStream.result(stream)

      # Or cancel explicitly
      EventStream.cancel(stream, :user_requested)

  ## Terminal Events

  The stream terminates when one of these events is received:
  - `{:agent_end, messages}` - Successful completion with final message list
  - `{:error, reason, partial_state}` - Error with reason and any partial state
  - `{:canceled, reason}` - Stream was canceled
  """

  use GenServer

  require Logger

  # ============================================================================
  # Constants
  # ============================================================================

  @default_max_queue 10_000
  @default_timeout 300_000

  # ============================================================================
  # Event Types
  # ============================================================================

  @typedoc """
  Agent events that can be pushed to the stream.

  Terminal events:
  - `{:agent_end, messages}` - Successful completion
  - `{:error, reason, partial_state}` - Error state
  - `{:canceled, reason}` - Stream was canceled

  Non-terminal events can be any term representing agent activity.
  """
  @type event ::
          {:agent_start, map()}
          | {:agent_end, list()}
          | {:tool_call, map()}
          | {:tool_result, map()}
          | {:thinking, String.t()}
          | {:text_delta, String.t()}
          | {:error, term(), term()}
          | {:canceled, term()}
          | term()

  @type t :: pid()

  @type drop_strategy :: :drop_oldest | :drop_newest | :error

  @type option ::
          {:owner, pid()}
          | {:max_queue, pos_integer()}
          | {:drop_strategy, drop_strategy()}
          | {:timeout, timeout()}

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Start a new event stream.

  ## Options

  - `:owner` - Process to monitor. Stream cancels if owner dies. Default: `self()`
  - `:max_queue` - Maximum events to buffer. Default: #{@default_max_queue}
  - `:drop_strategy` - What to do on overflow: `:drop_oldest`, `:drop_newest`, or `:error`.
    Default: `:error`
  - `:timeout` - Stream timeout in milliseconds. Default: #{@default_timeout}ms.
    Set to `:infinity` to disable timeout.

  ## Examples

      {:ok, stream} = AgentCore.EventStream.start_link(
        owner: self(),
        max_queue: 5000,
        timeout: 60_000
      )
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Attach a task to this event stream.

  When the stream is canceled or the owner dies, the attached task will be
  shutdown. Only one task can be attached at a time.
  """
  @spec attach_task(t(), pid()) :: :ok
  def attach_task(stream, task_pid) when is_pid(task_pid) do
    GenServer.cast(stream, {:attach_task, task_pid})
  end

  @doc """
  Push an event to the stream (synchronous with backpressure).

  Returns `:ok` on success or `{:error, :overflow}` if the queue is full
  (when using `:error` drop strategy) or `{:error, :canceled}` if the
  stream has been canceled.

  Use `push_async/2` if you don't need backpressure feedback.

  ## Examples

      case EventStream.push(stream, {:tool_call, %{name: "read_file"}}) do
        :ok -> :continue
        {:error, :overflow} -> :stop_producing
      end
  """
  @spec push(t(), event()) :: :ok | {:error, :overflow | :canceled}
  def push(stream, event) do
    GenServer.call(stream, {:push, event})
  catch
    :exit, {:noproc, _} -> {:error, :canceled}
    :exit, {:normal, _} -> {:error, :canceled}
    :exit, {:shutdown, _} -> {:error, :canceled}
  end

  @doc """
  Push an event to the stream (asynchronous, fire-and-forget).

  This is a non-blocking push that ignores backpressure. Use `push/2`
  if you need confirmation that the event was accepted.

  If using `:drop_oldest` or `:drop_newest` strategies, events will be
  dropped silently on overflow. With `:error` strategy, overflow events
  are still dropped but a warning is logged.

  ## Examples

      :ok = EventStream.push_async(stream, {:agent_start})
  """
  @spec push_async(t(), event()) :: :ok
  def push_async(stream, event) do
    GenServer.cast(stream, {:push, event})
  end

  @doc """
  Complete the stream with a final list of messages.

  This pushes an `{:agent_end, messages}` terminal event and marks
  the stream as done. After completion, `result/1` will return
  `{:ok, messages}`.

  ## Examples

      :ok = EventStream.complete(stream, [user_msg, assistant_msg])
  """
  @spec complete(t(), list()) :: :ok
  def complete(stream, messages) when is_list(messages) do
    GenServer.cast(stream, {:complete, messages})
  end

  @doc """
  Signal an error on the stream.

  This pushes an `{:error, reason, partial_state}` terminal event and marks
  the stream as done. After an error, `result/1` will return
  `{:error, reason, partial_state}`.

  ## Examples

      :ok = EventStream.error(stream, :timeout, %{messages: partial_messages})
  """
  @spec error(t(), term(), term()) :: :ok
  def error(stream, reason, partial_state \\ nil) do
    GenServer.cast(stream, {:error, reason, partial_state})
  end

  @doc """
  Cancel the stream with a reason.

  This will:
  1. Mark the stream as canceled
  2. Shutdown any attached task
  3. Wake up all waiters with a terminal event
  4. Stop the GenServer

  ## Examples

      :ok = EventStream.cancel(stream, :user_requested)
  """
  @spec cancel(t(), term()) :: :ok
  def cancel(stream, reason \\ :canceled) do
    GenServer.cast(stream, {:cancel, reason})
  end

  @doc """
  Get a lazy enumerable of events from the stream.

  This returns a Stream that will block when no events are available
  and complete when a terminal event is received. Terminal events
  (`{:agent_end, _}`, `{:error, _, _}`, or `{:canceled, _}`) are included
  in the stream before it halts.

  ## Examples

      stream
      |> EventStream.events()
      |> Enum.each(fn
        {:agent_end, messages} -> IO.puts("Done with \#{length(messages)} messages")
        {:tool_call, call} -> IO.puts("Calling tool: \#{call.name}")
        event -> IO.inspect(event)
      end)
  """
  @spec events(t()) :: Enumerable.t()
  def events(stream) do
    Stream.resource(
      fn -> {:active, stream} end,
      fn
        {:halting, _stream} ->
          {:halt, nil}

        {:active, stream} ->
          case safe_take(stream) do
            {:event, event} ->
              if terminal?(event) do
                # Yield the terminal event, then halt on next iteration
                {[event], {:halting, stream}}
              else
                {[event], {:active, stream}}
              end

            :done ->
              {:halt, nil}

            :canceled ->
              {:halt, nil}
          end
      end,
      fn _acc -> :ok end
    )
  end

  @doc """
  Get the final result of the stream, blocking until complete.

  Returns `{:ok, messages}` on successful completion or
  `{:error, reason, partial_state}` on error/cancellation.

  ## Options

  - `timeout` - How long to wait for completion (default: `:infinity`)

  ## Examples

      {:ok, messages} = EventStream.result(stream)
      {:ok, messages} = EventStream.result(stream, 5000)
  """
  @spec result(t(), timeout()) :: {:ok, list()} | {:error, term(), term()} | {:error, term()}
  def result(stream, timeout \\ :infinity) do
    GenServer.call(stream, :result, timeout)
  catch
    :exit, {:noproc, _} -> {:error, :stream_not_found}
    :exit, {:normal, _} -> {:error, :stream_closed}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  Get current queue statistics.

  Returns a map with:
  - `:queue_size` - Current number of buffered events
  - `:max_queue` - Maximum queue size
  - `:dropped` - Number of events dropped due to overflow

  ## Examples

      %{queue_size: 42, max_queue: 10000, dropped: 0} = EventStream.stats(stream)
  """
  @spec stats(t()) :: %{queue_size: non_neg_integer(), max_queue: pos_integer(), dropped: non_neg_integer()}
  def stats(stream) do
    GenServer.call(stream, :stats)
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    owner = Keyword.get(opts, :owner, self())
    max_queue = Keyword.get(opts, :max_queue, @default_max_queue)
    drop_strategy = Keyword.get(opts, :drop_strategy, :error)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    # Monitor the owner process (unless it's self, which is the stream itself)
    owner_ref = if owner != self(), do: Process.monitor(owner), else: nil

    # Set up stream timeout
    timeout_ref =
      if timeout != :infinity, do: Process.send_after(self(), :stream_timeout, timeout), else: nil

    state = %{
      events: :queue.new(),
      queue_size: 0,
      max_queue: max_queue,
      drop_strategy: drop_strategy,
      dropped: 0,
      take_waiters: :queue.new(),
      result_waiters: :queue.new(),
      result: nil,
      done: false,
      canceled: false,
      cancel_reason: nil,
      owner: owner,
      owner_ref: owner_ref,
      task_pid: nil,
      task_ref: nil,
      timeout_ref: timeout_ref
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:push, _event}, _from, %{canceled: true} = state) do
    {:reply, {:error, :canceled}, state}
  end

  def handle_call({:push, _event}, _from, %{done: true} = state) do
    {:reply, {:error, :canceled}, state}
  end

  def handle_call({:push, event}, _from, state) do
    case handle_push(event, state, log_on_overflow: false) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:overflow, new_state} ->
        {:reply, {:error, :overflow}, new_state}
    end
  end

  def handle_call(:take, from, state) do
    case :queue.out(state.events) do
      {{:value, event}, remaining} ->
        {:reply, {:event, event}, %{state | events: remaining, queue_size: state.queue_size - 1}}

      {:empty, _} ->
        if state.done or state.canceled do
          {:reply, :done, state}
        else
          # Add to waiters queue
          take_waiters = :queue.in(from, state.take_waiters)
          {:noreply, %{state | take_waiters: take_waiters}}
        end
    end
  end

  def handle_call(:result, from, state) do
    if state.done do
      {:reply, state.result, state}
    else
      result_waiters = :queue.in(from, state.result_waiters)
      {:noreply, %{state | result_waiters: result_waiters}}
    end
  end

  def handle_call(:stats, _from, state) do
    stats = %{
      queue_size: state.queue_size,
      max_queue: state.max_queue,
      dropped: state.dropped
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:attach_task, task_pid}, state) do
    # Only one task can be attached at a time.
    # Demonitor any previously-attached task to avoid leaking monitors.
    if state.task_ref do
      Process.demonitor(state.task_ref, [:flush])
    end

    task_ref = Process.monitor(task_pid)
    {:noreply, %{state | task_pid: task_pid, task_ref: task_ref}}
  end

  def handle_cast({:push, event}, state) do
    if state.canceled or state.done do
      {:noreply, state}
    else
      # Async push - ignores backpressure
      case handle_push(event, state, log_on_overflow: true) do
        {:ok, new_state} -> {:noreply, new_state}
        {:overflow, new_state} -> {:noreply, new_state}
      end
    end
  end

  def handle_cast({:complete, messages}, state) do
    if state.done or state.canceled do
      {:noreply, state}
    else
      done_event = {:agent_end, messages}

      state = push_terminal(done_event, state)
      state = %{state | result: {:ok, messages}, done: true}

      # Cancel the timeout
      if state.timeout_ref, do: Process.cancel_timer(state.timeout_ref)

      # Wake up any result waiters
      state = notify_result_waiters(state)

      {:noreply, state}
    end
  end

  def handle_cast({:error, reason, partial_state}, state) do
    if state.done or state.canceled do
      {:noreply, state}
    else
      error_event = {:error, reason, partial_state}

      state = push_terminal(error_event, state)
      state = %{state | result: {:error, reason, partial_state}, done: true}

      # Cancel the timeout
      if state.timeout_ref, do: Process.cancel_timer(state.timeout_ref)

      # Wake up any result waiters
      state = notify_result_waiters(state)

      {:noreply, state}
    end
  end

  def handle_cast({:cancel, reason}, state) do
    state = do_cancel(state, reason)
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    # Owner died - cancel the stream
    Logger.debug("AgentCore.EventStream owner died, canceling stream")
    state = do_cancel(state, :owner_down)
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, %{task_pid: pid, task_ref: ref} = state) do
    # Attached task died
    Logger.debug("AgentCore.EventStream task died: #{inspect(reason)}")

    state = %{state | task_pid: nil, task_ref: nil}

    unless state.done or state.canceled do
      # Task crashed before completing - this is an error
      error_event = {:error, {:task_crashed, reason}, nil}

      state = push_terminal(error_event, state)
      state = %{state | result: {:error, {:task_crashed, reason}, nil}, done: true}
      state = notify_result_waiters(state)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Unknown process died - ignore
    {:noreply, state}
  end

  def handle_info(:stream_timeout, state) do
    Logger.debug("AgentCore.EventStream timeout, canceling stream")
    state = do_cancel(state, :timeout)
    {:stop, :normal, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Shutdown attached task if still running
    if state.task_pid && Process.alive?(state.task_pid) do
      Process.exit(state.task_pid, :shutdown)
    end

    if state.task_ref do
      Process.demonitor(state.task_ref, [:flush])
    end

    :ok
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Handle safe take with exit catching
  defp safe_take(stream) do
    GenServer.call(stream, :take, :infinity)
  catch
    :exit, {:noproc, _} -> :canceled
    :exit, {:normal, _} -> :canceled
    :exit, {:shutdown, _} -> :canceled
  end

  defp handle_push(event, state, opts) do
    log_on_overflow = Keyword.get(opts, :log_on_overflow, false)

    if state.queue_size >= state.max_queue do
      handle_overflow(event, state, log_on_overflow)
    else
      state = deliver_or_buffer(event, state)
      {:ok, state}
    end
  end

  defp push_terminal(event, state) do
    case :queue.out(state.take_waiters) do
      {{:value, from}, remaining} ->
        GenServer.reply(from, {:event, event})
        %{state | take_waiters: remaining}

      {:empty, _} ->
        state =
          if state.queue_size >= state.max_queue do
            drop_oldest_event(state)
          else
            state
          end

        deliver_or_buffer(event, state)
    end
  end

  defp drop_oldest_event(state) do
    case :queue.out(state.events) do
      {{:value, _dropped}, remaining} ->
        %{
          state
          | events: remaining,
            queue_size: max(state.queue_size - 1, 0),
            dropped: state.dropped + 1
        }

      {:empty, _} ->
        state
    end
  end

  defp handle_overflow(event, %{drop_strategy: :drop_oldest} = state, _log_on_overflow) do
    # Drop the oldest event and add the new one
    case :queue.out(state.events) do
      {{:value, _dropped}, remaining} ->
        events = :queue.in(event, remaining)
        {:ok, %{state | events: events, dropped: state.dropped + 1}}

      {:empty, _} ->
        # Queue was empty, just add the event
        events = :queue.in(event, state.events)
        {:ok, %{state | events: events, queue_size: state.queue_size + 1}}
    end
  end

  defp handle_overflow(_event, %{drop_strategy: :drop_newest} = state, _log_on_overflow) do
    # Drop the new event
    {:ok, %{state | dropped: state.dropped + 1}}
  end

  defp handle_overflow(_event, %{drop_strategy: :error} = state, log_on_overflow) do
    if log_on_overflow do
      Logger.warning("AgentCore.EventStream dropping event due to queue overflow")
    end

    {:overflow, %{state | dropped: state.dropped + 1}}
  end

  defp deliver_or_buffer(event, state) do
    case :queue.out(state.take_waiters) do
      {{:value, from}, remaining} ->
        GenServer.reply(from, {:event, event})
        %{state | take_waiters: remaining}

      {:empty, _} ->
        events = :queue.in(event, state.events)
        %{state | events: events, queue_size: state.queue_size + 1}
    end
  end

  defp notify_result_waiters(state) do
    Enum.each(:queue.to_list(state.result_waiters), fn from ->
      GenServer.reply(from, state.result)
    end)

    # Also wake up take waiters with :done
    Enum.each(:queue.to_list(state.take_waiters), fn from ->
      GenServer.reply(from, :done)
    end)

    %{state | result_waiters: :queue.new(), take_waiters: :queue.new()}
  end

  defp do_cancel(state, reason) do
    # Cancel the timeout timer
    if state.timeout_ref, do: Process.cancel_timer(state.timeout_ref)

    # Shutdown attached task
    if state.task_pid && Process.alive?(state.task_pid) do
      Process.exit(state.task_pid, :shutdown)
    end

    if state.task_ref do
      Process.demonitor(state.task_ref, [:flush])
    end

    # Push a canceled event if not already done
    cancel_event = {:canceled, reason}

    state =
      if not state.done do
        case handle_push(cancel_event, %{state | max_queue: state.max_queue + 1}, []) do
          {:ok, new_state} -> new_state
          {:overflow, new_state} -> new_state
        end
      else
        state
      end

    # Set canceled state
    state = %{state | canceled: true, cancel_reason: reason, done: true, task_pid: nil, task_ref: nil}

    # If no result set, set a cancel result
    state =
      if state.result == nil do
        %{state | result: {:error, {:canceled, reason}}}
      else
        state
      end

    # Wake up all waiters
    notify_result_waiters(state)
  end

  # Check if an event is terminal (signals end of stream)
  defp terminal?({:agent_end, _messages}), do: true
  defp terminal?({:error, _reason, _partial_state}), do: true
  defp terminal?({:canceled, _reason}), do: true
  defp terminal?(_event), do: false
end
