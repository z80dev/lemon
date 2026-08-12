defmodule LemonGateway.Engines.CliAdapter do
  @moduledoc """
  Shared CLI subprocess runner used by the Claude, Codex, Kimi, Opencode, and Pi engines.

  Provides common logic for starting a CLI runner process, consuming its event
  stream, translating `LemonAgent` events into plain tagged maps via
  `LemonGateway.Event` constructors, and handling cancellation and resume token
  formatting.
  """

  alias LemonCore.ResumeToken
  alias LemonCore.RunEvents.{ActionEvent, CompletedEvent, StartedEvent}
  alias LemonGateway.Event

  def start_run(runner_module, engine_id, job, opts, sink_pid) do
    run_ref = make_ref()

    case start_runner(runner_module, engine_id, job, opts) do
      {:ok, runner_pid} ->
        {:ok, task_pid} =
          Task.start_link(fn ->
            consume_runner(runner_module, runner_pid, engine_id, sink_pid, run_ref)
          end)

        {:ok, run_ref,
         %{task_pid: task_pid, runner_pid: runner_pid, runner_module: runner_module}}

      {:error, reason} ->
        completed = Event.completed(%{engine: engine_id, ok: false, error: reason, answer: ""})
        send(sink_pid, {:engine_event, run_ref, completed})
        {:ok, run_ref, %{task_pid: nil, runner_pid: nil, runner_module: runner_module}}
    end
  end

  def cancel(%{runner_pid: pid, runner_module: mod}) when is_pid(pid) do
    cond do
      function_exported?(mod, :cancel, 2) ->
        mod.cancel(pid, :user_requested)

      function_exported?(mod, :cancel, 1) ->
        mod.cancel(pid)

      true ->
        Process.exit(pid, :kill)
    end

    :ok
  end

  def cancel(%{task_pid: pid}) when is_pid(pid) do
    Process.exit(pid, :kill)
    :ok
  end

  # `LemonGateway.Engine.cancel/1` is total: the gateway cancels from timeout and
  # supervisor paths where its context may be stale, and `start_run/3` itself
  # hands back a nil-pid context when the runner failed to start. Nothing left to
  # kill is a successful cancel, not a FunctionClauseError in the caller.
  def cancel(_ctx), do: :ok

  def format_resume(engine_id, %ResumeToken{value: value}) do
    case engine_id do
      "codex" -> "codex resume #{value}"
      "claude" -> "claude --resume #{value}"
      "kimi" -> "kimi --session #{value}"
      "opencode" -> "opencode --session #{value}"
      "pi" -> "pi --session #{quote_token(value)}"
      _ -> "#{engine_id} resume #{value}"
    end
  end

  defp quote_token(value) when is_binary(value) do
    needs_quotes = Regex.match?(~r/\s/, value)

    cond do
      not needs_quotes and not String.contains?(value, "\"") ->
        value

      true ->
        escaped = String.replace(value, "\"", "\\\"")
        "\"#{escaped}\""
    end
  end

  defp quote_token(value), do: to_string(value)

  def extract_resume(engine_id, text) do
    case ResumeToken.extract_resume(text, engine_id) do
      %ResumeToken{engine: ^engine_id, value: value} ->
        %ResumeToken{engine: engine_id, value: value}

      _ ->
        nil
    end
  end

  # Resume-line detection keeps the LemonGateway.Engine callback name.
  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_resume_line(engine_id, line) do
    ResumeToken.is_resume_line(line, engine_id)
  end

  defp start_runner(runner_module, engine_id, job, opts) do
    resume =
      case job.resume do
        %ResumeToken{engine: ^engine_id, value: value} ->
          ResumeToken.new(engine_id, value)

        _ ->
          nil
      end

    prompt = job.prompt

    start_opts = [
      prompt: prompt,
      resume: resume,
      owner: self()
    ]

    # Add run_id and delta callback for streaming support
    start_opts =
      start_opts
      |> maybe_put(:cwd, Map.get(opts, :cwd))
      |> maybe_put(:env, Map.get(opts, :env))
      |> maybe_put(:timeout, Map.get(opts, :timeout_ms))
      |> maybe_put(:run_id, Map.get(opts, :run_id))
      |> maybe_put(:images, job.images)

    # Pass tool_policy, session_key, and agent_id for approval context
    start_opts =
      start_opts
      |> maybe_put(:tool_policy, job.tool_policy)
      |> maybe_put(:session_key, job.session_key)
      |> maybe_put(:agent_id, get_in(job.meta || %{}, [:agent_id]))
      |> maybe_put(:model, get_in(job.meta || %{}, [:model]))
      |> maybe_put(:thinking_level, get_in(job.meta || %{}, [:thinking_level]))
      |> maybe_put(:system_prompt, get_in(job.meta || %{}, [:system_prompt]))
      |> maybe_put(:acp_session_id, get_in(job.meta || %{}, [:acp_session_id]))
      |> maybe_put(
        :acp_client_fs_read_text_file,
        get_in(job.meta || %{}, [:acp_client_fs_read_text_file])
      )
      |> maybe_put(
        :acp_client_fs_write_text_file,
        get_in(job.meta || %{}, [:acp_client_fs_write_text_file])
      )
      |> maybe_put(:async_followups, async_followups(job))
      |> maybe_put(:run_id, job.run_id || Map.get(opts, :run_id))

    runner_module.start_link(start_opts)
  end

  defp async_followups(job) do
    meta = job.meta || %{}
    meta[:async_followups] || meta["async_followups"]
  end

  defp consume_runner(runner_module, runner_pid, engine_id, sink_pid, run_ref) do
    stream = runner_module.stream(runner_pid)

    _ =
      LemonAgent.EventStream.events(stream)
      |> Enum.reduce(%{completed: false}, fn event, acc ->
        acc = handle_stream_event(event, engine_id, sink_pid, run_ref, acc)
        acc
      end)

    :ok
  end

  # Handle delta events from LemonRunner for streaming
  defp handle_stream_event(
         {:cli_event, {:delta, delta_event}},
         _engine_id,
         sink_pid,
         run_ref,
         acc
       ) do
    # Forward delta to sink as :engine_delta message
    text = delta_event[:text] || delta_event.text
    send(sink_pid, {:engine_delta, run_ref, text})
    acc
  end

  defp handle_stream_event({:cli_event, %StartedEvent{} = ev}, _engine_id, sink_pid, run_ref, acc) do
    started = to_event_map(ev)
    send(sink_pid, {:engine_event, run_ref, started})
    acc
  end

  defp handle_stream_event({:cli_event, %ActionEvent{} = ev}, _engine_id, sink_pid, run_ref, acc) do
    action_event = to_event_map(ev)
    send(sink_pid, {:engine_event, run_ref, action_event})
    acc
  end

  defp handle_stream_event(
         {:cli_event, %CompletedEvent{} = ev},
         _engine_id,
         sink_pid,
         run_ref,
         acc
       ) do
    completed = to_event_map(ev)
    send(sink_pid, {:engine_event, run_ref, completed})
    %{acc | completed: true}
  end

  defp handle_stream_event({:error, reason, _}, engine_id, sink_pid, run_ref, acc) do
    if acc.completed do
      acc
    else
      completed = Event.completed(%{engine: engine_id, ok: false, error: reason, answer: ""})
      send(sink_pid, {:engine_event, run_ref, completed})
      %{acc | completed: true}
    end
  end

  defp handle_stream_event({:canceled, reason}, engine_id, sink_pid, run_ref, acc) do
    if acc.completed do
      acc
    else
      completed = Event.completed(%{engine: engine_id, ok: false, error: reason, answer: ""})
      send(sink_pid, {:engine_event, run_ref, completed})
      %{acc | completed: true}
    end
  end

  defp handle_stream_event(_event, _engine_id, _sink_pid, _run_ref, acc), do: acc

  @doc """
  Translate an LemonAgent CLI runner event into a plain tagged event map.
  """
  def to_event_map(%StartedEvent{} = ev), do: to_event_started(ev)
  def to_event_map(%ActionEvent{} = ev), do: to_event_action(ev)
  def to_event_map(%CompletedEvent{} = ev), do: to_event_completed(ev)
  def to_event_map(_), do: nil

  defp to_event_started(%StartedEvent{
         engine: engine,
         resume: resume,
         title: title,
         meta: meta
       }) do
    resume =
      case resume do
        %ResumeToken{} = token ->
          token

        %{engine: token_engine, value: value} when is_binary(token_engine) and is_binary(value) ->
          %ResumeToken{engine: token_engine, value: value}

        _ ->
          nil
      end

    Event.started(%{
      engine: engine,
      resume: resume,
      title: title,
      meta: meta
    })
  end

  defp to_event_action(%ActionEvent{
         engine: engine,
         action: action,
         phase: phase,
         ok: ok,
         message: message,
         level: level
       }) do
    gw_action =
      Event.action(%{
        id: action.id,
        kind: to_string(action.kind),
        title: action.title,
        detail: action.detail
      })

    Event.action_event(%{
      engine: engine,
      action: gw_action,
      phase: phase,
      ok: ok,
      message: message,
      level: level
    })
  end

  defp to_event_completed(%CompletedEvent{} = ev) do
    resume =
      case ev.resume do
        %ResumeToken{} = token ->
          token

        _ ->
          nil
      end

    Event.completed(%{
      engine: ev.engine,
      ok: ev.ok,
      answer: ev.answer,
      error: ev.error,
      usage: ev.usage,
      resume: resume
    })
  end

  defp maybe_put(list, _key, nil), do: list
  defp maybe_put(list, key, value), do: Keyword.put(list, key, value)
end
