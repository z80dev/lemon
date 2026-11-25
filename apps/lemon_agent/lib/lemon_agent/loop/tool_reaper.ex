defmodule LemonAgent.Loop.ToolReaper do
  @moduledoc false

  # Owns the tool tasks of one tool batch on behalf of the loop process.
  #
  # Tools run unlinked under the tool task supervisor so a tool crash becomes a
  # tool error instead of a loop crash. The reaper ties their lifetime to the
  # loop instead: it starts each task (so a task is tracked before the loop can
  # die holding its pid), owns the per-tool deadlines, and when the loop exits
  # for any reason, including `:kill` from its owner, it aborts the run signal,
  # gives cooperative tools a short grace period and terminates the rest.

  alias LemonAgent.AbortSignal

  @abort_grace_ms 250

  @doc "Start the reaper for a batch run by `loop` under `signal`."
  @spec start(pid(), reference() | nil, Supervisor.supervisor()) ::
          {:ok, pid()} | {:error, term()}
  def start(loop, signal, tool_task_supervisor) do
    LemonCore.TaskSupervisor.start_child(LemonAgent.LoopTaskSupervisor, fn ->
      run(loop, signal, tool_task_supervisor)
    end)
  end

  @doc """
  Start a tool task tracked by `reaper`.

  When `timeout_ms` elapses first, the reaper sends `{:tool_task_timeout, ref}`
  to the loop and then terminates the task.
  """
  @spec start_tool(pid(), reference(), (-> term()), pos_integer() | nil) ::
          {:ok, pid()} | {:error, term()}
  def start_tool(reaper, ref, fun, timeout_ms) do
    tag = Process.monitor(reaper)
    send(reaper, {:start_tool, self(), tag, ref, fun, timeout_ms})

    receive do
      {^tag, reply} ->
        Process.demonitor(tag, [:flush])
        reply

      {:DOWN, ^tag, :process, _pid, _reason} ->
        {:error, {:task_start_outcome_unknown, :tool_reaper_down}}
    end
  end

  @doc "End the batch: terminate any task still tracked and exit."
  @spec stop(pid()) :: :ok
  def stop(reaper) do
    send(reaper, {:stop, self()})
    :ok
  end

  defp run(loop, signal, supervisor) do
    state = %{
      loop: loop,
      loop_mon: Process.monitor(loop),
      signal: signal,
      supervisor: supervisor,
      tasks: %{}
    }

    loop(state)
  end

  defp loop(%{loop: loop_pid, loop_mon: loop_mon} = state) do
    receive do
      {:start_tool, ^loop_pid, tag, ref, fun, timeout_ms} ->
        {reply, state} = start_task(state, ref, fun, timeout_ms)
        send(loop_pid, {tag, reply})
        loop(state)

      {:DOWN, ^loop_mon, :process, _pid, _reason} ->
        if state.signal, do: AbortSignal.abort(state.signal)
        state |> await_exits(System.monotonic_time(:millisecond) + @abort_grace_ms) |> terminate()

      {:DOWN, mon, :process, _pid, _reason} when is_map_key(state.tasks, mon) ->
        {task, tasks} = Map.pop!(state.tasks, mon)
        _ = cancel_deadline(task.timer)
        loop(%{state | tasks: tasks})

      {:deadline, mon} when is_map_key(state.tasks, mon) ->
        task = Map.fetch!(state.tasks, mon)
        # The loop observes the timeout before the task's DOWN.
        send(loop_pid, {:tool_task_timeout, task.ref})
        _ = Task.Supervisor.terminate_child(state.supervisor, task.pid)
        loop(%{state | tasks: Map.put(state.tasks, mon, %{task | timer: nil})})

      {:stop, ^loop_pid} ->
        terminate(state)

      _stale ->
        loop(state)
    end
  end

  defp start_task(state, ref, fun, timeout_ms) do
    case start_child(state.supervisor, fun) do
      {:ok, pid} ->
        mon = Process.monitor(pid)
        timer = if timeout_ms, do: Process.send_after(self(), {:deadline, mon}, timeout_ms)
        task = %{ref: ref, pid: pid, timer: timer}
        {{:ok, pid}, %{state | tasks: Map.put(state.tasks, mon, task)}}

      {:error, _reason} = error ->
        {error, state}
    end
  end

  defp start_child(supervisor, fun) do
    LemonCore.TaskSupervisor.start_child(supervisor, fun)
  catch
    :exit, reason -> {:error, {:task_start_outcome_unknown, reason}}
  end

  defp await_exits(%{tasks: tasks} = state, _deadline) when map_size(tasks) == 0, do: state

  defp await_exits(state, deadline) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:DOWN, mon, :process, _pid, _reason} when is_map_key(state.tasks, mon) ->
        {task, tasks} = Map.pop!(state.tasks, mon)
        _ = cancel_deadline(task.timer)
        await_exits(%{state | tasks: tasks}, deadline)
    after
      remaining_ms -> state
    end
  end

  defp terminate(state) do
    Enum.each(state.tasks, fn {mon, task} ->
      _ = cancel_deadline(task.timer)
      _ = Task.Supervisor.terminate_child(state.supervisor, task.pid)
      Process.demonitor(mon, [:flush])
    end)

    :ok
  end

  defp cancel_deadline(nil), do: :ok
  defp cancel_deadline(timer), do: Process.cancel_timer(timer, async: true, info: false)
end
