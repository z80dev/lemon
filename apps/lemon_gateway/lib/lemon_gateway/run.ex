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

  alias LemonGateway.{BindingResolver, ChatState, Event, Store}
  alias LemonGateway.Types.{Job, ResumeToken}

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
    # Acquire engine lock based on thread_key (derived from scope/resume/session_key)
    lock_result = maybe_acquire_lock(job)

    case lock_result do
      {:ok, release_fn} ->
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

  defp session_key_from_job(%Job{scope: %LemonGateway.Types.ChatScope{} = scope}) do
    LemonGateway.Types.Job.Legacy.session_key_from_scope(scope)
  end

  defp session_key_from_job(%Job{scope: scope}) when not is_nil(scope) do
    "scope:#{inspect(scope)}"
  end

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

  # Derive lock key from job - use resume token value if present, otherwise session_key or scope
  defp lock_key_for(%Job{resume: %ResumeToken{value: value}}) when is_binary(value) do
    {:resume, value}
  end

  defp lock_key_for(%Job{session_key: session_key}) when is_binary(session_key) do
    {:session, session_key}
  end

  defp lock_key_for(%Job{scope: scope}) when not is_nil(scope) do
    {:scope, scope}
  end

  defp lock_key_for(_), do: {:default, :global}

  @impl true
  def handle_continue({:start_run, %{job: job}}, state) do
    engine_id = engine_id_for(job)
    engine = LemonGateway.EngineRegistry.get_engine!(engine_id)
    renderer_state = state.renderer.init(%{engine: engine})

    # Resolve cwd from job or scope
    opts =
      cond do
        is_binary(job.cwd) ->
          %{cwd: job.cwd, run_id: state.run_id}

        not is_nil(job.scope) ->
          case BindingResolver.resolve_cwd(job.scope) do
            cwd when is_binary(cwd) -> %{cwd: cwd, run_id: state.run_id}
            _ -> %{run_id: state.run_id}
          end

        true ->
          %{run_id: state.run_id}
      end

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

  @impl true
  def handle_info({:engine_event, run_ref, event}, %{run_ref: run_ref} = state) do
    LemonGateway.Store.append_run_event(run_ref, event)

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
    # Use effective prompt from job
    steer_text = Job.get_prompt(job) || job.text

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
    steer_text = Job.get_prompt(job) || job.text

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
    # Check new field first, then legacy
    cond do
      is_binary(job.engine_id) ->
        job.engine_id

      not is_nil(job.scope) ->
        BindingResolver.resolve_engine(job.scope, job.engine_hint, job.resume)

      not is_nil(job.resume) ->
        job.resume.engine

      is_binary(job.engine_hint) ->
        job.engine_hint

      true ->
        LemonGateway.Config.get(:default_engine) || "lemon"
    end
  end

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
      # Include prompt in summary for complete chat history
      prompt = LemonGateway.Types.Job.get_prompt(state.job) || state.job.prompt

      LemonGateway.Store.finalize_run(state.run_ref, %{
        completed: completed,
        scope: state.job.scope,
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

  # Emit events to the LemonCore.Bus
  defp emit_to_bus(run_id, event_type, payload, extra_meta) do
    # Only emit if LemonCore.Bus is available
    if Code.ensure_loaded?(LemonCore.Bus) do
      topic = "run:#{run_id}"
      # Include run_id in meta, plus any extra metadata
      meta = Map.merge(%{run_id: run_id}, extra_meta)

      event =
        if Code.ensure_loaded?(LemonCore.Event) do
          LemonCore.Event.new(event_type, payload, meta)
        else
          {event_type, payload}
        end

      LemonCore.Bus.broadcast(topic, event)
    end
  rescue
    _ -> :ok
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

  defp maybe_store_chat_state(%Job{} = job, %Event.Completed{resume: %ResumeToken{} = resume}) do
    store_chat_state(job.scope, resume)
    store_chat_state(job.session_key, resume)
  end

  defp maybe_store_chat_state(_job, _completed), do: :ok

  defp store_chat_state(nil, _resume), do: :ok

  defp store_chat_state(key, %ResumeToken{} = resume) do
    chat_state = %ChatState{
      last_engine: resume.engine,
      last_resume_token: resume.value,
      updated_at: System.system_time(:millisecond)
    }

    Store.put_chat_state(key, chat_state)
  end

  defp register_progress_mapping(%Job{meta: meta, scope: scope}, run_pid)
       when not is_nil(scope) do
    progress_msg_id = meta && meta[:progress_msg_id]
    status_msg_id = meta && meta[:status_msg_id]

    if progress_msg_id do
      LemonGateway.Store.put_progress_mapping(scope, progress_msg_id, run_pid)
    end

    if status_msg_id do
      LemonGateway.Store.put_progress_mapping(scope, status_msg_id, run_pid)
    end
  end

  defp register_progress_mapping(_, _), do: :ok

  defp unregister_progress_mapping(%Job{meta: meta, scope: scope}) when not is_nil(scope) do
    progress_msg_id = meta && meta[:progress_msg_id]
    status_msg_id = meta && meta[:status_msg_id]

    if progress_msg_id do
      LemonGateway.Store.delete_progress_mapping(scope, progress_msg_id)
    end

    if status_msg_id do
      LemonGateway.Store.delete_progress_mapping(scope, status_msg_id)
    end
  end

  defp unregister_progress_mapping(_), do: :ok

  defp maybe_update_progress(%{job: %Job{} = job} = state, {:render, %{text: text}})
       when is_binary(text) do
    with %LemonGateway.Types.ChatScope{transport: :telegram, chat_id: chat_id} <- job.scope,
         progress_msg_id when not is_nil(progress_msg_id) <-
           job.meta && job.meta[:progress_msg_id],
         true <- is_pid(Process.whereis(LemonGateway.Telegram.Outbox)) do
      engine = if is_atom(state.engine), do: state.engine, else: nil
      key = {chat_id, progress_msg_id, :edit}

      LemonGateway.Telegram.Outbox.enqueue(
        key,
        0,
        {:edit, chat_id, progress_msg_id, %{text: text, engine: engine}}
      )
    else
      _ -> :ok
    end
  end

  defp maybe_update_progress(_state, _render_action), do: :ok

  # Telemetry emission helpers for run lifecycle events
  # Uses LemonCore.Telemetry for consistent event naming across the umbrella

  defp emit_telemetry_start(run_id, meta) do
    # Emit both legacy [:lemon_gateway, :run, :start] and new [:lemon, :run, :start]
    # for backwards compatibility during migration
    LemonCore.Telemetry.emit(
      [:lemon_gateway, :run, :start],
      %{system_time: System.system_time()},
      %{
        run_id: run_id,
        session_key: meta[:session_key],
        engine: meta[:engine],
        origin: meta[:origin]
      }
    )

    # New canonical telemetry via LemonCore.Telemetry
    if Code.ensure_loaded?(LemonCore.Telemetry) do
      LemonCore.Telemetry.run_start(run_id, %{
        session_key: meta[:session_key],
        engine: meta[:engine],
        origin: meta[:origin]
      })
    end
  end

  defp emit_telemetry_first_token(run_id, meta, latency_ms) do
    # Legacy event
    LemonCore.Telemetry.emit(
      [:lemon_gateway, :run, :first_token],
      %{latency_ms: latency_ms, system_time: System.system_time()},
      %{
        run_id: run_id,
        session_key: meta[:session_key],
        engine: meta[:engine]
      }
    )

    # New canonical telemetry
    if Code.ensure_loaded?(LemonCore.Telemetry) do
      # Calculate start time from latency
      start_ts_ms = System.system_time(:millisecond) - latency_ms
      LemonCore.Telemetry.run_first_token(run_id, start_ts_ms)
    end
  end

  defp emit_telemetry_stop(run_id, meta, duration_ms, ok?) do
    # Legacy event
    LemonCore.Telemetry.emit(
      [:lemon_gateway, :run, :stop],
      %{duration_ms: duration_ms, system_time: System.system_time()},
      %{
        run_id: run_id,
        session_key: meta[:session_key],
        engine: meta[:engine],
        ok: ok?
      }
    )

    # New canonical telemetry
    if Code.ensure_loaded?(LemonCore.Telemetry) do
      LemonCore.Telemetry.run_stop(run_id, duration_ms, ok?)
    end
  end
end
