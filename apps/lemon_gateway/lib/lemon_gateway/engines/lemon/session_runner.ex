defmodule LemonGateway.Engines.Lemon.SessionRunner do
  @moduledoc false

  use GenServer

  alias CodingAgent.Session.Presentation
  alias LemonCore.ResumeToken
  alias LemonGateway.Event
  alias LemonGateway.Types.Job

  require Logger

  @engine "lemon"

  defstruct [
    :session,
    :session_ref,
    :session_id,
    :sink_pid,
    :run_ref,
    :prompt,
    :cwd,
    :resume,
    :run_id,
    :session_key,
    :agent_id,
    :accumulated_text,
    :pending_actions,
    :resume_token,
    :started_emitted,
    :completed_emitted,
    :delta_seq,
    :first_token_emitted,
    :delta_callback
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def cancel(pid, reason \\ :user_requested) do
    GenServer.cast(pid, {:cancel, reason})
  end

  def steer(pid, text) do
    GenServer.call(pid, {:steer, text})
  end

  @impl true
  def init(opts) do
    case LemonGateway.DependencyManager.ensure_app(:coding_agent) do
      :ok ->
        init_session(opts)

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp init_session(opts) do
    job = Keyword.fetch!(opts, :job)
    run_opts = Keyword.get(opts, :opts, %{})
    sink_pid = Keyword.fetch!(opts, :sink_pid)
    run_ref = Keyword.fetch!(opts, :run_ref)

    prompt = job.prompt
    cwd = job.cwd || get_opt(run_opts, :cwd) || File.cwd!()
    resume = normalize_resume(job.resume)
    run_id = job.run_id || get_opt(run_opts, :run_id)
    session_key = job.session_key
    agent_id = job_agent_id(job)
    async_followups = async_followups(job)
    extra_tools = gateway_extra_tools(job, run_opts)
    stream_fn = get_opt(run_opts, :stream_fn)

    state = %__MODULE__{
      sink_pid: sink_pid,
      run_ref: run_ref,
      prompt: prompt,
      cwd: cwd,
      resume: resume,
      run_id: run_id,
      session_key: session_key,
      agent_id: agent_id,
      accumulated_text: "",
      pending_actions: %{},
      started_emitted: false,
      completed_emitted: false,
      delta_seq: 0,
      first_token_emitted: false,
      delta_callback: get_opt(run_opts, :delta_callback)
    }

    session_opts =
      [
        model: get_in(job.meta || %{}, [:model]),
        thinking_level: get_in(job.meta || %{}, [:thinking_level]),
        system_prompt: get_in(job.meta || %{}, [:system_prompt]),
        stream_fn: stream_fn,
        tool_policy: job.tool_policy,
        approval_timeout_ms: get_opt(run_opts, :approval_timeout_ms),
        acp_session_id: get_in(job.meta || %{}, [:acp_session_id]),
        acp_client_fs_read_text_file: get_in(job.meta || %{}, [:acp_client_fs_read_text_file]),
        acp_client_fs_write_text_file: get_in(job.meta || %{}, [:acp_client_fs_write_text_file]),
        stream_options: get_opt(run_opts, :stream_options),
        extra_tools: extra_tools
      ]
      |> Presentation.build_session_opts(cwd, run_id, session_key, agent_id)

    case Presentation.start_or_resume_session(resume, session_opts, state) do
      {:ok, session, session_id, state} ->
        {:ok, _stream} = CodingAgent.Session.subscribe(session, mode: :stream, max_queue: 10_000)
        _unsub = CodingAgent.Session.subscribe(session)

        case async_followups do
          list when is_list(list) and list != [] ->
            :ok =
              CodingAgent.Session.handle_async_followup(session, %{
                content: prompt,
                async_followups: list
              })

          _ ->
            :ok = CodingAgent.Session.prompt(session, prompt, images: job.images)
        end

        session_ref = Process.monitor(session)

        {:ok,
         %{
           state
           | session: session,
             session_ref: session_ref,
             session_id: session_id
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:steer, text}, _from, state) do
    case state.session do
      nil ->
        {:reply, {:error, :no_session}, state}

      session ->
        CodingAgent.Session.steer(session, text)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_cast({:cancel, reason}, state) do
    state = handle_cancel(reason, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:session_event, _session_id, event}, state) do
    state = translate_and_emit(event, state)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.debug("Lemon SessionRunner: Session process down: #{inspect(reason)}")

    state =
      if state.started_emitted and not state.completed_emitted do
        emit_completed_error(state, "Session terminated: #{inspect(reason)}")
      else
        state
      end

    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp handle_cancel(reason, state) do
    if state.session do
      CodingAgent.Session.abort(state.session)
    end

    if state.started_emitted and not state.completed_emitted do
      emit_completed_error(state, Presentation.cancel_error_message(reason))
    else
      state
    end
  end

  defp translate_and_emit({:agent_start}, state) do
    token = ResumeToken.new(@engine, state.session_id)
    event = Event.started(%{engine: @engine, resume: token, meta: %{cwd: state.cwd}})

    emit_event(state, event)
    %{state | resume_token: token, started_emitted: true}
  end

  defp translate_and_emit({:tool_execution_start, id, name, args}, state) do
    action_id = "tool_#{id}"
    kind = Presentation.tool_kind(name)
    title = Presentation.tool_title(name, args)
    detail = %{name: name, args: args}

    action = %{id: action_id, kind: kind, title: title, detail: detail}

    emit_action_event(state, action_id, kind, title, :started, detail: detail)

    pending = Map.put(state.pending_actions, action_id, action)
    %{state | pending_actions: pending}
  end

  defp translate_and_emit({:tool_execution_update, id, _name, _args, partial_result}, state) do
    action_id = "tool_#{id}"

    case Map.get(state.pending_actions, action_id) do
      nil ->
        state

      action ->
        detail = Map.merge(action.detail, %{partial_result: partial_result})

        emit_action_event(state, action_id, action.kind, action.title, :updated, detail: detail)

        updated_action = %{action | detail: detail}
        pending = Map.put(state.pending_actions, action_id, updated_action)
        %{state | pending_actions: pending}
    end
  end

  defp translate_and_emit({:tool_execution_end, id, name, result, is_error}, state) do
    action_id = "tool_#{id}"

    case Map.get(state.pending_actions, action_id) do
      nil ->
        kind = Presentation.tool_kind(name)
        title = Presentation.tool_title(name, %{})

        detail =
          %{name: name, result: Presentation.truncate_result(result)}
          |> Presentation.maybe_put_result_meta(result, name)

        ok? = Presentation.action_ok?(name, result, is_error)

        emit_action_event(state, action_id, kind, title, :completed,
          ok: ok?,
          detail: detail
        )

        state

      action ->
        detail =
          action.detail
          |> Map.merge(%{result: Presentation.truncate_result(result)})
          |> Presentation.maybe_put_result_meta(result, name)

        ok? = Presentation.action_ok?(name, result, is_error)

        emit_action_event(state, action_id, action.kind, action.title, :completed,
          ok: ok?,
          detail: detail
        )

        pending = Map.delete(state.pending_actions, action_id)
        %{state | pending_actions: pending}
    end
  end

  defp translate_and_emit({:message_update, _msg, delta}, state) when is_binary(delta) do
    state = emit_delta(state, delta)
    %{state | accumulated_text: state.accumulated_text <> delta}
  end

  defp translate_and_emit({:message_update, msg, event}, state) when is_tuple(event) do
    case Presentation.text_delta_from_message_update(msg, event, state.accumulated_text) do
      text when is_binary(text) and text != "" ->
        state = emit_delta(state, text)
        %{state | accumulated_text: state.accumulated_text <> text}

      _ ->
        state
    end
  end

  defp translate_and_emit({:message_update, _msg, _delta}, state), do: state

  defp translate_and_emit({:agent_end, messages}, state) do
    answer = Presentation.extract_answer(messages, state.accumulated_text)
    usage = Presentation.build_usage(messages)

    emit_completed_ok(state, answer, usage)
  end

  defp translate_and_emit({:error, reason, _partial_state}, state) do
    error_msg = Presentation.format_error(reason, state)

    Logger.error(
      "Lemon SessionRunner stream error " <>
        "run_id=#{inspect(state.run_id)} " <>
        "session_id=#{inspect(state.session_id)} " <>
        "error=#{error_msg} " <>
        "reason=#{inspect(reason, limit: 80, printable_limit: 8_000)} " <>
        "answer_bytes=#{byte_size(state.accumulated_text || "")} " <>
        "pending_actions=#{map_size(state.pending_actions || %{})}"
    )

    emit_completed_error(state, error_msg)
  end

  defp translate_and_emit({:turn_start}, state), do: state
  defp translate_and_emit({:turn_end, _msg, _results}, state), do: state
  defp translate_and_emit({:message_start, _msg}, state), do: state
  defp translate_and_emit({:message_end, _msg}, state), do: state
  defp translate_and_emit({:extension_status_report, _report}, state), do: state
  defp translate_and_emit({:compaction_complete, _info}, state), do: state
  defp translate_and_emit({:branch_summarized, _info}, state), do: state
  defp translate_and_emit(_event, state), do: state

  defp emit_delta(state, text) when is_binary(text) and byte_size(text) > 0 do
    new_seq = state.delta_seq + 1

    state =
      if not state.first_token_emitted do
        if state.delta_callback do
          state.delta_callback.(:first_token, %{run_id: state.run_id, seq: new_seq})
        end

        %{state | first_token_emitted: true}
      else
        state
      end

    delta_event = %{
      type: :delta,
      run_id: state.run_id,
      ts_ms: System.system_time(:millisecond),
      seq: new_seq,
      text: text
    }

    send(state.sink_pid, {:engine_delta, state.run_ref, text})

    if state.delta_callback do
      state.delta_callback.(:delta, delta_event)
    end

    %{state | delta_seq: new_seq}
  end

  defp emit_delta(state, _text), do: state

  defp emit_completed_ok(state, answer, usage) do
    if state.completed_emitted do
      state
    else
      event =
        Event.completed(%{
          engine: @engine,
          ok: true,
          answer: answer,
          resume: state.resume_token,
          usage: usage
        })

      emit_event(state, event)
      state = %{state | completed_emitted: true}
      Presentation.finalize_session(state)
    end
  end

  defp emit_completed_error(state, error_msg) do
    if state.completed_emitted do
      state
    else
      event =
        Event.completed(%{
          engine: @engine,
          ok: false,
          error: error_msg,
          answer: state.accumulated_text,
          resume: state.resume_token
        })

      emit_event(state, event)
      state = %{state | completed_emitted: true}
      Presentation.finalize_session(state)
    end
  end

  defp emit_action_event(state, action_id, kind, title, phase, opts) do
    action =
      Event.action(%{
        id: action_id,
        kind: to_string(kind),
        title: title,
        detail: Keyword.get(opts, :detail)
      })

    event =
      Event.action_event(%{
        engine: @engine,
        action: action,
        phase: phase,
        ok: Keyword.get(opts, :ok),
        message: Keyword.get(opts, :message),
        level: Keyword.get(opts, :level)
      })

    emit_event(state, event)
  end

  defp emit_event(state, event) do
    send(state.sink_pid, {:engine_event, state.run_ref, event})
  end

  defp normalize_resume(%ResumeToken{engine: @engine} = token), do: token

  defp normalize_resume(%{engine: @engine, value: value}) when is_binary(value),
    do: ResumeToken.new(@engine, value)

  defp normalize_resume(_), do: nil

  defp gateway_extra_tools(%Job{} = job, opts) do
    cwd = job.cwd || get_opt(opts, :cwd) || File.cwd!()

    cron_tool =
      LemonGateway.Tools.Cron.tool(
        cwd,
        session_key: job.session_key,
        agent_id: job_agent_id(job)
      )

    sms_tools = [
      cron_tool,
      LemonGateway.Tools.SmsGetInboxNumber.tool(cwd),
      LemonGateway.Tools.SmsWaitForCode.tool(cwd, session_key: job.session_key),
      LemonGateway.Tools.SmsListMessages.tool(cwd, session_key: job.session_key),
      LemonGateway.Tools.SmsClaimMessage.tool(cwd, session_key: job.session_key)
    ]

    workspace_dir = CodingAgent.Config.workspace_dir()

    cond do
      telegram_session?(job) ->
        [
          LemonGateway.Tools.TelegramSendImage.tool(
            cwd,
            session_key: job.session_key,
            workspace_dir: workspace_dir
          )
          | sms_tools
        ]

      discord_session?(job) ->
        [
          LemonGateway.Tools.DiscordSendFile.tool(
            cwd,
            session_key: job.session_key,
            workspace_dir: workspace_dir
          )
          | sms_tools
        ]

      true ->
        sms_tools
    end
  end

  defp telegram_session?(job) do
    case LemonCore.SessionKey.parse(job.session_key || "") do
      %{kind: :channel_peer, channel_id: "telegram"} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp discord_session?(job) do
    case LemonCore.SessionKey.parse(job.session_key || "") do
      %{kind: :channel_peer, channel_id: "discord"} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp job_agent_id(job) do
    meta = job.meta || %{}

    agent_id =
      meta[:agent_id] ||
        meta["agent_id"] ||
        LemonCore.SessionKey.agent_id(job.session_key || "")

    case agent_id do
      id when is_binary(id) ->
        id = String.trim(id)
        if id == "", do: nil, else: id

      _ ->
        nil
    end
  end

  defp async_followups(job) do
    meta = job.meta || %{}
    meta[:async_followups] || meta["async_followups"]
  end

  defp get_opt(opts, key) when is_map(opts), do: Map.get(opts, key)
  defp get_opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp get_opt(_opts, _key), do: nil
end
