defmodule CodingAgent.Session.RunTranslator do
  @moduledoc """
  Translates native session events into execution events.

  Provider usage is accumulated only from `{:provider_usage, message}` terminal
  attempt observations. Transcript messages may omit failed/empty attempts or
  repeat messages and are never accounting input. Budget ledgers enforce limits
  independently and must not fill unknown provider counters or costs.
  """

  alias CodingAgent.Executor.Usage
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
    :model_activity_scope,
    :resume_token,
    :delta_callback,
    :retry_action_id,
    :compaction_action_id,
    :budget_usage,
    :budget_stop,
    :cancel_reason,
    usage_occurrences: [],
    accumulated_text: "",
    pending_actions: %{},
    task_actions: %{},
    reasoning_accumulator: nil,
    started_emitted: false,
    todo_snapshot_received: false,
    completed_emitted: false,
    delta_seq: 0,
    first_token_emitted: false,
    turns: 0,
    tool_errors: 0
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
      # Consumers key activities by ID across every run in a transcript.
      model_activity_scope:
        Keyword.get(opts, :run_id) ||
          "translator_#{Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)}",
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

    detail = %{
      name: name,
      args: CodingAgent.ToolExecutor.project_action(name, args),
      tool_call_id: id
    }

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
        {:tool_execution_update, launch_id, "task", args,
         %{details: %{task_id: task_id} = details} = partial_result}
      )
      when is_binary(task_id) do
    action_id = "task_#{task_id}"

    if Map.get(t.task_actions, action_id) == :terminal do
      t
    else
      status = details[:status]

      terminal? =
        status in [
          :completed,
          "completed",
          :error,
          "error",
          :aborted,
          "aborted",
          :cancelled,
          "cancelled",
          :killed,
          "killed"
        ]

      phase =
        cond do
          terminal? -> :completed
          Map.has_key?(t.task_actions, action_id) -> :updated
          true -> :started
        end

      detail = %{
        name: "task",
        args: args,
        task_id: task_id,
        tool_call_id: action_id,
        parent_action_id: "tool_#{launch_id}",
        parent_tool_call_id: launch_id,
        partial_result: partial_result
      }

      detail =
        if terminal? do
          detail
          |> Map.put(:result, Presentation.truncate_result(partial_result))
          |> Presentation.put_operator_result(partial_result)
          |> Presentation.maybe_put_result_meta(partial_result, "task")
        else
          detail
        end

      t =
        emit_action_event(t, %{
          id: action_id,
          kind: Presentation.tool_kind("task"),
          title: details[:name] || details[:description] || "Task #{task_id}",
          phase: phase,
          ok: if(terminal?, do: status in [:completed, "completed"], else: nil),
          detail: detail
        })

      %{
        t
        | task_actions:
            Map.put(t.task_actions, action_id, if(terminal?, do: :terminal, else: :running))
      }
    end
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
    t =
      if Presentation.action_ok?(name, result, is_error),
        do: t,
        else: %{t | tool_errors: t.tool_errors + 1}

    action_id = "tool_#{id}"

    case Map.get(t.pending_actions, action_id) do
      nil ->
        kind = Presentation.tool_kind(name)
        title = Presentation.tool_title(name, %{})

        detail =
          %{name: name, tool_call_id: id, result: Presentation.truncate_result(result)}
          |> Presentation.put_operator_result(result)
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
          |> Presentation.put_operator_result(result)
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

  def handle_event(%__MODULE__{} = t, {:approval_request, _approval_id, _pending} = event) do
    emit_approval_action(t, event)
  end

  def handle_event(
        %__MODULE__{} = t,
        {:approval_resolved, _approval_id, _decision, _pending} = event
      ) do
    emit_approval_action(t, event)
  end

  # The targeted subscription snapshot precedes agent_start. An initially empty
  # journal is authoritative for plan consumers, but is not a visible action.
  def handle_event(
        %__MODULE__{started_emitted: false, todo_snapshot_received: false} = t,
        {:todos_changed, []}
      ),
      do: %{t | todo_snapshot_received: true}

  def handle_event(%__MODULE__{} = t, {:todos_changed, todos}) do
    emit_action_event(%{t | todo_snapshot_received: true}, %{
      id: "todos",
      kind: :note,
      title: "Todo plan updated",
      detail: %{type: :todos_changed, todos: todos},
      phase: :completed,
      ok: true
    })
  end

  def handle_event(%__MODULE__{} = t, {:todos_unavailable, reason}) do
    emit_action_event(%{t | todo_snapshot_received: true}, %{
      id: "todos",
      kind: :note,
      title: "Todo plan unavailable",
      detail: %{type: :todos_unavailable, reason: reason},
      phase: :completed,
      ok: false
    })
  end

  def handle_event(%__MODULE__{} = t, {:provider_retry, details}) when is_map(details) do
    attempt = Map.get(details, :attempt, 1)
    max_retries = Map.get(details, :max_retries, attempt)
    seconds = Float.round(Map.get(details, :delay_ms, 0) / 1000, 1)

    text =
      "Provider request failed (#{Map.get(details, :category, :transient)}); " <>
        "retrying in #{seconds}s (attempt #{attempt}/#{max_retries})"

    id = t.retry_action_id || "provider_retry_#{System.unique_integer([:positive])}"

    t =
      emit_action_event(t, %{
        id: id,
        kind: :note,
        title: text,
        phase: if(t.retry_action_id, do: :updated, else: :started),
        level: :warning,
        detail: %{text: text, retry: details}
      })

    %{t | retry_action_id: id}
  end

  def handle_event(%__MODULE__{} = t, {:provider_retry_end, details}) do
    if t.retry_action_id do
      t =
        emit_action_event(t, %{
          id: t.retry_action_id,
          kind: :note,
          title: "Provider retry finished",
          phase: :completed,
          detail: %{retry: details}
        })

      %{t | retry_action_id: nil}
    else
      t
    end
  end

  def handle_event(%__MODULE__{} = t, {:compaction_start, info}) do
    id = "compaction_#{System.unique_integer([:positive])}"

    t =
      emit_action_event(t, %{
        id: id,
        kind: :compaction,
        title: "Compacting context",
        phase: :started,
        detail: %{compaction: Map.merge(info, %{id: id, status: "in_progress"})}
      })

    %{t | compaction_action_id: id}
  end

  def handle_event(%__MODULE__{} = t, {:compaction_complete, info}) do
    id = t.compaction_action_id || "compaction_#{System.unique_integer([:positive])}"

    t =
      emit_action_event(t, %{
        id: id,
        kind: :compaction,
        title: "Context compacted",
        phase: :completed,
        detail: %{compaction: Map.merge(info, %{id: id, status: "completed"})}
      })

    %{t | compaction_action_id: nil}
  end

  def handle_event(%__MODULE__{} = t, {:usage_budget_updated, usage}) do
    %{t | budget_usage: usage}
  end

  def handle_event(%__MODULE__{} = t, {:budget_exceeded, details}) do
    %{t | budget_stop: details}
  end

  def handle_event(%__MODULE__{} = t, {:error, {:budget_exceeded, details}, partial_state}) do
    usage = Map.get(details, :provider_usage, Map.take(details, [:run_usage, :session_usage]))
    t = %{t | budget_stop: details, budget_usage: usage}
    emit_completed_error(t, details.message, partial_state)
  end

  def handle_event(%__MODULE__{} = t, {:agent_end, messages}) do
    if t.cancel_reason do
      emit_completed_error(t, Presentation.cancel_error_message(t.cancel_reason), %{
        messages: messages
      })
    else
      answer = Presentation.extract_answer(messages, t.accumulated_text)

      usage =
        t.usage_occurrences
        |> Enum.reverse()
        |> Presentation.build_usage()
        |> with_budget_usage(t)
        |> with_metrics(t)

      emit_completed_ok(t, answer, usage)
    end
  end

  def handle_event(%__MODULE__{} = t, {:canceled, reason}) do
    t = mark_cancelled(t, reason)
    emit_completed_error(t, Presentation.cancel_error_message(t.cancel_reason))
  end

  def handle_event(%__MODULE__{} = t, {:error, reason, partial_state}) do
    error_msg =
      if t.cancel_reason,
        do: Presentation.cancel_error_message(t.cancel_reason),
        else: Presentation.format_error(reason, t)

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

  def handle_event(
        %__MODULE__{} = t,
        {:turn_end, %LemonAi.Types.AssistantMessage{stop_reason: :aborted}, _results}
      ) do
    t = mark_cancelled(%{t | turns: t.turns + 1}, :assistant_aborted)
    emit_completed_error(t, Presentation.cancel_error_message(t.cancel_reason))
  end

  def handle_event(%__MODULE__{} = t, {:turn_end, _msg, _results}), do: %{t | turns: t.turns + 1}
  def handle_event(%__MODULE__{} = t, {:message_start, _msg}), do: t

  def handle_event(%__MODULE__{} = t, {:provider_usage, message}) do
    case Usage.occurrence(message) do
      nil ->
        t

      occurrence ->
        t = %{t | usage_occurrences: [occurrence | t.usage_occurrences]}
        emit_turn_model(t, occurrence)
    end
  end

  def handle_event(%__MODULE__{} = t, {:extension_status_report, _report}), do: t
  def handle_event(%__MODULE__{} = t, {:branch_summarized, _info}), do: t
  def handle_event(%__MODULE__{} = t, _event), do: t

  @doc "Marks cancellation intent without discarding queued terminal tool events."
  def mark_cancelled(%__MODULE__{} = t, reason) do
    if t.completed_emitted or t.cancel_reason,
      do: t,
      else: %{t | cancel_reason: reason || :user_requested}
  end

  def handle_session_down(%__MODULE__{} = t, reason) do
    if t.started_emitted and not t.completed_emitted do
      Logger.warning("Session stopped: #{inspect(reason)}")

      error =
        if t.cancel_reason,
          do: Presentation.cancel_error_message(t.cancel_reason),
          else: "The session stopped unexpectedly. Send your message again to retry."

      emit_completed_error(t, error)
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

  defp emit_approval_action(%__MODULE__{} = t, event) do
    case Presentation.approval_action(event) do
      nil ->
        t

      action ->
        emit_action_event(t, %{
          id: action.id,
          kind: action.kind,
          title: action.title,
          phase: action.phase,
          ok: action.ok,
          message: action.message,
          detail: action.detail
        })
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
          usage: usage,
          meta: actual_model_meta(t)
        })

      %{t | emitter_state: emitter_state, completed_emitted: true}
    end
  end

  defp emit_completed_error(%__MODULE__{} = t, error_msg, _partial_state \\ nil) do
    if t.completed_emitted do
      t
    else
      usage =
        t.usage_occurrences
        |> Enum.reverse()
        |> Presentation.build_usage()
        |> with_budget_usage(t)
        |> with_metrics(t)

      emitter_state =
        t.emitter.emit_completed(t.emitter_state, %{
          engine: t.engine,
          ok: false,
          error: error_msg,
          answer: t.accumulated_text,
          resume: t.resume_token,
          usage: usage,
          meta:
            t
            |> actual_model_meta()
            |> Map.put(:cancelled, not is_nil(t.cancel_reason))
            |> then(fn meta ->
              if t.budget_stop, do: Map.put(meta, :budget, t.budget_stop), else: meta
            end)
        })

      %{t | emitter_state: emitter_state, completed_emitted: true}
    end
  end

  defp with_budget_usage(usage, %{budget_usage: %{run_usage: _run_usage}}) do
    # Enforcement totals are separate from provider telemetry and may be unknown.
    # They cannot attest provider counters or fill their missing data.
    usage = usage || %{}
    cost = Map.get(usage, :cost)
    total_cost = if is_map(cost), do: Map.get(cost, :total), else: cost

    Map.merge(usage, %{
      tokens: Map.get(usage, :total_tokens),
      cost_usd: total_cost
    })
  end

  defp with_budget_usage(usage, _translator), do: usage

  defp with_metrics(usage, t) do
    unknown_usage = %{
      input: nil,
      output: nil,
      cache_read: nil,
      cache_write: nil,
      cache_write_long: nil,
      total_tokens: nil,
      context_tokens: nil,
      cost: %{
        input: nil,
        output: nil,
        cache_read: nil,
        cache_write: nil,
        cache_write_long: nil,
        total: nil
      }
    }

    usage = Map.merge(unknown_usage, usage || %{})

    Map.merge(usage, %{
      turns: t.turns,
      tool_errors: t.tool_errors,
      occurrences: Enum.reverse(t.usage_occurrences)
    })
  end

  defp actual_model_meta(%{usage_occurrences: [occurrence | _]}) do
    %{model: occurrence.model, provider: occurrence.provider}
  end

  defp actual_model_meta(_translator), do: %{}

  defp emit_turn_model(t, %{model: model, provider: provider})
       when is_binary(model) and model != "" and not is_nil(provider) do
    emit_action_event(t, %{
      id: "model_#{t.model_activity_scope}_#{length(t.usage_occurrences)}",
      kind: "model",
      title: "Model: #{provider}:#{model}",
      phase: :completed,
      ok: true,
      detail: %{model: model, provider: provider}
    })
  end

  defp emit_turn_model(t, _occurrence), do: t

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
