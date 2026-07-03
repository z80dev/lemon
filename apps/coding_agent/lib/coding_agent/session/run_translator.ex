defmodule CodingAgent.Session.RunTranslator do
  @moduledoc false

  alias CodingAgent.Session.Presentation
  alias LemonCore.ResumeToken

  require Logger

  defmodule Emitter do
    @moduledoc false

    @callback emit_started(term(), map()) :: term()
    @callback emit_action_event(term(), map()) :: term()
    @callback emit_delta(term(), String.t(), map()) :: term()
    @callback emit_completed(term(), map()) :: term()
  end

  defstruct [
    :emitter,
    :emitter_state,
    :engine,
    :label,
    :session_id,
    :cwd,
    :run_id,
    :resume_token,
    :delta_callback,
    accumulated_text: "",
    pending_actions: %{},
    reasoning_accumulator: nil,
    started_emitted: false,
    completed_emitted: false,
    delta_seq: 0,
    first_token_emitted: false
  ]

  def new(opts) do
    %__MODULE__{
      emitter: Keyword.fetch!(opts, :emitter),
      emitter_state: Keyword.fetch!(opts, :emitter_state),
      engine: Keyword.fetch!(opts, :engine),
      label: Keyword.fetch!(opts, :label),
      session_id: Keyword.get(opts, :session_id),
      cwd: Keyword.fetch!(opts, :cwd),
      run_id: Keyword.get(opts, :run_id),
      delta_callback: Keyword.get(opts, :delta_callback),
      accumulated_text: "",
      pending_actions: %{},
      reasoning_accumulator: Presentation.new_reasoning_accumulator(),
      started_emitted: false,
      completed_emitted: false,
      delta_seq: 0,
      first_token_emitted: false
    }
  end

  def handle_event(%__MODULE__{} = t, {:agent_start}) do
    token = ResumeToken.new(t.engine, t.session_id)

    emitter_state =
      t.emitter.emit_started(t.emitter_state, %{
        engine: t.engine,
        resume: token,
        meta: %{cwd: t.cwd}
      })

    %{t | emitter_state: emitter_state, resume_token: token, started_emitted: true}
  end

  def handle_event(%__MODULE__{} = t, {:tool_execution_start, id, name, args}) do
    action_id = "tool_#{id}"
    kind = Presentation.tool_kind(name)
    title = Presentation.tool_title(name, args)
    detail = %{name: name, args: args}

    action = %{id: action_id, kind: kind, title: title, detail: detail}

    t =
      emit_action_event(t, %{
        id: action_id,
        kind: kind,
        title: title,
        phase: :started,
        detail: detail
      })

    pending = Map.put(t.pending_actions, action_id, action)
    %{t | pending_actions: pending}
  end

  def handle_event(
        %__MODULE__{} = t,
        {:tool_execution_update, id, _name, _args, partial_result}
      ) do
    action_id = "tool_#{id}"

    case Map.get(t.pending_actions, action_id) do
      nil ->
        t

      action ->
        detail = Map.merge(action.detail, %{partial_result: partial_result})

        t =
          emit_action_event(t, %{
            id: action_id,
            kind: action.kind,
            title: action.title,
            phase: :updated,
            detail: detail
          })

        updated_action = %{action | detail: detail}
        pending = Map.put(t.pending_actions, action_id, updated_action)
        %{t | pending_actions: pending}
    end
  end

  def handle_event(%__MODULE__{} = t, {:tool_execution_end, id, name, result, is_error}) do
    action_id = "tool_#{id}"

    case Map.get(t.pending_actions, action_id) do
      nil ->
        kind = Presentation.tool_kind(name)
        title = Presentation.tool_title(name, %{})

        detail =
          %{name: name, result: Presentation.truncate_result(result)}
          |> Presentation.maybe_put_result_meta(result, name)

        ok? = Presentation.action_ok?(name, result, is_error)

        emit_action_event(t, %{
          id: action_id,
          kind: kind,
          title: title,
          phase: :completed,
          ok: ok?,
          detail: detail
        })

      action ->
        detail =
          action.detail
          |> Map.merge(%{result: Presentation.truncate_result(result)})
          |> Presentation.maybe_put_result_meta(result, name)

        ok? = Presentation.action_ok?(name, result, is_error)

        t =
          emit_action_event(t, %{
            id: action_id,
            kind: action.kind,
            title: action.title,
            phase: :completed,
            ok: ok?,
            detail: detail
          })

        pending = Map.delete(t.pending_actions, action_id)
        %{t | pending_actions: pending}
    end
  end

  def handle_event(%__MODULE__{} = t, {:message_update, _msg, delta}) when is_binary(delta) do
    t = emit_delta(t, delta)
    %{t | accumulated_text: t.accumulated_text <> delta}
  end

  def handle_event(%__MODULE__{} = t, {:message_update, msg, event}) when is_tuple(event) do
    case emit_reasoning_action(event, t) do
      {true, t} ->
        t

      {false, t} ->
        case Presentation.text_delta_from_message_update(msg, event, t.accumulated_text) do
          text when is_binary(text) and text != "" ->
            t = emit_delta(t, text)
            %{t | accumulated_text: t.accumulated_text <> text}

          _ ->
            t
        end
    end
  end

  def handle_event(%__MODULE__{} = t, {:message_update, _msg, _delta}), do: t

  def handle_event(%__MODULE__{} = t, {:agent_end, messages}) do
    answer = Presentation.extract_answer(messages, t.accumulated_text)
    usage = Presentation.build_usage(messages)

    emit_completed_ok(t, answer, usage)
  end

  def handle_event(%__MODULE__{} = t, {:error, reason, partial_state}) do
    error_msg = Presentation.format_error(reason, t)

    Logger.error(
      "#{t.label} stream error " <>
        "run_id=#{inspect(t.run_id)} " <>
        "session_id=#{inspect(t.session_id)} " <>
        "error=#{error_msg} " <>
        "reason=#{inspect(reason, limit: 80, printable_limit: 8_000)} " <>
        "answer_bytes=#{byte_size(t.accumulated_text || "")} " <>
        "pending_actions=#{map_size(t.pending_actions || %{})}"
    )

    emit_completed_error(t, error_msg, partial_state)
  end

  def handle_event(%__MODULE__{} = t, {:turn_start}), do: t
  def handle_event(%__MODULE__{} = t, {:turn_end, _msg, _results}), do: t
  def handle_event(%__MODULE__{} = t, {:message_start, _msg}), do: t
  def handle_event(%__MODULE__{} = t, {:message_end, _msg}), do: t
  def handle_event(%__MODULE__{} = t, {:extension_status_report, _report}), do: t
  def handle_event(%__MODULE__{} = t, {:compaction_complete, _info}), do: t
  def handle_event(%__MODULE__{} = t, {:branch_summarized, _info}), do: t
  def handle_event(%__MODULE__{} = t, _event), do: t

  def handle_cancel(%__MODULE__{} = t, reason) do
    if t.started_emitted and not t.completed_emitted do
      emit_completed_error(t, Presentation.cancel_error_message(reason))
    else
      t
    end
  end

  def handle_session_down(%__MODULE__{} = t, reason) do
    if t.started_emitted and not t.completed_emitted do
      emit_completed_error(t, "Session terminated: #{inspect(reason)}")
    else
      t
    end
  end

  defp emit_delta(%__MODULE__{} = t, text) when is_binary(text) and byte_size(text) > 0 do
    new_seq = t.delta_seq + 1

    t =
      if not t.first_token_emitted do
        if t.delta_callback do
          t.delta_callback.(:first_token, %{run_id: t.run_id, seq: new_seq})
        end

        %{t | first_token_emitted: true}
      else
        t
      end

    delta_event = %{
      type: :delta,
      run_id: t.run_id,
      ts_ms: System.system_time(:millisecond),
      seq: new_seq,
      text: text
    }

    emitter_state = t.emitter.emit_delta(t.emitter_state, text, delta_event)

    if t.delta_callback do
      t.delta_callback.(:delta, delta_event)
    end

    %{t | emitter_state: emitter_state, delta_seq: new_seq}
  end

  defp emit_delta(%__MODULE__{} = t, _text), do: t

  defp emit_reasoning_action(event, %__MODULE__{} = t) do
    case Presentation.reasoning_action(event, t.reasoning_accumulator) do
      {:emit, action, accumulator} ->
        t =
          emit_action_event(t, %{
            id: action.id,
            kind: action.kind,
            title: action.title,
            phase: action.phase,
            ok: action.ok,
            detail: action.detail
          })

        {true, %{t | reasoning_accumulator: accumulator}}

      {:skip, %Presentation.ReasoningAccumulator{} = accumulator} ->
        {true, %{t | reasoning_accumulator: accumulator}}

      {:ignore, %Presentation.ReasoningAccumulator{} = accumulator} ->
        {false, %{t | reasoning_accumulator: accumulator}}
    end
  end

  defp emit_completed_ok(%__MODULE__{} = t, answer, usage) do
    if t.completed_emitted do
      t
    else
      emitter_state =
        t.emitter.emit_completed(t.emitter_state, %{
          engine: t.engine,
          ok: true,
          answer: answer,
          resume: t.resume_token,
          usage: usage
        })

      %{t | emitter_state: emitter_state, completed_emitted: true}
    end
  end

  defp emit_completed_error(%__MODULE__{} = t, error_msg, partial_state \\ nil) do
    if t.completed_emitted do
      t
    else
      usage = Presentation.build_failure_usage(t.emitter_state, partial_state)

      emitter_state =
        t.emitter.emit_completed(t.emitter_state, %{
          engine: t.engine,
          ok: false,
          error: error_msg,
          answer: t.accumulated_text,
          resume: t.resume_token,
          usage: usage
        })

      %{t | emitter_state: emitter_state, completed_emitted: true}
    end
  end

  defp emit_action_event(%__MODULE__{} = t, fields) do
    fields =
      fields
      |> Map.put(:engine, t.engine)
      |> Map.put_new(:ok, nil)
      |> Map.put_new(:message, nil)
      |> Map.put_new(:level, nil)

    emitter_state = t.emitter.emit_action_event(t.emitter_state, fields)
    %{t | emitter_state: emitter_state}
  end
end
