defmodule LemonGateway.Run do
  @moduledoc """
  Transport-agnostic run execution.

  Run is responsible for:
  - Executing runs
  - Emitting events to the LemonCore.Bus
  - Storing run events to the Store
  - Managing run lifecycle (start, steer, cancel, complete)

  Run does NOT:
  - Perform channel-specific rendering (handled by lemon_channels via bus events)
  - Call Telegram outbox directly (removed - all output goes through lemon_channels)

  ## Event Emission

  All events are broadcast to the LemonCore.Bus on topic "run:<run_id>".
  Subscribers (router, channels, control-plane) receive these events and
  handle channel-specific rendering.

  ## Channel Output Flow

  1. Run emits :delta and :run_completed events to the bus
  2. LemonRouter.RunProcess receives these events and forwards to session topic
  3. LemonRouter.StreamCoalescer ingests deltas and coalesces them
  4. Coalesced output is enqueued to LemonChannels.Outbox for delivery
  """
  use GenServer
  require Logger
  import LemonGateway.Event, only: [is_started: 1, is_action_event: 1, is_completed: 1]

  alias LemonCore.{Cwd, ProgressStore, RunStore}

  alias LemonCore.Events
  alias LemonGateway.{Event, ExecutionRequest, Executor}
  alias LemonCore.ResumeToken

  @engine_provenance "lemon"
  @max_logged_error_bytes 4_096
  @executor_start_error_banner_bytes 1_024

  def start_link(args) do
    # Allow cancel-by-run-id (used by router/control-plane) by registering the run
    # process under LemonGateway.RunRegistry when run_id is present.
    name =
      case args do
        %{execution_request: %ExecutionRequest{run_id: run_id}}
        when is_binary(run_id) and run_id != "" ->
          {:via, Registry, {LemonGateway.RunRegistry, run_id}}

        _ ->
          nil
      end

    opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, args, opts)
  end

  @impl true
  def init(args) when is_map(args) do
    %{
      execution_request: %ExecutionRequest{} = request,
      slot_ref: slot_ref,
      worker_pid: worker_pid
    } =
      args

    submitted_request = request
    run_id = request.run_id || generate_run_id()
    session_key = request.session_key || "default"
    request = %{request | run_id: run_id, session_key: session_key}
    executor_result = resolve_configured_executor()

    {lock_release_fn, continuation} =
      case maybe_acquire_lock(request) do
        {:ok, release_fn} ->
          Logger.debug(
            "Gateway run init lock acquired run_id=#{inspect(run_id)} session_key=#{inspect(session_key)}"
          )

          {release_fn, {:start_run, executor_result}}

        {:error, :timeout} ->
          Logger.warning(
            "Gateway run lock timeout run_id=#{inspect(run_id)} session_key=#{inspect(session_key)}"
          )

          {fn -> :ok end, :lock_timeout}
      end

    state = %{
      submitted_execution_request: submitted_request,
      execution_request: request,
      run_id: run_id,
      session_key: session_key,
      slot_ref: slot_ref,
      worker_pid: worker_pid,
      executor: nil,
      run_ref: nil,
      control_ctx: nil,
      renderer: LemonGateway.Renderers.Basic,
      renderer_state: nil,
      completed: false,
      lock_release_fn: lock_release_fn,
      last_resume: request.resume,
      cancelled: false,
      delta_seq: 0,
      start_ts_ms: System.system_time(:millisecond),
      accumulated_text: "",
      first_token_emitted: false,
      progress_mapping_registered?: false
    }

    {:ok, state, {:continue, continuation}}
  end

  defp generate_run_id do
    "run_#{LemonCore.Id.uuid()}"
  end

  defp maybe_acquire_lock(request) do
    require_lock = LemonGateway.Config.get(:require_engine_lock)
    timeout_ms = LemonGateway.Config.get(:engine_lock_timeout_ms) || 60_000

    if require_lock do
      LemonGateway.EngineLock.acquire(lock_key_for(request), timeout_ms)
    else
      {:ok, fn -> :ok end}
    end
  end

  defp lock_key_for(%ExecutionRequest{resume: %ResumeToken{value: value}})
       when is_binary(value) do
    {:resume, value}
  end

  defp lock_key_for(%ExecutionRequest{session_key: session_key}) when is_binary(session_key) do
    {:session, session_key}
  end

  defp lock_key_for(_), do: {:default, :global}

  # Request meta is atom-keyed on the normal router path, but replayed events
  # and hand-built tests can use string keys.
  defp meta_field(%ExecutionRequest{meta: meta}, key) when is_map(meta) do
    case Map.get(meta, key) do
      nil -> Map.get(meta, Atom.to_string(key))
      value -> value
    end
  end

  defp meta_field(_request, _key), do: nil

  defp resolve_configured_executor do
    with {:ok, executor} <- Executor.configured_module(),
         :ok <- Executor.validate(executor) do
      {:ok, executor}
    end
  rescue
    error ->
      Logger.error(
        "Gateway run executor resolution raised error=" <>
          truncate_for_log(
            Exception.format_banner(:error, error),
            @executor_start_error_banner_bytes
          )
      )

      {:error, "executor_resolution_exception: " <> Exception.message(error)}
  catch
    :exit, reason ->
      Logger.error("Gateway run executor resolution exited reason=#{inspect(reason)}")
      {:error, "executor_resolution_exit: " <> inspect(reason)}

    kind, reason ->
      Logger.error(
        "Gateway run executor resolution threw kind=#{inspect(kind)} reason=#{inspect(reason)}"
      )

      {:error, "executor_resolution_throw: " <> inspect({kind, reason})}
  end

  @impl true
  def handle_continue(:lock_timeout, state) do
    completed =
      Event.completed(%{
        engine: @engine_provenance,
        ok: false,
        error: :lock_timeout,
        answer: "",
        run_id: state.run_id,
        session_key: state.session_key
      })

    renderer_state = state.renderer.init(%{engine: @engine_provenance})
    {renderer_state, render_action} = state.renderer.apply_event(renderer_state, completed)
    maybe_update_progress(state, render_action)
    state = %{state | renderer_state: renderer_state}

    finalize(state, completed)
    {:stop, :normal, %{state | completed: true}}
  end

  def handle_continue({:start_run, {:error, reason}}, state) do
    finalize_start_failure(state, reason)
  end

  def handle_continue({:start_run, {:ok, executor}}, state) do
    request = state.execution_request

    Logger.debug(
      "Gateway run start run_id=#{inspect(state.run_id)} session_key=#{inspect(state.session_key)} " <>
        "resume=#{inspect(request.resume)} cwd=#{inspect(request.cwd)}"
    )

    renderer_state = state.renderer.init(%{engine: @engine_provenance})

    cwd =
      cond do
        is_binary(request.cwd) and String.trim(request.cwd) != "" ->
          Path.expand(request.cwd)

        true ->
          Cwd.default_cwd()
      end

    opts = [cwd: cwd, run_id: state.run_id]

    emit_to_bus(
      state.run_id,
      :run_started,
      Events.RunStarted.new(%{
        run_id: state.run_id,
        session_key: state.session_key,
        engine: @engine_provenance,
        model: meta_field(request, :model),
        thinking_level: meta_field(request, :thinking_level)
      }),
      build_event_meta(state)
    )

    emit_telemetry_start(state.run_id, %{
      session_key: state.session_key,
      engine: @engine_provenance,
      origin: meta_field(request, :origin)
    })

    case safe_start_executor_run(executor, request, opts, self()) do
      {:ok, run_ref, control_ctx} ->
        Logger.debug(
          "Gateway run executor started run_id=#{inspect(state.run_id)} run_ref=#{inspect(run_ref)}"
        )

        register_progress_mapping(request, state.run_id)

        {:noreply,
         %{
           state
           | executor: executor,
             run_ref: run_ref,
             control_ctx: control_ctx,
             renderer_state: renderer_state,
             progress_mapping_registered?: true
         }}

      {:error, reason} ->
        finalize_start_failure(
          %{state | executor: executor, renderer_state: renderer_state},
          reason
        )

      other ->
        finalize_start_failure(
          %{state | executor: executor, renderer_state: renderer_state},
          {:invalid_executor_start_result, other}
        )
    end
  end

  defp finalize_start_failure(state, reason) do
    Logger.warning(
      "Gateway run executor start failed run_id=#{inspect(state.run_id)} reason=#{inspect(reason)}"
    )

    renderer_state = state.renderer_state || state.renderer.init(%{engine: @engine_provenance})

    completed =
      Event.completed(%{
        engine: @engine_provenance,
        ok: false,
        error: reason,
        answer: "",
        run_id: state.run_id,
        session_key: state.session_key
      })

    {renderer_state, render_action} = state.renderer.apply_event(renderer_state, completed)
    maybe_update_progress(state, render_action)
    state = %{state | renderer_state: renderer_state}

    finalize(state, completed)
    {:stop, :normal, %{state | completed: true}}
  end

  defp safe_start_executor_run(executor, %ExecutionRequest{} = request, opts, sink_pid) do
    executor.start_run(request, opts, sink_pid)
  rescue
    error ->
      Logger.error(
        "Gateway run executor start raised executor=#{inspect(executor)} " <>
          "session_key=#{inspect(request.session_key)} error=" <>
          truncate_for_log(
            Exception.format_banner(:error, error),
            @executor_start_error_banner_bytes
          )
      )

      {:error, "executor_start_exception: " <> Exception.message(error)}
  catch
    :exit, reason ->
      Logger.error(
        "Gateway run executor start exited executor=#{inspect(executor)} " <>
          "session_key=#{inspect(request.session_key)} reason=#{inspect(reason)}"
      )

      {:error, "executor_start_exit: " <> inspect(reason)}

    kind, reason ->
      Logger.error(
        "Gateway run executor start threw executor=#{inspect(executor)} " <>
          "session_key=#{inspect(request.session_key)} kind=#{inspect(kind)} reason=#{inspect(reason)}"
      )

      {:error, "executor_start_throw: " <> inspect({kind, reason})}
  end

  @impl true
  def handle_info({:engine_event, run_ref, event}, %{run_ref: run_ref} = state) do
    RunStore.append_event(state.run_id, event)

    cond do
      is_started(event) ->
        Logger.debug(
          "Gateway run engine_event started run_id=#{inspect(state.run_id)} session_key=#{inspect(state.session_key)}"
        )

      is_completed(event) ->
        Logger.info(
          "Gateway run engine_event completed run_id=#{inspect(state.run_id)} session_key=#{inspect(state.session_key)} " <>
            "ok=#{inspect(event.ok)} error=#{inspect(Map.get(event, :error))} answer_bytes=#{byte_size(event.answer || "")}"
        )

      is_action_event(event) ->
        Logger.debug(
          "Gateway run action run_id=#{inspect(state.run_id)} phase=#{inspect(event.phase)} kind=#{inspect(event.action && event.action.kind)} " <>
            action_event_ok_fragment(event.ok)
        )

      true ->
        :ok
    end

    # Emit event to bus
    emit_engine_event_to_bus(state, event)

    # Update renderer state for answer tracking (but no rendering)
    {renderer_state, render_action} = state.renderer.apply_event(state.renderer_state, event)
    state = %{state | renderer_state: renderer_state}
    maybe_update_progress(state, render_action)

    cond do
      is_started(event) ->
        resume = event.resume
        # Note: Do NOT store chat state here. Storing on Started allows new messages
        # to auto-resume to this token while the run is still active, creating
        # concurrent runs. Chat state is stored in finalize/2 after Completed.
        {:noreply, %{state | last_resume: resume || state.last_resume}}

      is_completed(event) ->
        resume = event.resume
        state = %{state | last_resume: resume || state.last_resume}
        finalize(state, event)
        {:stop, :normal, state}

      true ->
        {:noreply, state}
    end
  end

  # Handle delta events from engine (for streaming)
  def handle_info({:engine_delta, run_ref, text}, %{run_ref: run_ref} = state)
      when is_binary(text) do
    new_seq = state.delta_seq + 1

    # Emit first_token telemetry on first delta
    state =
      if not state.first_token_emitted do
        latency_ms = System.system_time(:millisecond) - state.start_ts_ms

        emit_telemetry_first_token(
          state.run_id,
          %{
            session_key: state.session_key,
            engine: @engine_provenance
          },
          latency_ms
        )

        %{state | first_token_emitted: true}
      else
        state
      end

    # Subscribers such as the router's StreamCoalescer take deltas from the bus;
    # `seq` is monotonic per run so they can drop duplicates and reorder safely.
    emit_to_bus(
      state.run_id,
      :delta,
      Events.Delta.new(%{
        run_id: state.run_id,
        ts_ms: System.system_time(:millisecond),
        seq: new_seq,
        text: text,
        meta: %{session_key: state.session_key}
      }),
      build_event_meta(state)
    )

    # Accumulate text for final answer
    {:noreply, %{state | delta_seq: new_seq, accumulated_text: state.accumulated_text <> text}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast({:steer, submission_run_id, prompt, worker_pid}, state)
      when is_binary(submission_run_id) and is_binary(prompt) do
    {:noreply, handle_steer(:steer, submission_run_id, prompt, worker_pid, state)}
  end

  def handle_cast({:steer_backlog, submission_run_id, prompt, worker_pid}, state)
      when is_binary(submission_run_id) and is_binary(prompt) do
    {:noreply, handle_steer(:steer_backlog, submission_run_id, prompt, worker_pid, state)}
  end

  def handle_cast({:redirect, submission_run_id, prompt, worker_pid}, state)
      when is_binary(submission_run_id) and is_binary(prompt) do
    {:noreply, handle_redirect(submission_run_id, prompt, worker_pid, state)}
  end

  @impl true
  def handle_cast({:cancel, reason}, state) do
    if state.completed do
      {:noreply, state}
    else
      Logger.warning(
        "Gateway run cancel run_id=#{inspect(state.run_id)} session_key=#{inspect(state.session_key)} reason=#{inspect(reason)}"
      )

      if state.executor do
        _ = safe_executor_control(state.executor, :cancel, state.control_ctx)
      end

      resume = state.last_resume || state.execution_request.resume

      completed =
        Event.completed(%{
          engine: @engine_provenance,
          resume: resume,
          ok: false,
          error: reason,
          answer: "",
          run_id: state.run_id,
          session_key: state.session_key
        })

      state = %{state | cancelled: true}
      finalize(state, completed)
      {:stop, :normal, %{state | completed: true}}
    end
  end

  defp handle_steer(kind, submission_run_id, prompt, worker_pid, state) do
    cond do
      state.completed or is_nil(state.executor) ->
        notify_steer_result(kind, :rejected, worker_pid, submission_run_id)
        state

      safe_executor_control(state.executor, :steer, state.control_ctx, prompt) == :ok ->
        notify_steer_result(kind, :accepted, worker_pid, submission_run_id)
        state

      true ->
        notify_steer_result(kind, :rejected, worker_pid, submission_run_id)
        state
    end
  end

  defp handle_redirect(submission_run_id, prompt, worker_pid, state) do
    cond do
      state.completed or is_nil(state.executor) ->
        notify_steer_result(:redirect, :rejected, worker_pid, submission_run_id)
        state

      true ->
        case safe_executor_control(state.executor, :redirect, state.control_ctx, prompt) do
          :ok ->
            notify_steer_result(:redirect, :accepted, worker_pid, submission_run_id)
            state

          {:error, :unsupported} ->
            handle_steer(:redirect, submission_run_id, prompt, worker_pid, state)

          _ ->
            notify_steer_result(:redirect, :rejected, worker_pid, submission_run_id)
            state
        end
    end
  end

  defp safe_executor_control(executor, callback, control_ctx, text \\ nil) do
    if is_nil(text) do
      apply(executor, callback, [control_ctx])
    else
      apply(executor, callback, [control_ctx, text])
    end
  rescue
    error ->
      Logger.error(
        "Gateway run executor #{callback} raised executor=#{inspect(executor)} " <>
          "error=" <>
          truncate_for_log(
            Exception.format_banner(:error, error),
            @executor_start_error_banner_bytes
          )
      )

      {:error, :executor_control_exception}
  catch
    :exit, reason ->
      Logger.error(
        "Gateway run executor #{callback} exited executor=#{inspect(executor)} reason=#{inspect(reason)}"
      )

      {:error, :executor_control_exit}

    kind, reason ->
      Logger.error(
        "Gateway run executor #{callback} threw executor=#{inspect(executor)} " <>
          "kind=#{inspect(kind)} reason=#{inspect(reason)}"
      )

      {:error, :executor_control_throw}
  end

  defp notify_steer_result(:steer, :accepted, worker_pid, request),
    do: send(worker_pid, {:steer_accepted, request})

  defp notify_steer_result(:steer, :rejected, worker_pid, request),
    do: send(worker_pid, {:steer_rejected, request})

  defp notify_steer_result(:steer_backlog, :accepted, worker_pid, request),
    do: send(worker_pid, {:steer_backlog_accepted, request})

  defp notify_steer_result(:steer_backlog, :rejected, worker_pid, request),
    do: send(worker_pid, {:steer_backlog_rejected, request})

  defp notify_steer_result(:redirect, :accepted, worker_pid, request),
    do: send(worker_pid, {:redirect_accepted, request})

  defp notify_steer_result(:redirect, :rejected, worker_pid, request),
    do: send(worker_pid, {:redirect_rejected, request})

  defp action_event_ok_fragment(ok?) when is_boolean(ok?), do: "ok=#{inspect(ok?)}"
  defp action_event_ok_fragment(_), do: "ok=unknown"

  defp finalize(state, %{__event__: :completed} = completed) do
    state = %{state | completed: true}

    # Release engine lock first (if acquired)
    if is_function(state.lock_release_fn) do
      state.lock_release_fn.()
    end

    # Add run_id, session_key, and accumulated answer to completed event
    answer = Map.get(completed, :answer)

    completed =
      completed
      |> Map.put(:run_id, state.run_id)
      |> Map.put(:session_key, state.session_key)
      |> Map.put(:answer, if(answer == "", do: state.accumulated_text, else: answer))

    Logger.info(
      "Gateway run finalize run_id=#{inspect(state.run_id)} session_key=#{inspect(state.session_key)} " <>
        "ok=#{inspect(Map.get(completed, :ok))} error=#{inspect(Map.get(completed, :error))} " <>
        "answer_bytes=#{byte_size(Map.get(completed, :answer) || "")}"
    )

    if Map.get(completed, :ok) != true do
      log_run_failure(state, completed)
    end

    # Emit completion event to bus (channel delivery handled by subscribers)
    duration_ms = System.system_time(:millisecond) - state.start_ts_ms

    # Emit run_stop telemetry
    emit_telemetry_stop(
      state.run_id,
      %{
        session_key: state.session_key,
        engine: @engine_provenance
      },
      duration_ms,
      Map.get(completed, :ok)
    )

    emit_to_bus(
      state.run_id,
      :run_completed,
      Events.RunCompleted.new(%{
        completed: completed_to_bus_map(completed),
        duration_ms: duration_ms
      }),
      build_event_meta(state)
    )

    if state.run_id do
      prompt = state.execution_request.prompt

      RunStore.finalize(state.run_id, %{
        completed: completed,
        session_key: state.session_key,
        run_id: state.run_id,
        run_ref: state.run_ref,
        prompt: prompt,
        duration_ms: duration_ms,
        engine: @engine_provenance,
        meta: state.execution_request.meta
      })
    end

    LemonGateway.Scheduler.release_slot(state.slot_ref)
    send(state.worker_pid, {:run_complete, self(), completed})

    notify_pid = meta_field(state.execution_request, :notify_pid)

    if is_pid(notify_pid) do
      send(
        notify_pid,
        {:lemon_gateway_run_completed, state.submitted_execution_request, completed}
      )
    end

    if state.progress_mapping_registered? do
      unregister_progress_mapping(state.execution_request)
    end

    :ok
  end

  defp log_run_failure(_state, %{__event__: :completed} = completed) do
    error_text = format_error_for_log(Map.get(completed, :error))

    level =
      if Map.get(completed, :error) in [:user_requested, :interrupted, :new_session],
        do: :warning,
        else: :error

    message =
      "Gateway run failed " <>
        "run_id=#{inspect(Map.get(completed, :run_id))} " <>
        "session_key=#{inspect(Map.get(completed, :session_key))} " <>
        "error=#{error_text} " <>
        "answer_bytes=#{byte_size(Map.get(completed, :answer) || "")}"

    case level do
      :warning -> Logger.warning(message)
      _ -> Logger.error(message)
    end
  end

  defp format_error_for_log(error) when is_binary(error) do
    truncate_for_log(error, @max_logged_error_bytes)
  end

  defp format_error_for_log(error) when is_atom(error), do: Atom.to_string(error)

  defp format_error_for_log(error) do
    error
    |> inspect(limit: 50, printable_limit: @max_logged_error_bytes)
    |> truncate_for_log(@max_logged_error_bytes)
  end

  defp truncate_for_log(text, max_bytes) when byte_size(text) <= max_bytes, do: text

  defp truncate_for_log(text, max_bytes) do
    prefix =
      text
      |> binary_part(0, max_bytes)
      |> trim_to_valid_utf8()

    "#{prefix}...[truncated #{byte_size(text) - byte_size(prefix)} bytes]"
  end

  defp trim_to_valid_utf8(<<>>), do: ""

  defp trim_to_valid_utf8(binary) when is_binary(binary) do
    if String.valid?(binary) do
      binary
    else
      binary
      |> binary_part(0, byte_size(binary) - 1)
      |> trim_to_valid_utf8()
    end
  end

  # Emit events to the LemonCore.Bus via DependencyManager
  defp emit_to_bus(run_id, event_type, payload, extra_meta) do
    alias LemonGateway.DependencyManager

    topic = "run:#{run_id}"
    meta = Map.merge(%{run_id: run_id}, extra_meta)
    event = DependencyManager.build_event(event_type, payload, meta)
    DependencyManager.broadcast(topic, event)
  end

  # Helper to build standard meta from state
  defp build_event_meta(state) do
    meta = %{run_id: state.run_id}

    meta = if state.session_key, do: Map.put(meta, :session_key, state.session_key), else: meta

    origin = meta_field(state.execution_request, :origin)
    meta = if origin, do: Map.put(meta, :origin, origin), else: meta

    # Carry the router's resolved model on every event of the run, not just `run_started`:
    # a client that attached mid-run still learns what it is talking to at `run_completed`.
    model = meta_field(state.execution_request, :model)
    if model, do: Map.put(meta, :model, model), else: meta
  end

  defp emit_engine_event_to_bus(state, event) do
    # Event constructors already produce plain maps; convert to bus shape.
    {event_type, payload} =
      cond do
        is_started(event) -> {:engine_started, started_to_bus_map(event)}
        is_completed(event) -> {:engine_completed, completed_to_bus_map(event)}
        is_action_event(event) -> {:engine_action, action_event_to_bus_map(event)}
        is_map(event) -> {:engine_event, event}
        true -> {:engine_event, %{event: inspect(event)}}
      end

    emit_to_bus(state.run_id, event_type, payload, build_event_meta(state))
  end

  defp resume_to_map(nil), do: nil

  defp resume_to_map(%ResumeToken{} = resume) do
    %{
      engine: resume.engine,
      value: resume.value
    }
  end

  defp resume_to_map(%{engine: engine, value: value}) do
    %{
      engine: engine,
      value: value
    }
  end

  defp resume_to_map(_), do: nil

  defp action_to_bus_map(nil), do: nil

  defp action_to_bus_map(action) when is_map(action) do
    %{
      id: Map.get(action, :id),
      kind: Map.get(action, :kind),
      title: Map.get(action, :title),
      detail: Map.get(action, :detail)
    }
  end

  defp started_to_bus_map(ev) when is_map(ev) do
    %{
      engine: Map.get(ev, :engine),
      resume: resume_to_map(Map.get(ev, :resume)),
      title: Map.get(ev, :title),
      meta: Map.get(ev, :meta),
      run_id: Map.get(ev, :run_id),
      session_key: Map.get(ev, :session_key)
    }
  end

  defp action_event_to_bus_map(ev) when is_map(ev) do
    Events.EngineAction.from_map(%{
      engine: Map.get(ev, :engine),
      action: action_to_bus_map(Map.get(ev, :action)),
      phase: Map.get(ev, :phase),
      ok: Map.get(ev, :ok),
      message: Map.get(ev, :message),
      level: Map.get(ev, :level)
    })
  end

  defp completed_to_bus_map(ev) when is_map(ev) do
    Events.Completion.from_map(%{
      engine: Map.get(ev, :engine),
      resume: resume_to_map(Map.get(ev, :resume)),
      ok: Map.get(ev, :ok),
      answer: Map.get(ev, :answer),
      error: Map.get(ev, :error),
      usage: Map.get(ev, :usage),
      meta: Map.get(ev, :meta),
      run_id: Map.get(ev, :run_id),
      session_key: Map.get(ev, :session_key)
    })
  end

  defp register_progress_mapping(%ExecutionRequest{} = request, run_id) do
    meta = request.meta
    keys = progress_mapping_keys(request)
    progress_msg_id = meta && meta[:progress_msg_id]
    status_msg_id = meta && meta[:status_msg_id]

    Enum.each(keys, fn key ->
      if progress_msg_id, do: ProgressStore.put(key, progress_msg_id, run_id)

      if status_msg_id, do: ProgressStore.put(key, status_msg_id, run_id)
    end)
  end

  defp unregister_progress_mapping(%ExecutionRequest{} = request) do
    meta = request.meta
    keys = progress_mapping_keys(request)
    progress_msg_id = meta && meta[:progress_msg_id]
    status_msg_id = meta && meta[:status_msg_id]

    Enum.each(keys, fn key ->
      if progress_msg_id, do: ProgressStore.delete(key, progress_msg_id)
      if status_msg_id, do: ProgressStore.delete(key, status_msg_id)
    end)
  end

  defp progress_mapping_keys(%ExecutionRequest{} = request) do
    if is_binary(request.session_key) and request.session_key != "" do
      [request.session_key]
    else
      []
    end
  end

  defp maybe_update_progress(_state, _render_action), do: :ok

  # Telemetry emission helpers for run lifecycle events
  # Uses LemonCore.Telemetry for consistent event naming across the umbrella

  defp emit_telemetry_start(run_id, meta) do
    LemonGateway.DependencyManager.emit_telemetry(:run_start, [
      run_id,
      %{
        session_key: meta[:session_key],
        engine: meta[:engine],
        origin: meta[:origin]
      }
    ])
  end

  defp emit_telemetry_first_token(run_id, _meta, latency_ms) do
    start_ts_ms = System.system_time(:millisecond) - latency_ms
    LemonGateway.DependencyManager.emit_telemetry(:run_first_token, [run_id, start_ts_ms])
  end

  defp emit_telemetry_stop(run_id, _meta, duration_ms, ok?) do
    LemonGateway.DependencyManager.emit_telemetry(:run_stop, [run_id, duration_ms, ok?])
  end
end
