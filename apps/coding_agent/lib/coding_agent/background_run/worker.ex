defmodule CodingAgent.BackgroundRun.Worker do
  @moduledoc false

  use GenServer

  alias CodingAgent.BackgroundRun.Registry
  alias CodingAgent.{LaneQueue, Session, SessionRegistry, TaskStore}
  alias CodingAgent.Tools.Task.{Result, Runner}
  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.AgentToolResult

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Registry.via(Keyword.fetch!(opts, :id)))
  end

  @spec cancel(GenServer.server(), term()) :: :ok
  def cancel(worker, reason), do: GenServer.call(worker, {:cancel, reason}, 5_000)

  @impl true
  def init(opts) do
    signal = AbortSignal.new()

    state = %{
      id: Keyword.fetch!(opts, :id),
      prompt: Keyword.fetch!(opts, :prompt),
      session_id: Keyword.fetch!(opts, :session_id),
      session_opts: Keyword.fetch!(opts, :session_opts),
      timeout_ms: Keyword.fetch!(opts, :timeout_ms),
      signal: signal,
      task_pid: nil,
      task_ref: nil,
      runner: Keyword.get(opts, :runner, &default_runner/4),
      task_supervisor: Keyword.get(opts, :task_supervisor, CodingAgent.TaskSupervisor)
    }

    {:ok, state, {:continue, :launch}}
  end

  @impl true
  def handle_continue(:launch, state) do
    TaskStore.mark_running(state.id)
    emit(state, :background_run_started, %{status: :running})
    owner = self()

    result =
      Task.Supervisor.start_child(state.task_supervisor, fn ->
        result = run_queued(state)
        send(owner, {:background_run_result, state.id, result})
      end)

    case result do
      {:ok, task_pid} ->
        {:noreply, %{state | task_pid: task_pid, task_ref: Process.monitor(task_pid)}}

      {:error, reason} ->
        TaskStore.fail(state.id, {:worker_start_failed, reason})
        emit(state, :background_run_error, %{status: :error, error: :worker_start_failed})
        {:stop, :normal, state}
    end
  rescue
    error ->
      TaskStore.fail(state.id, {:worker_start_failed, error})
      emit(state, :background_run_error, %{status: :error, error: :worker_start_failed})
      {:stop, :normal, state}
  catch
    :exit, reason ->
      TaskStore.fail(state.id, {:worker_start_failed, reason})
      emit(state, :background_run_error, %{status: :error, error: :worker_start_failed})
      {:stop, :normal, state}
  end

  @impl true
  def handle_call({:cancel, reason}, _from, state) do
    TaskStore.cancel(state.id, reason)
    AbortSignal.abort(state.signal)
    abort_live_session(state.session_id)
    emit(state, :background_run_cancelled, %{status: :cancelled, reason: safe_reason(reason)})
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:background_run_result, id, result}, %{id: id} = state) do
    finalize(state, result)
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    case TaskStore.get(state.id) do
      {:ok, %{status: status}, _events} when status in [:cancelled, :completed, :error] ->
        :ok

      _ ->
        TaskStore.fail(state.id, {:worker_exit, reason})
        emit(state, :background_run_error, %{status: :error, error: :worker_exit})
    end

    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    AbortSignal.abort(state.signal)
    AbortSignal.clear(state.signal)
    abort_live_session(state.session_id)
    :ok
  end

  defp run_queued(state) do
    run = fn ->
      if AbortSignal.aborted?(state.signal) do
        {:error, :cancelled}
      else
        state.runner.(state.session_opts, state.prompt, state.signal, state.timeout_ms)
      end
    end

    if Process.whereis(LaneQueue) do
      case LaneQueue.run(LaneQueue, :subagent, run, %{
             task_id: state.id,
             kind: :background_command
           }) do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    else
      run.()
    end
  end

  defp default_runner(session_opts, prompt, signal, timeout_ms) do
    case Runner.start_session_with_prompt(
           session_opts,
           prompt,
           "Background command",
           signal,
           nil,
           nil,
           task_session_timeout_ms: timeout_ms
         ) do
      %AgentToolResult{} = result -> {:ok, Result.visible_output_text(result)}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_result, other}}
    end
  end

  defp finalize(state, {:ok, answer}) when is_binary(answer) do
    TaskStore.finish(state.id, %{answer: answer, session_id: state.session_id})
    emit(state, :background_run_completed, %{status: :completed})
  end

  defp finalize(state, {:error, reason}) do
    case TaskStore.get(state.id) do
      {:ok, %{status: :cancelled}, _events} ->
        :ok

      _ ->
        TaskStore.fail(state.id, reason)
        emit(state, :background_run_error, %{status: :error, error: safe_reason(reason)})
    end
  end

  defp finalize(state, other), do: finalize(state, {:error, {:unexpected_result, other}})

  defp abort_live_session(session_id) do
    case SessionRegistry.lookup(session_id) do
      {:ok, pid} -> Session.abort(pid)
      :error -> :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp emit(state, type, payload) do
    payload =
      Map.merge(payload, %{
        id: state.id,
        session_id: state.session_id,
        ts_ms: System.system_time(:millisecond)
      })

    TaskStore.append_event(state.id, %{type: type, payload: payload})

    event =
      LemonCore.Event.new(type, payload, %{
        run_id: state.id,
        session_key: Keyword.get(state.session_opts, :session_key)
      })

    LemonCore.Bus.broadcast("background_run:#{state.id}", event)
    LemonCore.Introspection.record(type, payload, run_id: state.id, provenance: :direct)
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 500)
  defp safe_reason(_reason), do: :internal_error
end
