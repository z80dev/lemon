defmodule LemonAutomation.SynthesisRunnerManager do
  @moduledoc """
  Interval scheduler for `LemonAutomation.SynthesisRunner`.

  Ticks once a minute, defers while the router reports active sessions, and
  spawns at most one synthesis pass at a time. Interval gating itself lives in
  the runner's durable state (`:synthesis_runner_state`), so a restart does not
  reset the clock and re-run early.
  """

  use GenServer

  alias LemonAutomation.SynthesisRunner

  require Logger

  @default_tick_interval_ms 60_000
  @task_supervisor LemonAutomation.TaskSupervisor

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Force one scheduler tick.
  """
  @spec tick() :: :ok
  def tick do
    GenServer.cast(__MODULE__, :tick)
  end

  @impl true
  def init(opts) do
    schedule_tick(opts)

    {:ok,
     %{
       opts: opts,
       in_flight_ref: nil
     }}
  end

  @impl true
  def handle_cast(:tick, state) do
    {:noreply, do_tick(state)}
  end

  @impl true
  def handle_info(:tick, state) do
    state = do_tick(state)
    schedule_tick(state.opts)
    {:noreply, state}
  end

  @impl true
  def handle_info({_ref, _result}, state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{in_flight_ref: ref} = state) do
    {:noreply, %{state | in_flight_ref: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp do_tick(%{in_flight_ref: ref} = state) when not is_nil(ref), do: state

  defp do_tick(state) do
    cond do
      SynthesisRunner.active_sessions?(state.opts) ->
        state

      SynthesisRunner.should_run_now?(state.opts) ->
        case start_background_task(fn -> SynthesisRunner.run_once(state.opts) end) do
          {:ok, {_pid, ref}} -> %{state | in_flight_ref: ref}
          _ -> state
        end

      true ->
        state
    end
  end

  defp start_background_task(fun) when is_function(fun, 0) do
    case Task.Supervisor.start_child(@task_supervisor, fun) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        {:ok, {pid, ref}}

      {:error, {:noproc, _}} ->
        start_unlinked_task(fun)

      {:error, :noproc} ->
        start_unlinked_task(fun)

      {:error, reason} ->
        Logger.warning(
          "[SynthesisRunnerManager] Failed to start supervised task: #{inspect(reason)}"
        )

        :error
    end
  end

  defp start_unlinked_task(fun) do
    case Task.start(fun) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        {:ok, {pid, ref}}

      {:error, reason} ->
        Logger.warning("[SynthesisRunnerManager] Failed to start task: #{inspect(reason)}")
        :error
    end
  end

  defp schedule_tick(opts) do
    interval = Keyword.get(opts, :tick_interval_ms, @default_tick_interval_ms)
    Process.send_after(self(), :tick, interval)
  end
end
