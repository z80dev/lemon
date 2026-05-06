defmodule LemonAutomation.SkillCuratorManager do
  @moduledoc """
  Idle-triggered scheduler for the learned-skill curator.
  """

  use GenServer

  alias LemonAutomation.SkillCurator

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
    now_ms = LemonCore.Clock.now_ms()
    schedule_tick(opts)

    {:ok,
     %{
       opts: opts,
       last_busy_at_ms: now_ms,
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
    now_ms = LemonCore.Clock.now_ms()

    if SkillCurator.active_sessions?(state.opts) do
      %{state | last_busy_at_ms: now_ms}
    else
      idle_seconds =
        SkillCurator.idle_for_seconds(
          now_ms: now_ms,
          last_busy_at_ms: state.last_busy_at_ms
        )

      opts = Keyword.merge(state.opts, idle_for_seconds: idle_seconds)

      if SkillCurator.should_run_now?(opts) do
        case start_background_task(fn -> SkillCurator.run_once(opts) end) do
          {:ok, {_pid, ref}} -> %{state | in_flight_ref: ref}
          _ -> state
        end
      else
        state
      end
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
          "[SkillCuratorManager] Failed to start supervised task: #{inspect(reason)}"
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
        Logger.warning("[SkillCuratorManager] Failed to start task: #{inspect(reason)}")
        :error
    end
  end

  defp schedule_tick(opts) do
    interval = Keyword.get(opts, :tick_interval_ms, @default_tick_interval_ms)
    Process.send_after(self(), :tick, interval)
  end
end
