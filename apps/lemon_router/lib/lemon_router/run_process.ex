defmodule LemonRouter.RunProcess do
  @moduledoc """
  Process that owns a single run lifecycle.

  Each RunProcess:
  - Owns a run_id
  - Manages abort state
  - Subscribes to Bus for run events
  - Maintains metadata snapshot
  - Emits router-level events
  """

  use GenServer

  require Logger

  alias LemonCore.Bus

  @default_auto_send_generated_max_files 3
  @default_max_download_bytes 50 * 1024 * 1024
  @gateway_submit_retry_base_ms 100
  @gateway_submit_retry_max_ms 2_000
  @session_register_retry_ms 25
  @session_register_retry_max_ms 250

  def start_link(opts) do
    run_id = opts[:run_id]
    GenServer.start_link(__MODULE__, opts, name: via_tuple(run_id))
  end

  def child_spec(opts) do
    run_id = opts[:run_id]

    %{
      id: {__MODULE__, run_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5000
    }
  end

  defp via_tuple(run_id) do
    {:via, Registry, {LemonRouter.RunRegistry, run_id}}
  end

  @doc """
  Abort this run process.
  """
  @spec abort(pid() | binary(), reason :: term()) :: :ok
  def abort(pid_or_run_id, reason \\ :user_requested)

  def abort(pid_or_run_id, reason) when is_pid(pid_or_run_id) do
    GenServer.cast(pid_or_run_id, {:abort, reason})
  end

  def abort(pid_or_run_id, reason) when is_binary(pid_or_run_id) do
    case Registry.lookup(LemonRouter.RunRegistry, pid_or_run_id) do
      [{pid, _}] -> abort(pid, reason)
      _ -> :ok
    end
  end

  @impl true
  def init(opts) do
    run_id = opts[:run_id]
    session_key = opts[:session_key]
    job = opts[:job]
    gateway_scheduler = opts[:gateway_scheduler] || LemonGateway.Scheduler

    # For tests and partial-boot scenarios, allow skipping gateway submission.
    submit_to_gateway? =
      case opts[:submit_to_gateway?] do
        nil -> true
        other -> other
      end

    # Subscribe to run events
    Bus.subscribe(Bus.run_topic(run_id))

    state = %{
      run_id: run_id,
      session_key: session_key,
      job: job,
      start_ts_ms: LemonCore.Clock.now_ms(),
      aborted: false,
      completed: false,
      saw_delta: false,
      session_registered?: false,
      pending_run_started_event: nil,
      session_register_retry_ref: nil,
      session_register_retry_attempt: 0,
      submit_to_gateway?: submit_to_gateway?,
      gateway_scheduler: gateway_scheduler,
      gateway_submit_attempt: 0,
      gateway_submitted?: false,
      gateway_run_pid: nil,
      gateway_run_ref: nil,
      generated_image_paths: [],
      requested_send_files: []
    }

    # Submit to gateway
    if submit_to_gateway? do
      send(self(), :submit_to_gateway)
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:submit_to_gateway, state) do
    cond do
      state.gateway_submitted? or state.aborted or state.completed ->
        {:noreply, state}

      scheduler_available?(state.gateway_scheduler) ->
        state.gateway_scheduler.submit(state.job)
        {:noreply, %{state | gateway_submitted?: true, gateway_submit_attempt: 0}}

      true ->
        delay_ms = gateway_submit_retry_delay_ms(state.gateway_submit_attempt)
        Process.send_after(self(), :submit_to_gateway, delay_ms)

        Logger.warning(
          "Gateway scheduler unavailable; retrying submit for run_id=#{inspect(state.run_id)} " <>
            "in #{delay_ms}ms (attempt=#{state.gateway_submit_attempt + 1})"
        )

        {:noreply, %{state | gateway_submit_attempt: state.gateway_submit_attempt + 1}}
    end
  end

  # Handle run events from Bus
  def handle_info(%LemonCore.Event{type: :run_started} = event, state) do
    # Mark this run as the currently active run for the session.
    #
    # Note: strict single-flight is enforced by LemonGateway.ThreadWorker, which
    # serializes runs per session_key (scheduler thread_key is `{:session, session_key}`).
    if state.session_registered? do
      Bus.broadcast(Bus.session_topic(state.session_key), event)
      {:noreply, state}
    else
      case Registry.register(LemonRouter.SessionRegistry, state.session_key, %{
             run_id: state.run_id
           }) do
        {:ok, _pid} ->
          Bus.broadcast(Bus.session_topic(state.session_key), event)
          state = %{state | session_registered?: true} |> maybe_monitor_gateway_run()
          {:noreply, state}

        {:error, {:already_registered, _pid}} ->
          # We expect the gateway to serialize runs per session_key. This can still happen
          # briefly when the previous RunProcess is finalizing output and hasn't torn down
          # yet. Do NOT cancel the run (that drops a user message); instead, retry
          # registration until the old entry is released.
          {active_pid, active_run_id} = lookup_active_session(state.session_key)

          Logger.debug(
            "SessionRegistry already has an active run for session_key=#{inspect(state.session_key)}; " <>
              "active_run_id=#{inspect(active_run_id)} active_pid=#{inspect(active_pid)}; " <>
              "deferring registration for run_id=#{inspect(state.run_id)}"
          )

          state =
            state
            |> maybe_monitor_gateway_run()
            |> put_pending_run_started(event)
            |> schedule_session_register_retry()

          {:noreply, state}
      end
    end
  end

  def handle_info(%LemonCore.Event{type: :run_completed} = event, state) do
    Logger.debug("RunProcess #{state.run_id} completed")

    # Free the session key ASAP so the next queued run can become active without
    # tripping the SessionRegistry single-flight guard.
    _ = Registry.unregister(LemonRouter.SessionRegistry, state.session_key)

    # If we were monitoring the gateway run process, stop monitoring it before we exit so
    # we don't race a :DOWN message and emit a synthetic completion.
    state = maybe_demonitor_gateway_run(state)

    # Emit router-level completion event
    Bus.broadcast(Bus.session_topic(state.session_key), event)

    # Mark any still-running tool calls as completed so the editable "Tool calls"
    # status message (Telegram) can't get stuck at [running] if a final action
    # completion event is missed/raced.
    finalize_tool_status(state, event)

    # If we never streamed deltas, make sure any tool-status output is flushed
    # before we emit a single final answer chunk.
    if state.saw_delta == false do
      flush_tool_status(state)
    end

    # Telegram: StreamCoalescer finalizes by sending/editing a dedicated answer message; the
    # progress message is reserved for tool-call status + cancel UI and is never overwritten.
    maybe_finalize_stream_output(state, event)

    # If no streaming deltas were emitted, emit a final output chunk so channels respond.
    #
    # Note: Telegram final output is handled by maybe_finalize_stream_output/2 instead to avoid
    # producing a terminal :edit update to the progress message.
    maybe_emit_final_output(state, event)

    {:stop, :normal, %{state | completed: true}}
  end

  def handle_info(%LemonCore.Event{type: :delta, payload: delta} = event, state) do
    # Forward delta to session subscribers
    Bus.broadcast(Bus.session_topic(state.session_key), event)

    # Ensure any pending tool-status output is emitted before we start streaming the answer.
    if state.saw_delta == false do
      flush_tool_status(state)
    end

    # Also ingest into StreamCoalescer for channel delivery
    ingest_delta_to_coalescer(state, delta)

    {:noreply, %{state | saw_delta: true}}
  end

  def handle_info(%LemonCore.Event{type: :engine_action, payload: action_ev} = event, state) do
    # Forward engine action events to session subscribers
    Bus.broadcast(Bus.session_topic(state.session_key), event)

    # Also ingest into ToolStatusCoalescer for channel delivery
    ingest_action_to_tool_status_coalescer(state, action_ev)

    state = maybe_track_generated_images(state, action_ev)
    state = maybe_track_requested_send_files(state, action_ev)

    {:noreply, state}
  end

  def handle_info(%LemonCore.Event{} = event, state) do
    # Forward other events to session subscribers
    Bus.broadcast(Bus.session_topic(state.session_key), event)
    {:noreply, state}
  end

  def handle_info(:retry_session_register, state) do
    # Timer fired.
    state = %{state | session_register_retry_ref: nil}

    cond do
      state.session_registered? or state.aborted or state.completed ->
        {:noreply, state}

      true ->
        case Registry.register(LemonRouter.SessionRegistry, state.session_key, %{
               run_id: state.run_id
             }) do
          {:ok, _pid} ->
            if %LemonCore.Event{} = ev = state.pending_run_started_event do
              Bus.broadcast(Bus.session_topic(state.session_key), ev)
            end

            state =
              state
              |> Map.put(:session_registered?, true)
              |> Map.put(:pending_run_started_event, nil)
              |> Map.put(:session_register_retry_attempt, 0)
              |> maybe_monitor_gateway_run()

            {:noreply, state}

          {:error, {:already_registered, _pid}} ->
            {:noreply, schedule_session_register_retry(state)}

          _ ->
            {:noreply, schedule_session_register_retry(state)}
        end
    end
  rescue
    _ -> {:noreply, state}
  end

  # If the gateway run process dies without emitting a completion event, synthesize a failure
  # completion so the session can make progress (and SessionRegistry is eventually cleared).
  def handle_info(
        {:DOWN, ref, :process, pid, reason},
        %{gateway_run_ref: ref, gateway_run_pid: pid} = state
      ) do
    # Normal completions should be handled by :run_completed; give the bus a small grace window.
    delay_ms = gateway_down_grace_ms(reason)
    Process.send_after(self(), {:gateway_run_down, reason}, delay_ms)
    {:noreply, %{state | gateway_run_ref: nil, gateway_run_pid: nil}}
  end

  def handle_info({:gateway_run_down, reason}, state) do
    if state.completed do
      {:noreply, state}
    else
      event =
        LemonCore.Event.new(
          :run_completed,
          %{
            completed: %{
              ok: false,
              error: {:gateway_run_down, reason},
              answer: ""
            },
            duration_ms: nil
          },
          %{
            run_id: state.run_id,
            session_key: state.session_key,
            synthetic: true
          }
        )

      Bus.broadcast(Bus.run_topic(state.run_id), event)
      {:noreply, state}
    end
  rescue
    _ -> {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_cast({:abort, reason}, state) do
    if state.aborted or state.completed do
      {:noreply, state}
    else
      Logger.debug("RunProcess #{state.run_id} aborting: #{inspect(reason)}")

      # Best-effort cancel of the gateway run. This does not currently remove
      # queued jobs for the same session_key; it only cancels the in-flight run.
      LemonGateway.Runtime.cancel_by_run_id(state.run_id, reason)

      {:noreply, %{state | aborted: true}}
    end
  end

  @impl true
  def terminate(reason, state) do
    # Unregister from session registry
    Registry.unregister(LemonRouter.SessionRegistry, state.session_key)

    # If not completed normally, emit failure event and attempt abort
    if reason != :normal and not state.completed do
      Bus.broadcast(Bus.run_topic(state.run_id), %{
        type: :run_failed,
        run_id: state.run_id,
        session_key: state.session_key,
        reason: reason
      })

      # Best-effort abort of the gateway run on abnormal termination
      try do
        LemonGateway.Runtime.cancel_by_run_id(state.run_id, :run_process_terminated)
      rescue
        _ -> :ok
      end
    end

    # Flush any pending coalescer output
    flush_coalescer(state)

    # Unsubscribe control-plane EventBridge from run events
    unsubscribe_event_bridge(state.run_id)

    :ok
  end

  defp maybe_monitor_gateway_run(%{gateway_run_ref: ref} = state) when not is_nil(ref), do: state

  defp maybe_monitor_gateway_run(state) do
    with true <- Code.ensure_loaded?(Registry),
         true <- Code.ensure_loaded?(LemonGateway.RunRegistry),
         [{pid, _}] when is_pid(pid) <- Registry.lookup(LemonGateway.RunRegistry, state.run_id) do
      %{state | gateway_run_pid: pid, gateway_run_ref: Process.monitor(pid)}
    else
      _ -> state
    end
  rescue
    _ -> state
  end

  defp maybe_demonitor_gateway_run(%{gateway_run_ref: nil} = state), do: state

  defp maybe_demonitor_gateway_run(%{gateway_run_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    %{state | gateway_run_ref: nil, gateway_run_pid: nil}
  rescue
    _ -> %{state | gateway_run_ref: nil, gateway_run_pid: nil}
  end

  defp gateway_down_grace_ms(:normal), do: 200
  defp gateway_down_grace_ms(:shutdown), do: 200
  defp gateway_down_grace_ms({:shutdown, _}), do: 200
  defp gateway_down_grace_ms(_), do: 20

  defp lookup_active_session(session_key) do
    case Registry.lookup(LemonRouter.SessionRegistry, session_key) do
      [{pid, %{run_id: run_id}}] when is_pid(pid) and is_binary(run_id) ->
        {pid, run_id}

      [{pid, value}] when is_pid(pid) and is_map(value) ->
        run_id = value[:run_id] || value["run_id"]
        {pid, run_id}

      [{pid, _value}] when is_pid(pid) ->
        {pid, nil}

      _ ->
        {nil, nil}
    end
  end

  defp put_pending_run_started(%{pending_run_started_event: %LemonCore.Event{}} = state, _ev),
    do: state

  defp put_pending_run_started(state, %LemonCore.Event{} = ev),
    do: %{state | pending_run_started_event: ev}

  defp put_pending_run_started(state, _), do: state

  defp schedule_session_register_retry(%{session_register_retry_ref: ref} = state)
       when not is_nil(ref) do
    state
  end

  defp schedule_session_register_retry(state) do
    attempt = (state.session_register_retry_attempt || 0) + 1
    delay_ms = min(@session_register_retry_ms * attempt, @session_register_retry_max_ms)
    ref = Process.send_after(self(), :retry_session_register, delay_ms)
    %{state | session_register_retry_ref: ref, session_register_retry_attempt: attempt}
  end

  # Ingest delta into StreamCoalescer for channel delivery
  defp ingest_delta_to_coalescer(state, delta) do
    # Extract channel_id from session_key using SessionKey parser
    case LemonRouter.SessionKey.parse(state.session_key) do
      %{kind: :channel_peer, channel_id: channel_id} when not is_nil(channel_id) ->
        # Build meta from job for progress_msg_id
        meta = extract_coalescer_meta(state.job)

        seq = Map.get(delta, :seq)
        text = Map.get(delta, :text)

        if is_integer(seq) and is_binary(text) do
          LemonRouter.StreamCoalescer.ingest_delta(
            state.session_key,
            channel_id,
            state.run_id,
            seq,
            text,
            meta: meta
          )
        else
          :ok
        end

      _ ->
        # Not a channel session, no coalescing needed
        :ok
    end
  rescue
    _ -> :ok
  end

  # Extract metadata relevant for coalescer (e.g., progress_msg_id for edit mode)
  defp extract_coalescer_meta(%{meta: meta}) when is_map(meta) do
    %{
      progress_msg_id: meta[:progress_msg_id],
      status_msg_id: meta[:status_msg_id],
      user_msg_id: meta[:user_msg_id]
    }
  end

  defp extract_coalescer_meta(_), do: %{}

  # If the run completed without streaming deltas, emit a single delta with the final answer.
  defp maybe_emit_final_output(state, %LemonCore.Event{} = event) do
    with false <- state.saw_delta,
         answer when is_binary(answer) and answer != "" <- extract_completed_answer(event),
         %{kind: :channel_peer, channel_id: channel_id} when not is_nil(channel_id) <-
           LemonRouter.SessionKey.parse(state.session_key) do
      # Telegram final output is handled via StreamCoalescer.finalize_run/4
      # so we avoid emitting a terminal :edit update to the progress message.
      if channel_id == "telegram" do
        :ok
      else
        meta = extract_coalescer_meta(state.job)

        LemonRouter.StreamCoalescer.ingest_delta(
          state.session_key,
          channel_id,
          state.run_id,
          1,
          answer,
          meta: meta
        )
      end
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp extract_completed_answer(%LemonCore.Event{payload: %{completed: %{answer: answer}}}),
    do: answer

  defp extract_completed_answer(%LemonCore.Event{
         payload: %LemonGateway.Event.Completed{answer: answer}
       }),
       do: answer

  defp extract_completed_answer(%LemonCore.Event{payload: %{answer: answer}}), do: answer
  defp extract_completed_answer(_), do: nil

  defp extract_completed_resume(%LemonCore.Event{payload: %{completed: %{resume: resume}}}),
    do: resume

  defp extract_completed_resume(%LemonCore.Event{payload: %{resume: resume}}), do: resume

  defp extract_completed_resume(%LemonCore.Event{
         payload: %LemonGateway.Event.Completed{resume: resume}
       }),
       do: resume

  defp extract_completed_resume(_), do: nil

  defp normalize_resume_token(nil), do: nil

  defp normalize_resume_token(%LemonGateway.Types.ResumeToken{} = tok), do: tok

  defp normalize_resume_token(%{engine: engine, value: value})
       when is_binary(engine) and is_binary(value) do
    %LemonGateway.Types.ResumeToken{engine: engine, value: value}
  end

  defp normalize_resume_token(%{"engine" => engine, "value" => value})
       when is_binary(engine) and is_binary(value) do
    %LemonGateway.Types.ResumeToken{engine: engine, value: value}
  end

  defp normalize_resume_token(_), do: nil

  defp extract_completed_ok_and_error(%LemonCore.Event{payload: %{completed: %{ok: ok} = c}})
       when is_boolean(ok) do
    {ok, Map.get(c, :error) || Map.get(c, "error")}
  end

  defp extract_completed_ok_and_error(%LemonCore.Event{payload: %{ok: ok} = p})
       when is_boolean(ok) do
    {ok, Map.get(p, :error) || Map.get(p, "error")}
  end

  defp extract_completed_ok_and_error(%LemonCore.Event{
         payload: %LemonGateway.Event.Completed{ok: ok, error: err}
       })
       when is_boolean(ok),
       do: {ok, err}

  defp extract_completed_ok_and_error(_), do: {true, nil}

  defp format_run_error(nil), do: "unknown error"
  defp format_run_error(e) when is_binary(e), do: e
  defp format_run_error(e) when is_atom(e), do: Atom.to_string(e)
  defp format_run_error(e), do: inspect(e)

  defp maybe_finalize_stream_output(state, %LemonCore.Event{} = event) do
    with %{kind: :channel_peer, channel_id: "telegram"} <-
           LemonRouter.SessionKey.parse(state.session_key) do
      meta = extract_coalescer_meta(state.job)
      resume = event |> extract_completed_resume() |> normalize_resume_token()

      final_text =
        case extract_completed_answer(event) do
          answer when is_binary(answer) and answer != "" ->
            answer

          _ ->
            case extract_completed_ok_and_error(event) do
              {false, err} ->
                "Run failed: #{format_run_error(err)}"

              _ ->
                nil
            end
        end

      # StreamCoalescer handles optional resume footer formatting; RunProcess just passes metadata.
      meta = if resume, do: Map.put(meta, :resume, resume), else: meta
      meta = maybe_add_auto_send_generated_files(meta, state)

      LemonRouter.StreamCoalescer.finalize_run(
        state.session_key,
        "telegram",
        state.run_id,
        meta: meta,
        final_text: final_text
      )
    else
      _ -> :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  defp finalize_tool_status(state, %LemonCore.Event{} = event) do
    with %{kind: :channel_peer, channel_id: channel_id} when not is_nil(channel_id) <-
           LemonRouter.SessionKey.parse(state.session_key) do
      ok? =
        case event.payload do
          %{completed: %{ok: ok}} -> ok == true
          %{ok: ok} -> ok == true
          _ -> false
        end

      meta = extract_coalescer_meta(state.job)

      LemonRouter.ToolStatusCoalescer.finalize_run(
        state.session_key,
        channel_id,
        state.run_id,
        ok?,
        meta: meta
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  defp ingest_action_to_tool_status_coalescer(state, action_ev) do
    case LemonRouter.SessionKey.parse(state.session_key) do
      %{kind: :channel_peer, channel_id: channel_id} when not is_nil(channel_id) ->
        meta = extract_coalescer_meta(state.job)

        LemonRouter.ToolStatusCoalescer.ingest_action(
          state.session_key,
          channel_id,
          state.run_id,
          action_ev,
          meta: meta
        )

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  # Flush any pending coalesced output on termination
  defp flush_coalescer(state) do
    case LemonRouter.SessionKey.parse(state.session_key) do
      %{kind: :channel_peer, channel_id: channel_id} when not is_nil(channel_id) ->
        LemonRouter.StreamCoalescer.flush(state.session_key, channel_id)
        LemonRouter.ToolStatusCoalescer.flush(state.session_key, channel_id)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp flush_tool_status(state) do
    case LemonRouter.SessionKey.parse(state.session_key) do
      %{kind: :channel_peer, channel_id: channel_id} when not is_nil(channel_id) ->
        LemonRouter.ToolStatusCoalescer.flush(state.session_key, channel_id)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp maybe_track_generated_images(state, action_ev) do
    paths = extract_generated_image_paths(action_ev)

    if paths == [] do
      state
    else
      existing = state.generated_image_paths || []
      %{state | generated_image_paths: merge_paths(existing, paths)}
    end
  end

  defp maybe_track_requested_send_files(state, action_ev) do
    files = extract_requested_send_files(action_ev)

    if files == [] do
      state
    else
      existing = state.requested_send_files || []
      %{state | requested_send_files: merge_files(existing, files)}
    end
  end

  defp merge_paths(existing, new_paths) do
    Enum.reduce(new_paths, existing, fn path, acc ->
      if path in acc do
        acc
      else
        acc ++ [path]
      end
    end)
  end

  defp extract_requested_send_files(action_ev) do
    action = fetch(action_ev, :action)
    phase = fetch(action_ev, :phase)
    ok = fetch(action_ev, :ok)

    cond do
      not phase_completed?(phase) ->
        []

      ok == false ->
        []

      true ->
        detail = fetch(action, :detail)
        result_meta = fetch(detail, :result_meta)
        auto_send_files = fetch(result_meta, :auto_send_files)

        case auto_send_files do
          files when is_list(files) ->
            files
            |> Enum.map(&normalize_requested_send_file/1)
            |> Enum.reject(&is_nil/1)

          _ ->
            []
        end
    end
  end

  defp normalize_requested_send_file(file) when is_map(file) do
    path = fetch(file, :path)
    filename = fetch(file, :filename)
    caption = fetch(file, :caption)

    if is_binary(path) and path != "" do
      %{
        path: path,
        filename:
          case filename do
            x when is_binary(x) and x != "" -> x
            _ -> Path.basename(path)
          end,
        caption:
          case caption do
            x when is_binary(x) and x != "" -> x
            _ -> nil
          end
      }
    else
      nil
    end
  end

  defp normalize_requested_send_file(_), do: nil

  defp extract_generated_image_paths(action_ev) do
    action = fetch(action_ev, :action)
    kind = fetch(action, :kind)
    phase = fetch(action_ev, :phase)
    ok = fetch(action_ev, :ok)

    cond do
      not file_change_kind?(kind) ->
        []

      not phase_completed?(phase) ->
        []

      ok == false ->
        []

      true ->
        detail = fetch(action, :detail)

        case fetch(detail, :changes) do
          changes when is_list(changes) ->
            changes
            |> Enum.flat_map(fn change ->
              case extract_image_change_path(change) do
                nil -> []
                path -> [path]
              end
            end)

          _ ->
            []
        end
    end
  end

  defp extract_image_change_path(change) do
    path = fetch(change, :path)
    kind = fetch(change, :kind)

    cond do
      not is_binary(path) or path == "" ->
        nil

      deleted_change_kind?(kind) ->
        nil

      not image_path?(path) ->
        nil

      true ->
        path
    end
  end

  defp file_change_kind?(kind) when kind in [:file_change, "file_change"], do: true
  defp file_change_kind?(_), do: false

  defp phase_completed?(phase) when phase in [:completed, "completed"], do: true
  defp phase_completed?(_), do: false

  defp deleted_change_kind?(kind) when kind in [:deleted, "deleted", :remove, "remove"], do: true
  defp deleted_change_kind?(_), do: false

  defp image_path?(path) when is_binary(path) do
    case Path.extname(path) |> String.downcase() do
      ".png" -> true
      ".jpg" -> true
      ".jpeg" -> true
      ".gif" -> true
      ".webp" -> true
      ".bmp" -> true
      ".svg" -> true
      ".tif" -> true
      ".tiff" -> true
      ".heic" -> true
      ".heif" -> true
      _ -> false
    end
  end

  defp maybe_add_auto_send_generated_files(meta, state) when is_map(meta) do
    explicit_files =
      state.requested_send_files
      |> resolve_explicit_send_files(state.job && state.job.cwd)

    cfg = telegram_auto_send_generated_config()

    generated_files =
      if cfg.enabled do
        state.generated_image_paths
        |> select_recent_paths(cfg.max_files)
        |> resolve_generated_files(state.job && state.job.cwd, cfg.max_bytes)
      else
        []
      end

    files = merge_files(explicit_files, generated_files)

    if files == [] do
      meta
    else
      Map.put(meta, :auto_send_files, files)
    end
  end

  defp maybe_add_auto_send_generated_files(meta, _state), do: meta

  defp select_recent_paths(paths, max_files) when is_list(paths) and is_integer(max_files) do
    if max_files > 0 and length(paths) > max_files do
      Enum.take(paths, -max_files)
    else
      paths
    end
  end

  defp select_recent_paths(paths, _max_files), do: paths

  defp resolve_generated_files(paths, cwd, max_bytes) when is_list(paths) do
    paths
    |> Enum.map(&resolve_generated_path(&1, cwd))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.flat_map(fn path ->
      case file_within_limit(path, max_bytes) do
        {:ok, file} -> [file]
        _ -> []
      end
    end)
  end

  defp resolve_generated_files(_, _cwd, _max_bytes), do: []

  defp resolve_explicit_send_files(files, cwd) when is_list(files) do
    max_bytes = telegram_files_max_download_bytes()

    files
    |> Enum.map(&resolve_explicit_send_file(&1, cwd, max_bytes))
    |> Enum.reject(&is_nil/1)
  end

  defp resolve_explicit_send_files(_, _cwd), do: []

  defp resolve_explicit_send_file(file, cwd, max_bytes) when is_map(file) do
    path = fetch(file, :path)
    caption = fetch(file, :caption)
    filename = fetch(file, :filename)

    resolved_path =
      cond do
        is_binary(cwd) and cwd != "" ->
          case resolve_generated_path(path, cwd) do
            nil ->
              if is_binary(path) and Path.type(path) == :absolute do
                Path.expand(path)
              else
                nil
              end

            resolved ->
              resolved
          end

        is_binary(path) and Path.type(path) == :absolute ->
          Path.expand(path)

        true ->
          nil
      end

    with path when is_binary(path) and path != "" <- path,
         resolved when is_binary(resolved) <- resolved_path,
         {:ok, %{path: valid_path}} <- file_within_limit(resolved, max_bytes) do
      %{
        path: valid_path,
        filename:
          case filename do
            x when is_binary(x) and x != "" -> x
            _ -> Path.basename(valid_path)
          end,
        caption:
          case caption do
            x when is_binary(x) and x != "" -> x
            _ -> nil
          end
      }
    else
      _ -> nil
    end
  end

  defp resolve_explicit_send_file(_, _cwd, _max_bytes), do: nil

  defp resolve_generated_path(path, _cwd) when not is_binary(path), do: nil

  defp resolve_generated_path(path, cwd) when is_binary(cwd) and cwd != "" do
    root = Path.expand(cwd)

    absolute =
      if Path.type(path) == :absolute do
        Path.expand(path)
      else
        Path.expand(path, root)
      end

    if path_within_root?(absolute, root) do
      absolute
    else
      nil
    end
  end

  defp resolve_generated_path(_path, _cwd), do: nil

  defp merge_files(first, second) when is_list(first) and is_list(second) do
    (first ++ second)
    |> Enum.reduce({[], MapSet.new()}, fn file, {acc, seen} ->
      key = {Map.get(file, :path), Map.get(file, :caption)}

      if MapSet.member?(seen, key) do
        {acc, seen}
      else
        {acc ++ [file], MapSet.put(seen, key)}
      end
    end)
    |> elem(0)
  end

  defp merge_files(first, second) when is_list(first), do: first ++ List.wrap(second)
  defp merge_files(_first, second) when is_list(second), do: second
  defp merge_files(_, _), do: []

  defp path_within_root?(absolute, root) when is_binary(absolute) and is_binary(root) do
    rel = Path.relative_to(absolute, root)
    rel == "." or not String.starts_with?(rel, "..")
  end

  defp file_within_limit(path, max_bytes) when is_binary(path) and is_integer(max_bytes) do
    with true <- File.regular?(path),
         {:ok, %File.Stat{size: size}} <- File.stat(path),
         true <- size <= max_bytes do
      {:ok, %{path: path, filename: Path.basename(path), caption: nil}}
    else
      _ -> :error
    end
  end

  defp file_within_limit(_path, _max_bytes), do: :error

  defp telegram_auto_send_generated_config do
    telegram_cfg =
      if Process.whereis(LemonGateway.Config) do
        LemonGateway.Config.get(:telegram) || %{}
      else
        Application.get_env(:lemon_gateway, :telegram, %{}) || %{}
      end

    telegram_cfg = normalize_map(telegram_cfg)

    files_cfg = fetch(telegram_cfg, :files)
    files_cfg = normalize_map(files_cfg)

    enabled? =
      truthy?(fetch(files_cfg, :enabled)) and
        truthy?(fetch(files_cfg, :auto_send_generated_images))

    %{
      enabled: enabled?,
      max_files:
        positive_int_or(
          fetch(files_cfg, :auto_send_generated_max_files),
          @default_auto_send_generated_max_files
        ),
      max_bytes:
        positive_int_or(fetch(files_cfg, :max_download_bytes), @default_max_download_bytes)
    }
  rescue
    _ ->
      %{
        enabled: false,
        max_files: @default_auto_send_generated_max_files,
        max_bytes: @default_max_download_bytes
      }
  end

  defp fetch(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Map.get(map, Atom.to_string(key))
    end
  end

  defp fetch(_, _), do: nil

  defp normalize_map(value) when is_map(value), do: value

  defp normalize_map(value) when is_list(value) do
    if Keyword.keyword?(value) do
      Enum.into(value, %{})
    else
      %{}
    end
  end

  defp normalize_map(_), do: %{}

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_), do: false

  defp positive_int_or(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_int_or(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp positive_int_or(_value, default), do: default

  defp telegram_files_max_download_bytes do
    telegram_cfg =
      if Process.whereis(LemonGateway.Config) do
        LemonGateway.Config.get(:telegram) || %{}
      else
        Application.get_env(:lemon_gateway, :telegram, %{}) || %{}
      end

    telegram_cfg = normalize_map(telegram_cfg)
    files_cfg = fetch(telegram_cfg, :files) |> normalize_map()

    positive_int_or(fetch(files_cfg, :max_download_bytes), @default_max_download_bytes)
  rescue
    _ -> @default_max_download_bytes
  end

  # Unsubscribe control-plane EventBridge from run events
  defp unsubscribe_event_bridge(run_id) do
    LemonCore.EventBridge.unsubscribe_run(run_id)
  end

  defp scheduler_available?(scheduler) do
    case GenServer.whereis(scheduler) do
      pid when is_pid(pid) -> true
      _ -> false
    end
  end

  defp gateway_submit_retry_delay_ms(attempt) when is_integer(attempt) and attempt >= 0 do
    exponential = @gateway_submit_retry_base_ms * :math.pow(2, attempt)
    delay_ms = round(exponential)
    min(delay_ms, @gateway_submit_retry_max_ms)
  end
end
