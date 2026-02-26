defmodule LemonRouter.RunCountTracker do
  @moduledoc """
  Tracks run lifecycle counters via telemetry for the `RunOrchestrator.counts/0` API.

  Attaches to:
  - `[:lemon, :run, :submit]` — increments `queued` on submission
  - `[:lemon, :run, :start]`  — decrements `queued`, no-ops for `active` (DynamicSupervisor owns that)
  - `[:lemon, :run, :stop]`   — increments `completed_today`

  A midnight reset timer clears `completed_today` at the start of each UTC day.
  """

  use GenServer
  require Logger

  # Counter indices inside :counters ref
  @idx_queued 1
  @idx_completed_today 2

  # ── Client API ──────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the current queued count (submissions that have not yet started).
  """
  @spec queued() :: non_neg_integer()
  def queued do
    ref = counter_ref()
    max(:counters.get(ref, @idx_queued), 0)
  end

  @doc """
  Returns the number of runs completed since the last midnight UTC reset.
  """
  @spec completed_today() :: non_neg_integer()
  def completed_today do
    ref = counter_ref()
    max(:counters.get(ref, @idx_completed_today), 0)
  end

  # ── Server callbacks ────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    ref = :counters.new(2, [:write_concurrency])
    :persistent_term.put({__MODULE__, :counters}, ref)

    attach_telemetry()
    schedule_midnight_reset()

    {:ok, %{counter_ref: ref}}
  end

  @impl true
  def handle_info(:midnight_reset, state) do
    :counters.put(state.counter_ref, @idx_completed_today, 0)
    :counters.put(state.counter_ref, @idx_queued, 0)
    schedule_midnight_reset()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach("lemon_router.run_count_tracker.submit")
    :telemetry.detach("lemon_router.run_count_tracker.start")
    :telemetry.detach("lemon_router.run_count_tracker.stop")
    :ok
  end

  # ── Telemetry handlers (module function refs — required by :telemetry) ──

  @doc false
  def handle_submit(_event, _measurements, _metadata, _config) do
    :counters.add(counter_ref(), @idx_queued, 1)
  end

  @doc false
  def handle_start(_event, _measurements, _metadata, _config) do
    ref = counter_ref()
    # Decrement queued; floor at 0 to avoid negative drift.
    :counters.sub(ref, @idx_queued, 1)
  end

  @doc false
  def handle_stop(_event, _measurements, _metadata, _config) do
    :counters.add(counter_ref(), @idx_completed_today, 1)
  end

  # ── Internal helpers ────────────────────────────────────────────────────

  defp counter_ref do
    :persistent_term.get({__MODULE__, :counters})
  end

  defp attach_telemetry do
    :telemetry.attach(
      "lemon_router.run_count_tracker.submit",
      [:lemon, :run, :submit],
      &__MODULE__.handle_submit/4,
      nil
    )

    :telemetry.attach(
      "lemon_router.run_count_tracker.start",
      [:lemon, :run, :start],
      &__MODULE__.handle_start/4,
      nil
    )

    :telemetry.attach(
      "lemon_router.run_count_tracker.stop",
      [:lemon, :run, :stop],
      &__MODULE__.handle_stop/4,
      nil
    )
  end

  defp schedule_midnight_reset do
    ms_until_midnight = ms_until_next_utc_midnight()
    Process.send_after(self(), :midnight_reset, ms_until_midnight)
  end

  @doc false
  def ms_until_next_utc_midnight do
    now = DateTime.utc_now()

    midnight =
      now
      |> DateTime.to_date()
      |> Date.add(1)
      |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    DateTime.diff(midnight, now, :millisecond)
  end
end
