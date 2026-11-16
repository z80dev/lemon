defmodule LemonAutomation.IntervalRunner do
  @moduledoc false

  use GenServer

  alias LemonAutomation.RunnerConfig

  require Logger

  @default_tick_interval_ms 60_000
  @task_supervisor LemonAutomation.TaskSupervisor

  def start_link(name, runner, opts, scheduler_opts \\ []) do
    GenServer.start_link(__MODULE__, {runner, opts, scheduler_opts}, name: name)
  end

  @impl true
  def init({runner, opts, scheduler_opts}) do
    schedule_tick(opts)

    {:ok,
     %{
       runner: runner,
       opts: opts,
       track_idle: Keyword.get(scheduler_opts, :track_idle, false),
       last_busy_at_ms: LemonCore.Clock.now_ms(),
       in_flight_ref: nil
     }}
  end

  @impl true
  def handle_cast(:tick, state), do: {:noreply, do_tick(state)}

  @impl true
  def handle_info(:tick, state) do
    state = do_tick(state)
    schedule_tick(state.opts)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{in_flight_ref: ref} = state) do
    {:noreply, %{state | in_flight_ref: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp do_tick(%{in_flight_ref: ref} = state) when not is_nil(ref), do: state

  defp do_tick(state) do
    if RunnerConfig.active_sessions?(state.opts) do
      %{state | last_busy_at_ms: LemonCore.Clock.now_ms()}
    else
      opts = run_opts(state)
      runner = state.runner

      if runner.should_run_now?(opts) do
        case start_background_task(fn -> runner.run_once(opts) end) do
          {:ok, pid} ->
            %{state | in_flight_ref: Process.monitor(pid)}

          {:error, reason} ->
            Logger.warning(
              "[#{inspect(runner)}] Failed to start supervised task: #{inspect(reason)}"
            )

            state
        end
      else
        state
      end
    end
  end

  defp run_opts(%{track_idle: true} = state) do
    idle_seconds = RunnerConfig.idle_for_seconds(last_busy_at_ms: state.last_busy_at_ms)
    Keyword.put(state.opts, :idle_for_seconds, idle_seconds)
  end

  defp run_opts(state), do: state.opts

  defp start_background_task(fun) do
    LemonCore.TaskSupervisor.start_child(@task_supervisor, fun)
  end

  defp schedule_tick(opts) do
    interval = Keyword.get(opts, :tick_interval_ms, @default_tick_interval_ms)
    Process.send_after(self(), :tick, interval)
  end
end
