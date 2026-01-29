defmodule AgentCore.EventStream do
  @moduledoc """
  Async event stream for streaming Agent responses.

  This module provides a producer/consumer pattern for streaming events
  from agent execution. Events are buffered and can be consumed using
  Elixir's Stream or Enum modules.

  ## Usage

      # Start a stream
      {:ok, stream} = EventStream.start_link()

      # Producer pushes events
      EventStream.push(stream, {:agent_start, %{}})
      EventStream.push(stream, {:tool_call, tool_call})
      EventStream.push(stream, {:tool_result, result})
      EventStream.complete(stream, messages)

      # Consumer reads events
      stream
      |> EventStream.events()
      |> Enum.each(fn event -> IO.inspect(event) end)

      # Or get the final result
      {:ok, messages} = EventStream.result(stream)

  ## Terminal Events

  The stream terminates when one of these events is received:
  - `{:agent_end, messages}` - Successful completion with final message list
  - `{:error, reason, partial_state}` - Error with reason and any partial state
  """

  use GenServer

  # ============================================================================
  # Event Types
  # ============================================================================

  @typedoc """
  Agent events that can be pushed to the stream.

  Terminal events:
  - `{:agent_end, messages}` - Successful completion
  - `{:error, reason, partial_state}` - Error state

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
          | term()

  @type t :: pid()

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Start a new event stream.

  ## Options

  Currently accepts no options but the keyword list is reserved for future use.

  ## Examples

      {:ok, stream} = AgentCore.EventStream.start_link()
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Push an event to the stream.

  Events are buffered until consumed. If a consumer is waiting,
  the event is delivered immediately.

  ## Examples

      :ok = EventStream.push(stream, {:tool_call, %{name: "read_file"}})
  """
  @spec push(t(), event()) :: :ok
  def push(stream, event) do
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
  Get a lazy enumerable of events from the stream.

  This returns a Stream that will block when no events are available
  and complete when a terminal event is received. Terminal events
  (`{:agent_end, _}` or `{:error, _, _}`) are included in the stream
  before it halts.

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
          case GenServer.call(stream, :take, :infinity) do
            {:event, event} ->
              if terminal?(event) do
                # Yield the terminal event, then halt on next iteration
                {[event], {:halting, stream}}
              else
                {[event], {:active, stream}}
              end

            :done ->
              {:halt, nil}
          end
      end,
      fn _acc -> :ok end
    )
  end

  @doc """
  Get the final result of the stream, blocking until complete.

  Returns `{:ok, messages}` on successful completion or
  `{:error, reason, partial_state}` on error.

  ## Options

  - `timeout` - How long to wait for completion (default: `:infinity`)

  ## Examples

      {:ok, messages} = EventStream.result(stream)
      {:ok, messages} = EventStream.result(stream, 5000)
  """
  @spec result(t(), timeout()) :: {:ok, list()} | {:error, term(), term()}
  def result(stream, timeout \\ :infinity) do
    GenServer.call(stream, :result, timeout)
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    state = %{
      events: :queue.new(),
      take_waiters: :queue.new(),
      result_waiters: :queue.new(),
      result: nil,
      done: false
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:push, event}, state) do
    state = deliver_or_buffer(event, state)
    {:noreply, state}
  end

  def handle_cast({:complete, messages}, state) do
    done_event = {:agent_end, messages}
    state = deliver_or_buffer(done_event, state)

    state = %{state | result: {:ok, messages}, done: true}

    # Wake up any result waiters
    state = notify_result_waiters(state)

    {:noreply, state}
  end

  def handle_cast({:error, reason, partial_state}, state) do
    error_event = {:error, reason, partial_state}
    state = deliver_or_buffer(error_event, state)

    state = %{state | result: {:error, reason, partial_state}, done: true}

    # Wake up any result waiters
    state = notify_result_waiters(state)

    {:noreply, state}
  end

  @impl true
  def handle_call(:take, from, state) do
    case :queue.out(state.events) do
      {{:value, event}, remaining} ->
        {:reply, {:event, event}, %{state | events: remaining}}

      {:empty, _} ->
        if state.done do
          {:reply, :done, state}
        else
          # Add to take waiters queue
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

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Check if an event is terminal (signals end of stream)
  defp terminal?({:agent_end, _messages}), do: true
  defp terminal?({:error, _reason, _partial_state}), do: true
  defp terminal?(_event), do: false

  defp deliver_or_buffer(event, state) do
    case :queue.out(state.take_waiters) do
      {{:value, from}, remaining} ->
        GenServer.reply(from, {:event, event})
        %{state | take_waiters: remaining}

      {:empty, _} ->
        events = :queue.in(event, state.events)
        %{state | events: events}
    end
  end

  defp notify_result_waiters(state) do
    Enum.each(:queue.to_list(state.result_waiters), fn from ->
      GenServer.reply(from, state.result)
    end)

    state = %{state | result_waiters: :queue.new()}

    flush_take_waiters(state)
  end

  defp flush_take_waiters(state) do
    {events, take_waiters} = deliver_buffered_events(state.events, state.take_waiters)

    # Wake remaining take waiters if no more events will arrive
    Enum.each(:queue.to_list(take_waiters), fn from ->
      GenServer.reply(from, :done)
    end)

    %{state | events: events, take_waiters: :queue.new()}
  end

  defp deliver_buffered_events(events, take_waiters) do
    case {:queue.out(events), :queue.out(take_waiters)} do
      {{{:value, event}, remaining_events}, {{:value, from}, remaining_waiters}} ->
        GenServer.reply(from, {:event, event})
        deliver_buffered_events(remaining_events, remaining_waiters)

      _ ->
        {events, take_waiters}
    end
  end
end
