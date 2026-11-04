defmodule LemonGateway.ThreadWorker do
  @moduledoc """
  Per-conversation FIFO worker.

  Queue semantics are owned by `lemon_router` (`SessionCoordinator`). This worker
  only launches already-ordered execution requests under global slot limits.
  Run-start attempts are counted across slot grants. A request that cannot be
  started after the bounded attempt budget receives one synthetic terminal
  completion and is removed so later requests cannot be starved.

  A pending slot request owns its token and timestamp together; an active run
  owns its PID, execution request, slot and monitor together. A completion is
  evidence that `Run` already released its slot. A matching monitor DOWN only
  releases fallback ownership; it does not imply a known execution result.
  """

  use GenServer

  require Logger

  alias LemonCore.{Bus, Events, Introspection}
  alias LemonGateway.{Event, ExecutionRequest}

  @slot_request_timeout_ms 30_000
  @max_run_start_attempts 3

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :thread_key)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

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
       active_run: nil,
       slot_request: nil,
       start_attempts: %{}
     })}
  end

  @impl true
  def handle_cast({:enqueue, %ExecutionRequest{} = request}, state) do
    {:noreply, enqueue_request(state, request)}
  end

  def handle_cast({:cancel_queued, run_id, reason}, state) do
    {cancelled, kept} =
      state.requests
      |> :queue.to_list()
      |> Enum.split_with(&(&1.run_id == run_id))

    state = %{state | requests: :queue.from_list(kept)}

    state =
      Enum.reduce(cancelled, state, fn request, acc ->
        acc
        |> terminalize_request(request, reason, :cancelled)
        |> Map.update!(:start_attempts, &Map.delete(&1, request.run_id))
      end)

    case state.active_run do
      %{pid: pid, request: %ExecutionRequest{run_id: ^run_id}} ->
        LemonGateway.Scheduler.cancel(pid, reason)

      _ ->
        :ok
    end

    if state.active_run == nil and :queue.is_empty(state.requests) do
      {:stop, :normal, cancel_slot_request(state)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_call({:enqueue, %ExecutionRequest{} = request}, _from, state) do
    {:reply, :ok, enqueue_request(state, request)}
  end

  @impl true
  def handle_info(
        {:slot_granted, slot_ref, token},
        %{slot_request: %{token: token}} = state
      ) do
    handle_slot_granted(slot_ref, state)
  end

  def handle_info({:slot_granted, slot_ref, _token}, state) do
    release_stale_grant(slot_ref, state)
    {:noreply, state}
  end

  def handle_info({:slot_granted, slot_ref}, state) do
    # Production requests are tokenized; an uncorrelated grant cannot launch work.
    release_stale_grant(slot_ref, state)
    {:noreply, state}
  end

  def handle_info(
        {:run_complete, run_pid, _completed_event},
        %{active_run: %{pid: run_pid}} = state
      ) do
    # Run releases its slot before sending this acknowledgement.
    state |> clear_active_run() |> continue_or_stop()
  end

  def handle_info({:run_complete, _run_pid, _completed_event}, state) do
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, mon_ref, :process, pid, reason},
        %{active_run: %{pid: pid, mon_ref: mon_ref, slot_ref: slot_ref}} = state
      ) do
    safe_release_slot(slot_ref)

    Logger.warning(
      "ThreadWorker observed run down thread_key=#{inspect(state.thread_key)} run_pid=#{inspect(pid)} reason=#{inspect(reason)}"
    )

    state |> clear_active_run() |> continue_or_stop()
  end

  def handle_info({:DOWN, _mon_ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(:slot_timeout_check, state) do
    state =
      case state.slot_request do
        %{requested_at: requested_at} ->
          elapsed = System.monotonic_time(:millisecond) - requested_at

          if elapsed > @slot_request_timeout_ms do
            Logger.warning(
              "ThreadWorker: slot request timed out after #{div(elapsed, 1000)}s, retrying"
            )

            state |> cancel_slot_request() |> maybe_request_slot()
          else
            state
          end

        nil ->
          state
      end

    schedule_slot_timeout_check()
    {:noreply, state}
  end

  def handle_info(
        {:slot_request_rejected, token, reason},
        %{slot_request: %{token: token}} = state
      ) do
    {{:value, request}, rest} = :queue.out(state.requests)

    state
    |> clear_slot_request()
    |> Map.put(:requests, rest)
    |> terminalize_request(request, reason, :run_start)
    |> continue_or_stop()
  end

  def handle_info({:slot_request_rejected, _token, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(
        {:slot_request_expired, token},
        %{slot_request: %{token: token}} = state
      ) do
    {:noreply, state |> clear_slot_request() |> maybe_request_slot()}
  end

  def handle_info({:slot_request_expired, _token}, state) do
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warning("ThreadWorker received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp handle_slot_granted(slot_ref, state) do
    cond do
      state.active_run != nil ->
        release_stale_grant(slot_ref, state)
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
                     active_run: %{
                       pid: run_pid,
                       request: request,
                       slot_ref: slot_ref,
                       mon_ref: mon_ref
                     },
                     slot_request: nil,
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
    cancel_slot_request(state)

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
    if state.active_run == nil and state.slot_request == nil and
         not :queue.is_empty(state.requests) do
      token = make_ref()

      try do
        LemonGateway.Scheduler.request_slot(self(), state.thread_key, token)

        %{
          state
          | slot_request: %{token: token, requested_at: System.monotonic_time(:millisecond)}
        }
      catch
        :exit, {:noproc, _} ->
          Logger.error("ThreadWorker: scheduler not available for slot request")
          state

        :exit, reason ->
          Logger.error("ThreadWorker: scheduler request_slot exited: #{inspect(reason)}")
          state
      end
    else
      state
    end
  end

  defp enqueue_request(state, request) do
    cond do
      match?(
        %{request: %ExecutionRequest{run_id: id}} when id == request.run_id,
        state.active_run
      ) or
        Enum.any?(:queue.to_list(state.requests), &(&1.run_id == request.run_id)) or
          already_terminal?(request.run_id) ->
        state

      :queue.len(state.requests) >= 128 ->
        terminalize_request(state, request, :execution_queue_full, :run_start)

      true ->
        Logger.debug(
          "ThreadWorker enqueue thread_key=#{inspect(state.thread_key)} run_id=#{inspect(request.run_id)} queue_len_before=#{queue_len_safe(state.requests)}"
        )

        Introspection.record(
          :thread_message_dispatched,
          %{thread_key: inspect(state.thread_key), queue_len: queue_len_safe(state.requests)},
          run_id: request.run_id,
          session_key: request.session_key,
          engine: "lemon",
          provenance: :direct
        )

        %{state | requests: :queue.in(request, state.requests)}
        |> maybe_request_slot()
    end
  end

  defp already_terminal?(run_id) do
    case LemonCore.RunStore.fetch(run_id) do
      {:ok, nil} -> false
      {:ok, %{summary: nil}} -> false
      {:ok, %{summary: summary}} when is_map(summary) -> true
      _ -> exit(:run_state_unavailable)
    end
  end

  defp release_stale_grant(slot_ref, %{active_run: %{slot_ref: slot_ref}}), do: :ok
  defp release_stale_grant(slot_ref, _state), do: safe_release_slot(slot_ref)

  defp clear_active_run(%{active_run: %{mon_ref: mon_ref}} = state) do
    Process.demonitor(mon_ref, [:flush])
    %{state | active_run: nil}
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

  defp cancel_slot_request(%{slot_request: nil} = state), do: state

  defp cancel_slot_request(%{slot_request: %{token: token}} = state) do
    safe_cancel_slot_request(token)
    clear_slot_request(state)
  end

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
    %{state | slot_request: nil}
  end

  defp put_start_attempt(state, run_id, attempt) do
    %{state | start_attempts: Map.put(state.start_attempts, run_id, attempt)}
  end

  defp terminalize_start_failure(state, request, reason, attempts) do
    terminalize_request(
      state,
      request,
      %{type: :run_start_failed, reason: safe_failure_reason(reason), attempts: attempts},
      :run_start
    )
  end

  defp terminalize_request(state, request, error, stage) do
    if already_terminal?(request.run_id) do
      state
    else
      completed =
        Event.completed(%{
          engine: "lemon",
          ok: false,
          answer: "",
          error: error,
          run_id: request.run_id,
          session_key: request.session_key,
          meta: %{synthetic: true, failure_stage: stage, cancelled: stage == :cancelled}
        })

      :ok =
        LemonCore.RunStore.finalize(request.run_id, %{
          completed: completed,
          session_key: request.session_key,
          run_id: request.run_id,
          prompt: request.prompt,
          duration_ms: 0,
          engine: "lemon",
          meta: request.meta
        })

      LemonCore.Telemetry.emit(
        [:lemon, :run, :stop],
        %{duration_ms: 0, ok: false},
        %{run_id: request.run_id, session_key: request.session_key, engine: "lemon"}
      )

      Bus.broadcast(
        Bus.run_topic(request.run_id),
        LemonCore.Event.new(
          :run_completed,
          Events.RunCompleted.new(%{completed: completed, duration_ms: 0}),
          %{
            run_id: request.run_id,
            session_key: request.session_key,
            synthetic: true,
            failure_stage: stage
          }
        )
      )

      notify_pid = meta_field(request.meta, :notify_pid)

      if is_pid(notify_pid) do
        send(notify_pid, {:lemon_gateway_run_completed, request, completed})
      end

      Introspection.record(
        :run_start_failed,
        %{reason: safe_failure_reason(error), failure_stage: stage},
        run_id: request.run_id,
        session_key: request.session_key,
        engine: "lemon",
        provenance: :direct
      )

      state
    end
  end

  defp continue_or_stop(state) do
    state = maybe_request_slot(state)

    if state.active_run == nil and :queue.is_empty(state.requests) do
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
