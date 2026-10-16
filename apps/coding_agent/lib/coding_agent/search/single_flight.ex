defmodule CodingAgent.Search.SingleFlight do
  @moduledoc """
  Coalesces concurrent identical search/extraction work.

  The first caller runs the operation under a supervised task. Later callers
  for the same key wait for and receive the same result, preventing request
  bursts from multiplying provider cost or rate-limit pressure.

  A caller that passes an abort `:signal` is released with
  `{:error, "Operation aborted"}` once that signal is aborted; the other
  callers keep waiting for the shared result. An already-aborted caller never
  starts or joins work. When every caller of a flight has been released this
  way, the flight is detached from its key (later callers start a fresh flight)
  and the flight's own abort signal, which a one-argument operation receives,
  is aborted so cooperative work stops.
  """

  use GenServer

  import LemonAgent.Tools.AbortHelpers, only: [aborted?: 1]

  alias LemonAgent.AbortSignal

  @default_timeout_ms 30_000
  @abort_poll_ms 50

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Runs `fun` once per concurrent `key`. Options: `:signal` (the caller's abort
  signal) and `:server`.
  """
  @spec run(term(), (-> term()) | (reference() -> term()), pos_integer(), keyword()) :: term()
  def run(key, fun, timeout_ms \\ @default_timeout_ms, opts \\ [])
      when (is_function(fun, 0) or is_function(fun, 1)) and is_integer(timeout_ms) and
             timeout_ms > 0 do
    GenServer.call(
      Keyword.get(opts, :server, __MODULE__),
      {:run, key, fun, timeout_ms, Keyword.get(opts, :signal)},
      timeout_ms + 2_000
    )
  end

  @doc """
  Refreshes caller cancellation before admitting another provider operation.
  Authorization is the operation's admission point; later cancellation is
  propagated through the flight signal.
  """
  def authorize(signal, opts \\ []) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), {:authorize, signal})
  end

  @doc """
  Publishes a result only while the flight still has live callers.

  Authorization inside the server is the publication linearization point.
  Persistence then runs in a supervised task, never in the shared server.
  Cancellation after authorization releases callers but cannot abandon the
  publishing flight. Its original deadline still applies: on timeout both tasks
  are stopped and callers receive `{:error, :single_flight_timeout}`. A write
  already completed before timeout is not rolled back.
  """
  def commit(signal, fun, opts \\ []) when is_function(fun, 0) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), {:commit, signal, fun}, :infinity)
  end

  @impl true
  def init(_opts), do: {:ok, %{by_key: %{}, by_ref: %{}, abandoned: %{}, abort_timer: nil}}

  @impl true
  def handle_call({:run, key, fun, timeout_ms, signal}, from, state) do
    # Admission must observe cancellation too: the poll may not have detached
    # a flight whose last caller aborted before this new request arrived.
    state =
      case Map.fetch(state.by_key, key) do
        {:ok, flight} -> release_aborted_callers(state, key, flight)
        :error -> state
      end

    cond do
      aborted?(signal) ->
        {:reply, {:error, "Operation aborted"}, state}

      Map.has_key?(state.by_key, key) ->
        caller = %{from: from, signal: signal}

        {:noreply,
         state
         |> update_in([:by_key, key, :callers], &[caller | &1])
         |> schedule_abort_check()}

      true ->
        start_flight(key, fun, timeout_ms, signal, from, state)
    end
  end

  def handle_call({:authorize, signal}, _from, state) do
    case authorize_flight(signal, state) do
      {:ok, _key, _flight, state} -> {:reply, :ok, state}
      {:error, state} -> {:reply, {:error, "Operation aborted"}, state}
    end
  end

  def handle_call({:commit, signal, fun}, from, state) do
    case authorize_flight(signal, state) do
      {:ok, key, flight, state} ->
        publication =
          Task.Supervisor.async_nolink(CodingAgent.Search.TaskSupervisor, fn ->
            safe_run(fun)
          end)

        flight = %{flight | status: :committing, publication: {publication, from}}
        {:noreply, put_in(state, [:by_key, key], flight)}

      {:error, state} ->
        {:reply, {:error, "Operation aborted"}, state}
    end
  end

  defp authorize_flight(signal, state) do
    case Enum.find(state.by_key, fn {_key, flight} -> flight.signal == signal end) do
      {key, flight} ->
        state = release_aborted_callers(state, key, flight)

        case Map.fetch(state.by_key, key) do
          {:ok, %{status: :running} = flight} -> {:ok, key, flight, state}
          _ -> {:error, state}
        end

      nil ->
        {:error, state}
    end
  end

  defp start_flight(key, fun, timeout_ms, signal, from, state) do
    flight_signal = AbortSignal.new()
    operation = if is_function(fun, 1), do: fn -> fun.(flight_signal) end, else: fun

    task =
      Task.Supervisor.async_nolink(CodingAgent.Search.TaskSupervisor, fn ->
        safe_run(operation)
      end)

    timer = Process.send_after(self(), {:flight_timeout, task.ref}, timeout_ms)

    flight = %{
      key: key,
      task: task,
      timer: timer,
      signal: flight_signal,
      status: :running,
      publication: nil,
      callers: [%{from: from, signal: signal}]
    }

    {:noreply,
     state
     |> put_in([:by_key, key], flight)
     |> put_in([:by_ref, task.ref], key)
     |> schedule_abort_check()}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    finish_publication_or_flight(ref, result, state)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    finish_publication_or_flight(ref, {:error, {:single_flight_crash, reason}}, state)
  end

  def handle_info({:flight_timeout, ref}, state) do
    case lookup_flight(ref, state) do
      {:ok, flight} ->
        Task.Supervisor.terminate_child(CodingAgent.Search.TaskSupervisor, flight.task.pid)
        finish(ref, {:error, :single_flight_timeout}, state)

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(:check_aborts, state) do
    state =
      Enum.reduce(state.by_key, %{state | abort_timer: nil}, fn {key, flight}, acc ->
        release_aborted_callers(acc, key, flight)
      end)

    {:noreply, schedule_abort_check(state)}
  end

  defp release_aborted_callers(state, key, flight) do
    {aborted, waiting} = Enum.split_with(flight.callers, &aborted?(&1.signal))
    abandon? = aborted != [] and waiting == [] and flight.status == :running
    if abandon?, do: AbortSignal.abort(flight.signal)
    Enum.each(aborted, &GenServer.reply(&1.from, {:error, "Operation aborted"}))

    cond do
      aborted == [] ->
        state

      abandon? ->
        %{
          state
          | by_key: Map.delete(state.by_key, key),
            by_ref: Map.delete(state.by_ref, flight.task.ref),
            abandoned: Map.put(state.abandoned, flight.task.ref, %{flight | callers: []})
        }

      true ->
        put_in(state, [:by_key, key, :callers], waiting)
    end
  end

  defp schedule_abort_check(%{abort_timer: nil} = state) do
    watched? =
      Enum.any?(state.by_key, fn {_key, flight} ->
        Enum.any?(flight.callers, &(&1.signal != nil))
      end)

    if watched?,
      do: %{state | abort_timer: Process.send_after(self(), :check_aborts, @abort_poll_ms)},
      else: state
  end

  defp schedule_abort_check(state), do: state

  defp finish_publication_or_flight(ref, result, state) do
    case Enum.find(state.by_key, fn {_key, flight} ->
           match?({%Task{ref: ^ref}, _from}, flight.publication)
         end) do
      {key, flight} ->
        {_task, from} = flight.publication
        Process.demonitor(ref, [:flush])
        GenServer.reply(from, result)
        flight = %{flight | status: :committed, publication: nil}
        {:noreply, put_in(state, [:by_key, key], flight)}

      nil ->
        finish(ref, result, state)
    end
  end

  defp stop_publication(%{publication: nil}), do: :ok

  defp stop_publication(%{publication: {task, from}}) do
    Task.Supervisor.terminate_child(CodingAgent.Search.TaskSupervisor, task.pid)
    Process.demonitor(task.ref, [:flush])
    GenServer.reply(from, {:error, :single_flight_timeout})
  end

  defp finish(ref, result, state) do
    case take_flight(ref, state) do
      {:ok, flight, state} ->
        stop_publication(flight)
        Process.demonitor(ref, [:flush])
        Process.cancel_timer(flight.timer)
        AbortSignal.clear(flight.signal)

        Enum.each(flight.callers, fn caller ->
          reply = if aborted?(caller.signal), do: {:error, "Operation aborted"}, else: result
          GenServer.reply(caller.from, reply)
        end)

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  defp lookup_flight(ref, state) do
    case Map.fetch(state.abandoned, ref) do
      {:ok, flight} ->
        {:ok, flight}

      :error ->
        with {:ok, key} <- Map.fetch(state.by_ref, ref) do
          Map.fetch(state.by_key, key)
        end
    end
  end

  # An abandoned flight no longer owns its key, which may now belong to a fresh
  # flight; only the flight's own entries are removed.
  defp take_flight(ref, state) do
    case Map.pop(state.abandoned, ref) do
      {%{} = flight, abandoned} ->
        {:ok, flight, %{state | abandoned: abandoned}}

      {nil, _abandoned} ->
        with {:ok, key} <- Map.fetch(state.by_ref, ref),
             {:ok, flight} <- Map.fetch(state.by_key, key) do
          {:ok, flight,
           %{state | by_key: Map.delete(state.by_key, key), by_ref: Map.delete(state.by_ref, ref)}}
        end
    end
  end

  defp safe_run(fun) do
    fun.()
  rescue
    error -> {:error, {:single_flight_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:single_flight_throw, kind, reason}}
  end
end
