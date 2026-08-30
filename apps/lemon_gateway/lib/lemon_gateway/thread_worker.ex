defmodule LemonGateway.ThreadWorker do
  @moduledoc """
  Per-conversation FIFO worker.

  Queue semantics are owned by `lemon_router` (`SessionCoordinator`). This worker
  only launches already-ordered execution requests under global slot limits.
  Run-start attempts are counted across slot grants. A request that cannot be
  started after the bounded attempt budget receives one synthetic terminal
  completion and is removed so later requests cannot be starved.
  """

  use GenServer

  require Logger

  alias LemonCore.{Bus, Events, Introspection}
  alias LemonGateway.{Event, ExecutionRequest}

  @slot_request_timeout_ms 30_000
  @max_run_start_attempts 3

  def start_link(opts) do
    thread_key = Keyword.fetch!(opts, :thread_key)
    name = {:via, Registry, {LemonGateway.ThreadRegistry, thread_key}}

    GenServer.start_link(
      __MODULE__,
      %{
        thread_key: thread_key,
        run_supervisor: Keyword.get(opts, :run_supervisor, LemonGateway.RunSupervisor)
      },
      name: name
    )
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
       slot_requested_at: nil,
       slot_request_token: nil,
       start_attempts: %{},
       terminalized_run_ids: MapSet.new()
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
  def handle_info({:slot_granted, slot_ref, token}, state) do
    if state.slot_pending and state.slot_request_token == token do
      handle_slot_granted(slot_ref, state)
    else
      safe_release_slot(slot_ref)
      {:noreply, state}
    end
  end

  def handle_info({:slot_granted, slot_ref}, state) do
    handle_slot_granted(slot_ref, state)
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

          safe_cancel_slot_request(state.slot_request_token)
          state = clear_slot_request(state)
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

  def handle_info({:slot_request_expired, token}, state) do
    if state.slot_pending and state.slot_request_token == token do
      {:noreply, state |> clear_slot_request() |> maybe_request_slot()}
    else
      {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Logger.warning("ThreadWorker received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp handle_slot_granted(slot_ref, state) do
    cond do
      state.current_run != nil ->
        safe_release_slot(slot_ref)
        {:noreply, clear_slot_request(state)}

      :queue.is_empty(state.requests) ->
        safe_release_slot(slot_ref)
        {:stop, :normal, clear_slot_request(state)}

      true ->
        case :queue.out(state.requests) do
          {{:value, request}, rest} ->
            attempt = Map.get(state.start_attempts, request.run_id, 0) + 1

            case start_run_once(state.run_supervisor, request, slot_ref, state.thread_key) do
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
                     slot_requested_at: nil,
                     slot_request_token: nil,
                     start_attempts: Map.delete(state.start_attempts, request.run_id)
                 }}

              {:error, reason} ->
                Logger.error(
                  "ThreadWorker: failed to start run for request #{inspect(request.run_id)} " <>
                    "attempt=#{attempt}/#{@max_run_start_attempts}, reason=#{inspect(reason)}"
                )

                safe_release_slot(slot_ref)

                state =
                  state
                  |> clear_slot_request()
                  |> Map.put(:requests, rest)
                  |> put_start_attempt(request.run_id, attempt)

                if attempt < @max_run_start_attempts do
                  state = %{state | requests: :queue.in_r(request, rest)}
                  {:noreply, maybe_request_slot(state)}
                else
                  state = terminalize_start_failure(state, request, reason, attempt)

                  state = %{
                    state
                    | start_attempts: Map.delete(state.start_attempts, request.run_id)
                  }

                  continue_or_stop(state)
                end
            end

          {:empty, _} ->
            safe_release_slot(slot_ref)
            {:stop, :normal, clear_slot_request(state)}
        end
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.slot_pending, do: safe_cancel_slot_request(state.slot_request_token)

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
      token = make_ref()

      try do
        LemonGateway.Scheduler.request_slot(self(), state.thread_key, token)

        %{
          state
          | slot_pending: true,
            slot_requested_at: System.monotonic_time(:millisecond),
            slot_request_token: token
        }
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

  defp safe_cancel_slot_request(nil), do: :ok

  defp safe_cancel_slot_request(token) do
    LemonGateway.Scheduler.cancel_slot_request(self(), token)
  catch
    :exit, _ -> :ok
  end

  defp start_run_once(run_supervisor, request, slot_ref, thread_key) do
    try do
      case run_supervisor.start_run(%{
             execution_request: request,
             slot_ref: slot_ref,
             thread_key: thread_key,
             worker_pid: self()
           }) do
        {:ok, run_pid} ->
          {:ok, run_pid}

        {:error, _reason} = err ->
          err
      end
    catch
      :exit, {:noproc, _} ->
        {:error, :run_supervisor_unavailable}

      :exit, reason ->
        {:error, {:run_start_exit, reason}}

      error ->
        {:error, {:run_start_exception, error}}
    end
  end

  defp clear_slot_request(state) do
    %{state | slot_pending: false, slot_requested_at: nil, slot_request_token: nil}
  end

  defp put_start_attempt(state, run_id, attempt) do
    %{state | start_attempts: Map.put(state.start_attempts, run_id, attempt)}
  end

  defp terminalize_start_failure(state, request, reason, attempts) do
    if MapSet.member?(state.terminalized_run_ids, request.run_id) do
      state
    else
      safe_reason = safe_failure_reason(reason)

      completed =
        Event.completed(%{
          engine: "lemon",
          ok: false,
          answer: "",
          error: %{
            type: :run_start_failed,
            reason: safe_reason,
            attempts: attempts
          },
          run_id: request.run_id,
          session_key: request.session_key,
          meta: %{synthetic: true, failure_stage: :run_start}
        })

      Bus.broadcast(
        Bus.run_topic(request.run_id),
        LemonCore.Event.new(
          :run_completed,
          Events.RunCompleted.new(%{completed: completed, duration_ms: 0}),
          %{
            run_id: request.run_id,
            session_key: request.session_key,
            synthetic: true,
            failure_stage: :run_start
          }
        )
      )

      notify_pid = meta_field(request.meta, :notify_pid)

      if is_pid(notify_pid) do
        send(notify_pid, {:lemon_gateway_run_completed, request, completed})
      end

      Introspection.record(
        :run_start_failed,
        %{reason: safe_reason, attempts: attempts},
        run_id: request.run_id,
        session_key: request.session_key,
        engine: "lemon",
        provenance: :direct
      )

      %{state | terminalized_run_ids: MapSet.put(state.terminalized_run_ids, request.run_id)}
    end
  end

  defp continue_or_stop(state) do
    state = maybe_request_slot(state)

    if state.current_run == nil and :queue.is_empty(state.requests) do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  defp safe_failure_reason(reason)
       when is_atom(reason) or is_binary(reason) or is_number(reason),
       do: reason

  defp safe_failure_reason(reason), do: inspect(reason, limit: 20, printable_limit: 1_000)

  defp meta_field(meta, key) when is_map(meta),
    do: Map.get(meta, key) || Map.get(meta, Atom.to_string(key))

  defp meta_field(_, _), do: nil

  defp queue_len_safe(queue) do
    try do
      :queue.len(queue)
    rescue
      _ -> 0
    end
  end
end
