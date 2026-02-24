defmodule LemonGateway.Run do
  @moduledoc """
  Transport-agnostic run execution.

  Run is responsible for:
  - Executing engine runs
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

  alias LemonGateway.{ChatState, Cwd, Event, Store}
  alias LemonGateway.Types.{Job, ResumeToken}

  @max_logged_error_bytes 4_096
  @context_overflow_error_markers [
    "context_length_exceeded",
    "context length exceeded",
    "input exceeds the context window",
    "context window"
  ]

  def start_link(args) do
    # Allow cancel-by-run-id (used by router/control-plane) by registering the run
    # process under LemonGateway.RunRegistry when job.run_id is present.
    name =
      case args do
        %{job: %Job{run_id: run_id}} when is_binary(run_id) and run_id != "" ->
          {:via, Registry, {LemonGateway.RunRegistry, run_id}}

        _ ->
          nil
      end

    opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, args, opts)
  end

  @impl true
  def init(%{job: %Job{} = job, slot_ref: slot_ref, worker_pid: worker_pid} = args) do
    # Acquire engine lock based on thread_key (derived from resume/session_key)
    lock_result = maybe_acquire_lock(job)

    case lock_result do
      {:ok, release_fn} ->
        Logger.debug(
          "Gateway run init lock acquired run_id=#{inspect(job.run_id)} session_key=#{inspect(job.session_key)} " <>
            "engine=#{inspect(engine_id_for(job))} queue_mode=#{inspect(job.queue_mode)}"
        )

        # Generate run_id if not provided
        run_id = job.run_id || generate_run_id()
        session_key = job.session_key || session_key_from_job(job)

        state = %{
          submitted_job: job,
          job: %{job | run_id: run_id, session_key: session_key},
          run_id: run_id,
          session_key: session_key,
          slot_ref: slot_ref,
          worker_pid: worker_pid,
          engine: nil,
          run_ref: nil,
          cancel_ctx: nil,
          renderer: LemonGateway.Renderers.Basic,
          renderer_state: nil,
          completed: false,
          lock_release_fn: release_fn,
          last_resume: job.resume,
          delta_seq: 0,
          start_ts_ms: System.system_time(:millisecond),
          # Accumulated answer text for final event
          accumulated_text: "",
          # Track whether first token telemetry has been emitted
          first_token_emitted: false
        }

        {:ok, state, {:continue, {:start_run, args}}}

      {:error, :timeout} ->
        # Lock acquisition timed out - fail fast
        Logger.warning(
          "Gateway run lock timeout run_id=#{inspect(job.run_id)} session_key=#{inspect(job.session_key)} " <>
            "engine=#{inspect(engine_id_for(job))}"
        )

        run_id = job.run_id || generate_run_id()

        completed = %Event.Completed{
          engine: engine_id_for(job),
          ok: false,
          error: :lock_timeout,
          answer: "",
          run_id: run_id,
          session_key: job.session_key
        }

        # Emit completion event to bus (include session_key and origin in meta)
        meta = %{session_key: job.session_key, origin: job.meta && job.meta[:origin]}

        # Bus payloads must be plain maps; do not leak LemonGateway.Event structs.
        emit_to_bus(
          run_id,
          :run_completed,
          %{completed: completed_to_map(completed), duration_ms: nil},
          meta
        )

        # Notify worker and release slot synchronously before stopping
        LemonGateway.Scheduler.release_slot(slot_ref)
        send(worker_pid, {:run_complete, self(), completed})

        notify_pid = job.meta && job.meta[:notify_pid]

        if is_pid(notify_pid) do
          send(notify_pid, {:lemon_gateway_run_completed, job, completed})
        end

        {:stop, :normal}
    end
  end

  defp generate_run_id do
    "run_#{UUID.uuid4()}"
  end

  defp session_key_from_job(%Job{session_key: key}) when is_binary(key), do: key

  defp session_key_from_job(_), do: "default"

  defp maybe_acquire_lock(job) do
    require_lock = LemonGateway.Config.get(:require_engine_lock)
    timeout_ms = LemonGateway.Config.get(:engine_lock_timeout_ms) || 60_000

    if require_lock do
      thread_key = lock_key_for(job)
      LemonGateway.EngineLock.acquire(thread_key, timeout_ms)
    else
      # No lock required - return a no-op release function
      {:ok, fn -> :ok end}
    end
  end

  # Derive lock key from job - use resume token value if present, otherwise session_key.
  defp lock_key_for(%Job{resume: %ResumeToken{value: value}}) when is_binary(value) do
    {:resume, value}
  end

  defp lock_key_for(%Job{session_key: session_key}) when is_binary(session_key) do
    {:session, session_key}
  end

  defp lock_key_for(_), do: {:default, :global}

  @impl true
  def handle_continue({:start_run, %{job: job}}, state) do
    engine_id = engine_id_for(job)
    engine = resolve_engine(engine_id)

    Logger.debug(
      "Gateway run start run_id=#{inspect(state.run_id)} session_key=#{inspect(state.session_key)} " <>
        "engine=#{inspect(engine_id)} resume=#{inspect(job.resume)} cwd=#{inspect(job.cwd)}"
    )

    if is_nil(engine) do
      completed = %Event.Completed{
        engine: engine_id,
        ok: false,
        # Keep this stringy: the Basic renderer calls to_string/1 on error.
        error: "unknown engine id: #{engine_id}",
        answer: "",
        run_id: state.run_id,
        session_key: state.session_key
      }

      renderer_state = state.renderer.init(%{engine: nil})
      {renderer_state, render_action} = state.renderer.apply_event(renderer_state, completed)
      maybe_update_progress(state, render_action)
      state = %{state | renderer_state: renderer_state}

      finalize(state, completed)
      {:stop, :normal, state}
    else
      renderer_state = state.renderer.init(%{engine: engine})

      # Resolve cwd from explicit job value; otherwise use gateway default/home.
      cwd =
        cond do
          is_binary(job.cwd) and String.trim(job.cwd) != "" ->
            Path.expand(job.cwd)

          true ->
            Cwd.default_cwd()
        end

      opts = %{cwd: cwd, run_id: state.run_id}

      # Emit run started event to bus
      emit_to_bus(
        state.run_id,
        :run_started,
        %{
          run_id: state.run_id,
          session_key: state.session_key,
          engine: engine_id
        },
        build_event_meta(state)
      )

      # Emit run_start telemetry
      emit_telemetry_start(state.run_id, %{
        session_key: state.session_key,
        engine: engine_id,
        origin: get_in(state.job.meta || %{}, [:origin])
      })

      case engine.start_run(state.job, opts, self()) do
        {:ok, run_ref, cancel_ctx} ->
          Logger.debug(
            "Gateway run engine started run_id=#{inspect(state.run_id)} run_ref=#{inspect(run_ref)} " <>
              "engine=#{inspect(engine_id)}"
          )

          register_progress_mapping(job, self())

          {:noreply,
           %{
             state
             | engine: engine,
               run_ref: run_ref,
               cancel_ctx: cancel_ctx,
               renderer_state: renderer_state
           }}

        {:error, reason} ->
          Logger.warning(
            "Gateway run engine start failed run_id=#{inspect(state.run_id)} engine=#{inspect(engine_id)} " <>
              "reason=#{inspect(reason)}"
          )

          completed = %Event.Completed{
            engine: engine_id,
            ok: false,
            error: reason,
            answer: "",
            run_id: state.run_id,
            session_key: state.session_key
          }

          {renderer_state, render_action} = state.renderer.apply_event(renderer_state, completed)
          maybe_update_progress(state, render_action)
          state = %{state | engine: engine, renderer_state: renderer_state}

          finalize(state, completed)
          {:stop, :normal, state}
      end
    end
  end

  defp resolve_engine(engine_id) when is_binary(engine_id) do
    LemonGateway.EngineRegistry.get_engine(engine_id) || resolve_engine_by_prefix(engine_id)
  end

  defp resolve_engine(_), do: nil

  # Accept composite IDs like "claude:claude-3-opus" by falling back to "claude".
  defp resolve_engine_by_prefix(engine_id) do
    case String.split(engine_id, ":", parts: 2) do
      [prefix, _rest] when is_binary(prefix) and byte_size(prefix) > 0 ->
        LemonGateway.EngineRegistry.get_engine(prefix)

      _ ->
        nil
    end
  end

  @impl true
  def handle_info({:engine_event, run_ref, event}, %{run_ref: run_ref} = state) do
    LemonGateway.Store.append_run_event(run_ref, event)

    case event do
      %Event.Started{} ->
        Logger.debug(
          "Gateway run engine_event started run_id=#{inspect(state.run_id)} session_key=#{inspect(state.session_key)}"
        )

      %Event.Completed{} = ev ->
        Logger.info(
          "Gateway run engine_event completed run_id=#{inspect(state.run_id)} session_key=#{inspect(state.session_key)} " <>
            "ok=#{inspect(ev.ok)} error=#{inspect(ev.error)} answer_bytes=#{byte_size(ev.answer || "")}"
        )

      %Event.ActionEvent{} = ev ->
        Logger.debug(
          "Gateway run action run_id=#{inspect(state.run_id)} phase=#{inspect(ev.phase)} kind=#{inspect(ev.action && ev.action.kind)} " <>
            action_event_ok_fragment(ev.ok)
        )

      _ ->
        :ok
    end

    # Emit event to bus
    emit_engine_event_to_bus(state, event)

    # Update renderer state for answer tracking (but no rendering)
    {renderer_state, render_action} = state.renderer.apply_event(state.renderer_state, event)
    state = %{state | renderer_state: renderer_state}
    maybe_update_progress(state, render_action)

    case event do
      %Event.Started{resume: resume} ->
        # Note: Do NOT store chat state here. Storing on Started allows new messages
        # to auto-resume to this token while the run is still active, creating
        # concurrent runs. Chat state is stored in finalize/2 after Completed.
        {:noreply, %{state | last_resume: resume || state.last_resume}}

      %Event.Completed{resume: resume} = completed ->
        state = %{state | last_resume: resume || state.last_resume}
        finalize(state, completed)
        {:stop, :normal, state}

      _ ->
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
            engine: state.engine && state.engine.id()
          },
          latency_ms
        )

        %{state | first_token_emitted: true}
      else
        state
      end

    delta = Event.Delta.new(state.run_id, new_seq, text, %{session_key: state.session_key})

    # Emit delta to bus (subscribers like StreamCoalescer will handle channel delivery)
    # Bus payloads must be plain maps; do not leak LemonGateway.Event structs.
    emit_to_bus(
      state.run_id,
      :delta,
      %{
        run_id: delta.run_id,
        ts_ms: delta.ts_ms,
        seq: delta.seq,
        text: delta.text,
        meta: delta.meta
      },
      build_event_meta(state)
    )

    # Accumulate text for final answer
    {:noreply, %{state | delta_seq: new_seq, accumulated_text: state.accumulated_text <> text}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast({:steer, %Job{} = job, worker_pid}, state) do
    steer_text = job.prompt || ""

    cond do
      # Run already completed - reject steer
      state.completed ->
        send(worker_pid, {:steer_rejected, job})
        {:noreply, state}

      # Engine not yet initialized - reject steer
      is_nil(state.engine) or is_nil(state.cancel_ctx) ->
        send(worker_pid, {:steer_rejected, job})
        {:noreply, state}

      # Engine doesn't support steering - reject steer
      not state.engine.supports_steer?() ->
        send(worker_pid, {:steer_rejected, job})
        {:noreply, state}

      # Engine supports steering - attempt to steer
      true ->
        case state.engine.steer(state.cancel_ctx, steer_text) do
          :ok ->
            # Steering succeeded - notify worker so it can clear pending steer
            send(worker_pid, {:steer_accepted, job})
            {:noreply, state}

          {:error, _reason} ->
            # Steering failed - reject so it can be re-enqueued as followup
            send(worker_pid, {:steer_rejected, job})
            {:noreply, state}
        end
    end
  end

  def handle_cast({:steer_backlog, %Job{} = job, worker_pid}, state) do
    steer_text = job.prompt || ""

    cond do
      # Run already completed - reject steer_backlog
      state.completed ->
        send(worker_pid, {:steer_backlog_rejected, job})
        {:noreply, state}

      # Engine not yet initialized - reject steer_backlog
      is_nil(state.engine) or is_nil(state.cancel_ctx) ->
        send(worker_pid, {:steer_backlog_rejected, job})
        {:noreply, state}

      # Engine doesn't support steering - reject steer_backlog
      not state.engine.supports_steer?() ->
        send(worker_pid, {:steer_backlog_rejected, job})
        {:noreply, state}

      # Engine supports steering - attempt to steer
      true ->
        case state.engine.steer(state.cancel_ctx, steer_text) do
          :ok ->
            # Steering succeeded - notify worker so it can clear pending steer
            send(worker_pid, {:steer_backlog_accepted, job})
            {:noreply, state}

          {:error, _reason} ->
            # Steering failed - reject so it can be re-enqueued as collect
            send(worker_pid, {:steer_backlog_rejected, job})
            {:noreply, state}
        end
    end
  end

  @impl true
  def handle_cast({:cancel, reason}, state) do
    if state.completed do
      {:noreply, state}
    else
      Logger.warning(
        "Gateway run cancel run_id=#{inspect(state.run_id)} session_key=#{inspect(state.session_key)} reason=#{inspect(reason)}"
      )

      if state.engine && state.cancel_ctx do
        _ = state.engine.cancel(state.cancel_ctx)
      end

      resume = state.last_resume || state.job.resume

      completed = %Event.Completed{
        engine: engine_id_for(state.job),
        resume: resume,
        ok: false,
        error: reason,
        answer: "",
        run_id: state.run_id,
        session_key: state.session_key
      }

      finalize(state, completed)
      {:stop, :normal, %{state | completed: true}}
    end
  end

  defp engine_id_for(%Job{} = job) do
    cond do
      is_binary(job.engine_id) ->
        job.engine_id

      not is_nil(job.resume) ->
        job.resume.engine

      true ->
        LemonGateway.Config.get(:default_engine) || "lemon"
    end
  end

  defp action_event_ok_fragment(ok?) when is_boolean(ok?), do: "ok=#{inspect(ok?)}"
  defp action_event_ok_fragment(_), do: "ok=unknown"

  defp finalize(state, %Event.Completed{} = completed) do
    state = %{state | completed: true}

    # Release engine lock first (if acquired)
    if is_function(state.lock_release_fn) do
      state.lock_release_fn.()
    end

    # Add run_id, session_key, and accumulated answer to completed event
    completed = %{
      completed
      | run_id: state.run_id,
        session_key: state.session_key,
        answer: if(completed.answer == "", do: state.accumulated_text, else: completed.answer)
    }

    Logger.info(
      "Gateway run finalize run_id=#{inspect(state.run_id)} session_key=#{inspect(state.session_key)} " <>
        "engine=#{inspect(engine_id_for(state.job))} ok=#{inspect(completed.ok)} " <>
        "error=#{inspect(completed.error)} answer_bytes=#{byte_size(completed.answer || "")}"
    )

    if completed.ok != true do
      log_run_failure(state, completed)
    end

    maybe_clear_chat_state_on_context_overflow(state.session_key, completed)

    # Emit completion event to bus (channel delivery handled by subscribers)
    duration_ms = System.system_time(:millisecond) - state.start_ts_ms

    # Emit run_stop telemetry
    emit_telemetry_stop(
      state.run_id,
      %{
        session_key: state.session_key,
        engine: engine_id_for(state.job)
      },
      duration_ms,
      completed.ok
    )

    emit_to_bus(
      state.run_id,
      :run_completed,
      %{
        completed: completed_to_map(completed),
        duration_ms: duration_ms
      },
      build_event_meta(state)
    )

    if state.run_ref do
      prompt = state.job.prompt

      LemonGateway.Store.finalize_run(state.run_ref, %{
        completed: completed,
        session_key: state.session_key,
        run_id: state.run_id,
        prompt: prompt,
        duration_ms: duration_ms,
        engine: engine_id_for(state.job),
        meta: state.job.meta
      })
    end

    LemonGateway.Scheduler.release_slot(state.slot_ref)
    send(state.worker_pid, {:run_complete, self(), completed})

    notify_pid = state.job.meta && state.job.meta[:notify_pid]

    if is_pid(notify_pid) do
      notify_job = Map.get(state, :submitted_job, state.job)
      send(notify_pid, {:lemon_gateway_run_completed, notify_job, completed})
    end

    maybe_store_chat_state(state.job, completed)
    unregister_progress_mapping(state.job)
  end

  defp log_run_failure(state, %Event.Completed{} = completed) do
    error_text = format_error_for_log(completed.error)
    engine_id = engine_id_for(state.job)

    level =
      if completed.error in [:user_requested, :interrupted, :new_session],
        do: :warning,
        else: :error

    message =
      "Gateway run failed " <>
        "run_id=#{inspect(completed.run_id)} " <>
        "session_key=#{inspect(completed.session_key)} " <>
        "engine=#{inspect(engine_id)} " <>
        "error=#{error_text} " <>
        "answer_bytes=#{byte_size(completed.answer || "")}"

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

    # Extract origin from job meta
    origin = get_in(state.job.meta || %{}, [:origin])
    meta = if origin, do: Map.put(meta, :origin, origin), else: meta

    meta
  end

  defp emit_engine_event_to_bus(state, event) do
    # Bus payloads must be plain maps; do not leak LemonGateway.Event structs.
    {event_type, payload} =
      case event do
        %Event.Started{} = ev -> {:engine_started, started_to_map(ev)}
        %Event.Completed{} = ev -> {:engine_completed, completed_to_map(ev)}
        %Event.ActionEvent{} = ev -> {:engine_action, action_event_to_map(ev)}
        ev when is_map(ev) -> {:engine_event, ev}
        other -> {:engine_event, %{event: inspect(other)}}
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

  defp action_to_map(nil), do: nil

  defp action_to_map(action) when is_map(action) do
    %{
      id: Map.get(action, :id),
      kind: Map.get(action, :kind),
      title: Map.get(action, :title),
      detail: Map.get(action, :detail)
    }
  end

  defp started_to_map(%Event.Started{} = ev) do
    %{
      engine: ev.engine,
      resume: resume_to_map(ev.resume),
      title: ev.title,
      meta: ev.meta,
      run_id: ev.run_id,
      session_key: ev.session_key
    }
  end

  defp action_event_to_map(%Event.ActionEvent{} = ev) do
    %{
      engine: ev.engine,
      action: action_to_map(ev.action),
      phase: ev.phase,
      ok: ev.ok,
      message: ev.message,
      level: ev.level
    }
  end

  defp completed_to_map(%Event.Completed{} = ev) do
    %{
      engine: ev.engine,
      resume: resume_to_map(ev.resume),
      ok: ev.ok,
      answer: ev.answer,
      error: ev.error,
      usage: ev.usage,
      meta: ev.meta,
      run_id: ev.run_id,
      session_key: ev.session_key
    }
  end

  defp maybe_store_chat_state(
         %Job{} = job,
         %Event.Completed{resume: %ResumeToken{} = resume} = completed
       ) do
    if context_length_exceeded_error?(completed.error) do
      :ok
    else
      store_chat_state(job.session_key, resume)
    end
  end

  defp maybe_store_chat_state(_job, _completed), do: :ok

  defp maybe_clear_chat_state_on_context_overflow(
         session_key,
         %Event.Completed{ok: ok, error: error, run_id: run_id}
       )
       when is_binary(session_key) do
    if ok != true and context_length_exceeded_error?(error) do
      Store.delete_chat_state(session_key)

      Logger.warning(
        "Gateway run reset chat state after context overflow run_id=#{inspect(run_id)} " <>
          "session_key=#{inspect(session_key)} error=#{inspect(error)}"
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  defp maybe_clear_chat_state_on_context_overflow(_session_key, _completed), do: :ok

  defp context_length_exceeded_error?(nil), do: false

  defp context_length_exceeded_error?(error) do
    text =
      cond do
        is_binary(error) -> error
        is_atom(error) -> Atom.to_string(error)
        true -> inspect(error, limit: 200, printable_limit: 8_000)
      end
      |> String.downcase()

    Enum.any?(@context_overflow_error_markers, &String.contains?(text, &1))
  rescue
    _ -> false
  end

  defp store_chat_state(nil, _resume), do: :ok

  defp store_chat_state(key, %ResumeToken{} = resume) do
    chat_state = %ChatState{
      last_engine: resume.engine,
      last_resume_token: resume.value,
      updated_at: System.system_time(:millisecond)
    }

    Store.put_chat_state(key, chat_state)
  end

  defp register_progress_mapping(%Job{} = job, run_pid) do
    meta = job.meta
    keys = progress_mapping_keys(job)
    progress_msg_id = meta && meta[:progress_msg_id]
    status_msg_id = meta && meta[:status_msg_id]

    Enum.each(keys, fn key ->
      if progress_msg_id,
        do: LemonGateway.Store.put_progress_mapping(key, progress_msg_id, run_pid)

      if status_msg_id, do: LemonGateway.Store.put_progress_mapping(key, status_msg_id, run_pid)
    end)
  end

  defp unregister_progress_mapping(%Job{} = job) do
    meta = job.meta
    keys = progress_mapping_keys(job)
    progress_msg_id = meta && meta[:progress_msg_id]
    status_msg_id = meta && meta[:status_msg_id]

    Enum.each(keys, fn key ->
      if progress_msg_id, do: LemonGateway.Store.delete_progress_mapping(key, progress_msg_id)
      if status_msg_id, do: LemonGateway.Store.delete_progress_mapping(key, status_msg_id)
    end)
  end

  defp progress_mapping_keys(%Job{} = job) do
    if is_binary(job.session_key) and job.session_key != "" do
      [job.session_key]
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
