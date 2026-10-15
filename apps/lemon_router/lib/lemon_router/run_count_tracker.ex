defmodule LemonRouter.RunCountTracker do
  @moduledoc """
  Tracks terminal runs since midnight UTC, seeded from durable introspection
  `run_completed` and `run_failed` events, not provider usage requests.

  Run IDs deduplicate telemetry and durable terminal events. `completed_today`
  includes all terminal runs; `failed_today` is the subset that failed.
  Queued submissions are read from authoritative live session coordinators.
  """
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def queued, do: LemonRouter.SessionCoordinator.pending_count()
  def completed_today, do: GenServer.call(__MODULE__, :completed_today, 100)
  def failed_today, do: GenServer.call(__MODULE__, :failed_today, 100)

  @doc false
  def record_terminal(run_id, failed?) do
    GenServer.cast(__MODULE__, {:terminal, run_id, failed?})
  end

  @impl true
  def init(_opts) do
    :telemetry.attach(
      "lemon_router.run_count_tracker.stop",
      [:lemon, :run, :stop],
      &__MODULE__.handle_stop/4,
      nil
    )

    schedule_midnight_reset()
    {:ok, seed()}
  end

  @impl true
  def handle_call(field, _from, state) when field in [:completed_today, :failed_today] do
    value =
      if state.available? do
        if field == :completed_today,
          do: map_size(state.runs),
          else: Enum.count(state.runs, fn {_id, failed?} -> failed? end)
      end

    {:reply, value, state}
  end

  @impl true
  def handle_cast({:terminal, run_id, failed?}, state) do
    {:noreply, put_terminal(state, run_id, failed?)}
  end

  @impl true
  def handle_info(:midnight_reset, _state) do
    schedule_midnight_reset()
    {:noreply, seed()}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach("lemon_router.run_count_tracker.stop")
    :ok
  end

  @doc false
  # A raising telemetry handler is detached permanently, so never pattern-match
  # on metadata; a missing run ID still counts once under a unique key.
  def handle_stop(_event, measurements, metadata, _config) do
    run_id = Map.get(metadata, :run_id) || make_ref()
    record_terminal(run_id, Map.get(measurements, :ok) == false)
  end

  defp seed do
    midnight = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")

    case LemonCore.IntrospectionStore.terminal_events_since(
           DateTime.to_unix(midnight, :millisecond)
         ) do
      {:ok, events} ->
        Enum.reduce(
          events,
          %{runs: %{}, available?: LemonCore.Introspection.enabled?()},
          fn event, state ->
            failed? =
              event.event_type in [:run_failed, "run_failed"] or
                Map.get(event.payload, :ok, Map.get(event.payload, "ok")) == false

            put_terminal(state, event.run_id || event.event_id, failed?)
          end
        )

      {:error, _} ->
        %{runs: %{}, available?: false}
    end
  end

  defp put_terminal(state, run_id, failed?) do
    %{state | runs: Map.update(state.runs, run_id, failed?, &(&1 or failed?))}
  end

  defp schedule_midnight_reset do
    Process.send_after(self(), :midnight_reset, ms_until_next_utc_midnight())
  end

  @doc false
  def ms_until_next_utc_midnight do
    now = DateTime.utc_now()
    midnight = now |> DateTime.to_date() |> Date.add(1) |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    DateTime.diff(midnight, now, :millisecond)
  end
end
