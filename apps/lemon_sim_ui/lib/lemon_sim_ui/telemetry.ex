defmodule LemonSimUi.Telemetry do
  @moduledoc false

  use GenServer

  @handler_id "lemon-sim-ui-runtime-metrics"
  @events ~w(
    room_created seat_claimed game_started game_completed game_stopped
    phase_completed command_accepted command_rejected turn_timeout
    player_connected player_disconnected persistence_error provider_request ai_error room_failed
  )a
  @recent_limit 50
  @metadata_keys ~w(room_id seat_id source phase next_phase winner error_class status model)a

  def start_link(_arg) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  catch
    :exit, _ -> %{status: "unavailable"}
  end

  @impl true
  def init(_) do
    :telemetry.detach(@handler_id)

    :ok =
      :telemetry.attach_many(
        @handler_id,
        Enum.map(@events, &[:lemon_sim_ui, :hosted_werewolf, &1]),
        &__MODULE__.handle_telemetry_event/4,
        self()
      )

    {:ok,
     %{
       started_at_ms: System.system_time(:millisecond),
       counters: %{},
       durations: %{},
       recent: []
     }}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
    :ok
  end

  def handle_telemetry_event(
        [:lemon_sim_ui, :hosted_werewolf, event],
        measurements,
        metadata,
        pid
      ) do
    GenServer.cast(pid, {:metric, event, measurements, metadata})
  end

  @impl true
  def handle_cast({:metric, event, measurements, metadata}, state) do
    count = numeric_measurement(measurements, :count, 1)
    counters = Map.update(state.counters, event, count, &(&1 + count))

    durations =
      case numeric_measurement(measurements, :duration_ms, nil) do
        duration when is_number(duration) ->
          Map.update(
            state.durations,
            event,
            %{count: 1, total_ms: duration, max_ms: duration},
            fn current ->
              %{
                count: current.count + 1,
                total_ms: current.total_ms + duration,
                max_ms: max(current.max_ms, duration)
              }
            end
          )

        _ ->
          state.durations
      end

    recent_entry = %{
      event: event,
      at_ms: System.system_time(:millisecond),
      metadata: Map.take(metadata, @metadata_keys)
    }

    {:noreply,
     %{
       state
       | counters: counters,
         durations: durations,
         recent: Enum.take([recent_entry | state.recent], @recent_limit)
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    durations =
      Map.new(state.durations, fn {event, values} ->
        {event,
         Map.put(values, :average_ms, Float.round(values.total_ms / max(values.count, 1), 2))}
      end)

    {:reply,
     %{
       status: "ok",
       started_at_ms: state.started_at_ms,
       counters: state.counters,
       durations: durations,
       recent: state.recent
     }, state}
  end

  defp numeric_measurement(measurements, key, default) do
    case Map.get(measurements, key, default) do
      value when is_number(value) -> value
      _ -> default
    end
  end
end
