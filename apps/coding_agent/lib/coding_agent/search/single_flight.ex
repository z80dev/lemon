defmodule CodingAgent.Search.SingleFlight do
  @moduledoc """
  Coalesces concurrent identical search/extraction work.

  The first caller runs the operation under a supervised task. Later callers
  for the same key wait for and receive the same result, preventing request
  bursts from multiplying provider cost or rate-limit pressure.
  """

  use GenServer

  @default_timeout_ms 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec run(term(), (-> term()), pos_integer(), GenServer.server()) :: term()
  def run(key, fun, timeout_ms \\ @default_timeout_ms, server \\ __MODULE__)
      when is_function(fun, 0) and is_integer(timeout_ms) and timeout_ms > 0 do
    GenServer.call(server, {:run, key, fun, timeout_ms}, timeout_ms + 2_000)
  end

  @impl true
  def init(_opts), do: {:ok, %{by_key: %{}, by_ref: %{}}}

  @impl true
  def handle_call({:run, key, _fun, _timeout_ms}, from, %{by_key: by_key} = state)
      when is_map_key(by_key, key) do
    flight = Map.fetch!(by_key, key)
    updated = %{flight | callers: [from | flight.callers]}
    {:noreply, put_in(state.by_key[key], updated)}
  end

  def handle_call({:run, key, fun, timeout_ms}, from, state) do
    task =
      Task.Supervisor.async_nolink(CodingAgent.Search.TaskSupervisor, fn -> safe_run(fun) end)

    timer = Process.send_after(self(), {:flight_timeout, task.ref}, timeout_ms)
    flight = %{key: key, task: task, timer: timer, callers: [from]}

    {:noreply,
     state
     |> put_in([:by_key, key], flight)
     |> put_in([:by_ref, task.ref], key)}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    finish(ref, result, state)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    finish(ref, {:error, {:single_flight_crash, reason}}, state)
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

  defp finish(ref, result, state) do
    case lookup_flight(ref, state) do
      {:ok, flight} ->
        Process.cancel_timer(flight.timer)
        Enum.each(flight.callers, &GenServer.reply(&1, result))

        {:noreply,
         %{
           state
           | by_key: Map.delete(state.by_key, flight.key),
             by_ref: Map.delete(state.by_ref, ref)
         }}

      :error ->
        {:noreply, state}
    end
  end

  defp lookup_flight(ref, state) do
    with {:ok, key} <- Map.fetch(state.by_ref, ref),
         {:ok, flight} <- Map.fetch(state.by_key, key) do
      {:ok, flight}
    else
      :error -> :error
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
