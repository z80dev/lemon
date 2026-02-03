defmodule LemonGateway.Run do
  @moduledoc false
  use GenServer

  alias LemonGateway.{BindingResolver, ChatState, Event, Store}
  alias LemonGateway.Types.{Job, ResumeToken}

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl true
  def init(%{job: %Job{} = job, slot_ref: slot_ref, worker_pid: worker_pid} = args) do
    # Acquire engine lock based on thread_key (derived from scope/resume)
    lock_result = maybe_acquire_lock(job)

    case lock_result do
      {:ok, release_fn} ->
        state = %{
          job: job,
          slot_ref: slot_ref,
          worker_pid: worker_pid,
          engine: nil,
          run_ref: nil,
          cancel_ctx: nil,
          renderer: LemonGateway.Renderers.Basic,
          renderer_state: nil,
          completed: false,
          sent_final: false,
          lock_release_fn: release_fn,
          last_resume: job.resume
        }

        {:ok, state, {:continue, {:start_run, args}}}

      {:error, :timeout} ->
        # Lock acquisition timed out - fail fast
        completed = %Event.Completed{
          engine: engine_id_for(job),
          ok: false,
          error: :lock_timeout,
          answer: ""
        }

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

  # Derive lock key from job - use resume token value if present, otherwise scope
  defp lock_key_for(%Job{resume: %LemonGateway.Types.ResumeToken{value: value}})
       when is_binary(value) do
    {:resume, value}
  end

  defp lock_key_for(%Job{scope: scope}) do
    {:scope, scope}
  end

  @impl true
  def handle_continue({:start_run, %{job: job}}, state) do
    engine_id = engine_id_for(job)
    engine = LemonGateway.EngineRegistry.get_engine!(engine_id)
    renderer_state = state.renderer.init(%{engine: engine})

    opts =
      case BindingResolver.resolve_cwd(job.scope) do
        cwd when is_binary(cwd) -> %{cwd: cwd}
        _ -> %{}
      end

    case engine.start_run(job, opts, self()) do
      {:ok, run_ref, cancel_ctx} ->
        register_progress_mapping(job, self())
        {:noreply,
         %{state | engine: engine, run_ref: run_ref, cancel_ctx: cancel_ctx, renderer_state: renderer_state}}

      {:error, reason} ->
        completed = %Event.Completed{engine: engine_id, ok: false, error: reason, answer: ""}
        {renderer_state, render_action} = state.renderer.apply_event(renderer_state, completed)
        state = %{state | engine: engine, renderer_state: renderer_state}

        state =
          case render_action do
          {:render, %{text: text, status: status}} ->
              maybe_render(state, text, status)

          :unchanged ->
              state
          end

        finalize(state, completed)
        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_info({:engine_event, run_ref, event}, %{run_ref: run_ref} = state) do
    LemonGateway.Store.append_run_event(run_ref, event)

    {renderer_state, render_action} = state.renderer.apply_event(state.renderer_state, event)
    state = %{state | renderer_state: renderer_state}

    state =
      case render_action do
      {:render, %{text: text, status: status}} ->
          maybe_render(state, text, status)

      :unchanged ->
          state
      end

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

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast({:steer, %Job{} = job, worker_pid}, state) do
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
        case state.engine.steer(state.cancel_ctx, job.text) do
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
        case state.engine.steer(state.cancel_ctx, job.text) do
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
        answer: ""
      }
      finalize(state, completed)
      {:stop, :normal, %{state | completed: true}}
    end
  end

  defp engine_id_for(%Job{} = job) do
    BindingResolver.resolve_engine(job.scope, job.engine_hint, job.resume)
  end

  defp finalize(state, %Event.Completed{} = completed) do
    state = %{state | completed: true}

    # Release engine lock first (if acquired)
    if is_function(state.lock_release_fn) do
      state.lock_release_fn.()
    end

    if state.run_ref do
      LemonGateway.Store.finalize_run(state.run_ref, %{completed: completed, scope: state.job.scope})
    end
    LemonGateway.Scheduler.release_slot(state.slot_ref)
    send(state.worker_pid, {:run_complete, self(), completed})

    notify_pid = state.job.meta && state.job.meta[:notify_pid]

    if is_pid(notify_pid) do
      send(notify_pid, {:lemon_gateway_run_completed, state.job, completed})
    end

    if not state.sent_final do
      _state = maybe_render_from_finalize(state, completed)
    end

    maybe_store_chat_state(state.job, completed)
    unregister_progress_mapping(state.job)
  end

  defp maybe_store_chat_state(%Job{scope: scope}, %Event.Started{resume: %ResumeToken{} = resume}) do
    chat_state = %ChatState{
      last_engine: resume.engine,
      last_resume_token: resume.value,
      updated_at: System.system_time(:millisecond)
    }

    Store.put_chat_state(scope, chat_state)
  end

  defp maybe_store_chat_state(%Job{scope: scope}, %Event.Completed{resume: %ResumeToken{} = resume}) do
    chat_state = %ChatState{
      last_engine: resume.engine,
      last_resume_token: resume.value,
      updated_at: System.system_time(:millisecond)
    }

    Store.put_chat_state(scope, chat_state)
  end

  defp maybe_store_chat_state(_job, _completed), do: :ok

  defp maybe_render(state, text, status) do
    meta = state.job.meta || %{}
    chat_id = meta[:chat_id]
    user_msg_id = meta[:user_msg_id]
    progress_msg_id = meta[:progress_msg_id]

    cond do
      status in [:done, :error, :cancelled] && chat_id && progress_msg_id ->
        LemonGateway.Telegram.Outbox.enqueue(
          {chat_id, progress_msg_id, :edit},
          0,
          {:edit, chat_id, progress_msg_id, %{text: text, engine: state.engine}}
        )

        %{state | sent_final: true}

      status in [:done, :error, :cancelled] && chat_id ->
        LemonGateway.Telegram.Outbox.enqueue(
          {chat_id, user_msg_id, :send},
          0,
          {:send, chat_id, %{text: text, reply_to_message_id: user_msg_id, engine: state.engine}}
        )

        %{state | sent_final: true}

      status == :running && chat_id && progress_msg_id ->
        # Use a stable key based on chat_id and progress_msg_id so Outbox can coalesce rapid updates
        LemonGateway.Telegram.Outbox.enqueue(
          {chat_id, progress_msg_id, :edit},
          0,
          {:edit, chat_id, progress_msg_id, %{text: text, engine: state.engine}}
        )

        state

      true ->
        state
    end
  end

  defp maybe_render_from_finalize(state, %Event.Completed{} = completed) do
    renderer_state =
      case state.renderer_state do
        nil ->
          engine = state.engine || LemonGateway.EngineRegistry.get_engine!(completed.engine)
          state.renderer.init(%{engine: engine})

        existing ->
          existing
      end

    {renderer_state, render_action} = state.renderer.apply_event(renderer_state, completed)
    state = %{state | renderer_state: renderer_state}

    case render_action do
      {:render, %{text: text, status: status}} ->
        maybe_render(state, text, status)

      :unchanged ->
        maybe_render_fallback(state, renderer_state)
    end
  end

  defp maybe_render_fallback(state, renderer_state) do
    text = Map.get(renderer_state, :last_text)
    status = Map.get(renderer_state, :last_status)

    if is_binary(text) and status in [:done, :error, :cancelled] do
      maybe_render(state, text, status)
    else
      state
    end
  end

  defp register_progress_mapping(%Job{meta: meta, scope: scope}, run_pid) do
    progress_msg_id = meta && meta[:progress_msg_id]

    if progress_msg_id do
      LemonGateway.Store.put_progress_mapping(scope, progress_msg_id, run_pid)
    end
  end

  defp unregister_progress_mapping(%Job{meta: meta, scope: scope}) do
    progress_msg_id = meta && meta[:progress_msg_id]

    if progress_msg_id do
      LemonGateway.Store.delete_progress_mapping(scope, progress_msg_id)
    end
  end
end
