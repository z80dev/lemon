defmodule LemonGateway.ThreadWorker do
  @moduledoc """
  Per-conversation FIFO worker.

  Queue semantics are owned by `lemon_router` (`SessionCoordinator`). This worker
  only launches already-ordered execution requests under global slot limits.
  """

  use GenServer

  require Logger

  alias LemonCore.Introspection
  alias LemonGateway.ExecutionRequest

  @slot_request_timeout_ms 30_000
  @max_run_start_attempts 3

  def start_link(opts) do
    thread_key = Keyword.fetch!(opts, :thread_key)
    name = {:via, Registry, {LemonGateway.ThreadRegistry, thread_key}}
    GenServer.start_link(__MODULE__, %{thread_key: thread_key}, name: name)
  end

  @impl true
  def init(state) do
    schedule_slot_timeout_check()

    Introspection.record(
      :thread_started,
      %{thread_key: inspect(state.thread_key)},
      engine: "lemon",
      provenance: :direct
    )

    {:ok,
     Map.merge(state, %{
       requests: :queue.new(),
       current_run: nil,
       current_slot_ref: nil,
       run_mon_ref: nil,
       slot_pending: false,
       slot_requested_at: nil
     })}
  end

  @impl true
  def handle_cast({:enqueue, %ExecutionRequest{} = request}, state) do
    Logger.debug(
      "ThreadWorker enqueue thread_key=#{inspect(state.thread_key)} run_id=#{inspect(request.run_id)} queue_len_before=#{queue_len_safe(state.requests)}"
    )

    Introspection.record(
      :thread_message_dispatched,
      %{
        thread_key: inspect(state.thread_key),
        queue_len: queue_len_safe(state.requests)
      },
      run_id: request.run_id,
      session_key: request.session_key,
      engine: "lemon",
      provenance: :direct
    )

    state = %{state | requests: :queue.in(request, state.requests)}
    {:noreply, maybe_request_slot(state)}
  end

  @impl true
  def handle_call({:enqueue, %ExecutionRequest{} = request}, _from, state) do
    state = %{state | requests: :queue.in(request, state.requests)}
    {:reply, :ok, maybe_request_slot(state)}
  end

  @impl true
  def handle_info({:slot_granted, slot_ref}, state) do
    cond do
      state.current_run != nil ->
        safe_release_slot(slot_ref)
        {:noreply, %{state | slot_pending: false, slot_requested_at: nil}}

      :queue.is_empty(state.requests) ->
        safe_release_slot(slot_ref)
        {:stop, :normal, %{state | slot_pending: false, slot_requested_at: nil}}

      true ->
        case :queue.out(state.requests) do
          {{:value, request}, rest} ->
            case start_run_safe(request, slot_ref, state.thread_key) do
              {:ok, run_pid} ->
                mon_ref = Process.monitor(run_pid)

                {:noreply,
                 %{
                   state
                   | requests: rest,
                     current_run: run_pid,
                     current_slot_ref: slot_ref,
                     run_mon_ref: mon_ref,
                     slot_pending: false,
                     slot_requested_at: nil
                 }}

              {:error, reason} ->
                Logger.error(
                  "ThreadWorker: failed to start run for request #{inspect(request.run_id)}, reason=#{inspect(reason)}"
                )

                safe_release_slot(slot_ref)

                state = %{state | requests: :queue.in_r(request, state.requests)}
                state = %{state | slot_pending: false, slot_requested_at: nil}
                {:noreply, maybe_request_slot(state)}
            end

          {:empty, _} ->
            safe_release_slot(slot_ref)
            {:stop, :normal, %{state | slot_pending: false, slot_requested_at: nil}}
        end
    end
  end

  def handle_info({:run_complete, run_pid, _completed_event}, state) do
    state =
      if run_pid == state.current_run do
        if is_reference(state.run_mon_ref) do
          Process.demonitor(state.run_mon_ref, [:flush])
        end

        %{state | current_run: nil, current_slot_ref: nil, run_mon_ref: nil}
      else
        state
      end

    state = maybe_request_slot(state)

    if state.current_run == nil and :queue.is_empty(state.requests) do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, mon_ref, :process, pid, reason}, state) do
    if state.current_run == pid and state.run_mon_ref == mon_ref do
      if state.current_slot_ref do
        safe_release_slot(state.current_slot_ref)
      end

      Logger.warning(
        "ThreadWorker observed run down thread_key=#{inspect(state.thread_key)} run_pid=#{inspect(pid)} reason=#{inspect(reason)}"
      )

      state =
        %{state | current_run: nil, current_slot_ref: nil, run_mon_ref: nil}
        |> maybe_request_slot()

      if state.current_run == nil and :queue.is_empty(state.requests) do
        {:stop, :normal, state}
      else
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(:slot_timeout_check, state) do
    state =
      if state.slot_pending and state.slot_requested_at != nil do
        elapsed = System.monotonic_time(:millisecond) - state.slot_requested_at

        if elapsed > @slot_request_timeout_ms do
          Logger.warning(
            "ThreadWorker: slot request timed out after #{div(elapsed, 1000)}s, retrying"
          )

          state = %{state | slot_pending: false, slot_requested_at: nil}
          maybe_request_slot(state)
        else
          state
        end
      else
        state
      end

    schedule_slot_timeout_check()
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warning("ThreadWorker received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Introspection.record(
      :thread_terminated,
      %{
        thread_key: inspect(state.thread_key),
        queue_len: queue_len_safe(state.requests)
      },
      engine: "lemon",
      provenance: :direct
    )

    :ok
  end

  defp schedule_slot_timeout_check do
    Process.send_after(self(), :slot_timeout_check, 5_000)
  end

  defp maybe_request_slot(state) do
    if state.current_run == nil and not state.slot_pending and not :queue.is_empty(state.requests) do
      try do
        LemonGateway.Scheduler.request_slot(self(), state.thread_key)
        %{state | slot_pending: true, slot_requested_at: System.monotonic_time(:millisecond)}
      catch
        :exit, {:noproc, _} ->
          Logger.error("ThreadWorker: scheduler not available for slot request")
          %{state | slot_pending: false, slot_requested_at: nil}

        :exit, reason ->
          Logger.error("ThreadWorker: scheduler request_slot exited: #{inspect(reason)}")
          %{state | slot_pending: false, slot_requested_at: nil}
      end
    else
      state
    end
  end

  defp safe_release_slot(slot_ref) do
    try do
      LemonGateway.Scheduler.release_slot(slot_ref)
    catch
      :exit, {:noproc, _} ->
        Logger.debug("ThreadWorker: scheduler not available for slot release")
        :ok

      :exit, reason ->
        Logger.warning("ThreadWorker: scheduler release_slot exited: #{inspect(reason)}")
        :ok
    end
  end

  defp start_run_safe(request, slot_ref, thread_key, attempt \\ 1) do
    try do
      case LemonGateway.RunSupervisor.start_run(%{
             execution_request: request,
             slot_ref: slot_ref,
             thread_key: thread_key,
             worker_pid: self()
           }) do
        {:ok, run_pid} ->
          {:ok, run_pid}

        {:error, reason} = err ->
          if attempt < @max_run_start_attempts do
            Logger.warning(
              "ThreadWorker: run start attempt #{attempt} failed, retrying: #{inspect(reason)}"
            )

            Process.sleep(100 * attempt)
            start_run_safe(request, slot_ref, thread_key, attempt + 1)
          else
            err
          end
      end
    catch
      :exit, {:noproc, _} ->
        if attempt < @max_run_start_attempts do
          Process.sleep(100 * attempt)
          start_run_safe(request, slot_ref, thread_key, attempt + 1)
        else
          {:error, :run_supervisor_unavailable}
        end

      :exit, reason ->
        {:error, {:run_start_exit, reason}}

      error ->
        {:error, {:run_start_exception, error}}
    end
  end

  defp queue_len_safe(queue) do
    try do
      :queue.len(queue)
    rescue
      _ -> 0
    end
  end
end
