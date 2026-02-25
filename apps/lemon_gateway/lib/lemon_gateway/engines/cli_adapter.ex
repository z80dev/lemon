defmodule LemonGateway.Engines.CliAdapter do
  @moduledoc """
  Shared CLI subprocess runner used by the Claude, Codex, Opencode, and Pi engines.

  Provides common logic for starting a CLI runner process, consuming its event
  stream, translating `AgentCore` events into `LemonGateway.Event` structs,
  and handling cancellation and resume token formatting.
  """

  alias AgentCore.CliRunners.Types.{ActionEvent, CompletedEvent, StartedEvent}
  alias LemonCore.ResumeToken
  alias LemonGateway.Event

  # AgentCore runners still emit %AgentCore.CliRunners.Types.ResumeToken{} structs
  # (which is a compatibility wrapper). We need to match on that struct in event handlers.
  alias AgentCore.CliRunners.Types.ResumeToken, as: CliResumeToken

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
        completed = %Event.Completed{engine: engine_id, ok: false, error: reason, answer: ""}
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

  def format_resume(engine_id, %ResumeToken{value: value}) do
    case engine_id do
      "codex" -> "codex resume #{value}"
      "claude" -> "claude --resume #{value}"
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

  def is_resume_line(engine_id, line) do
    ResumeToken.is_resume_line(line, engine_id)
  end

  defp start_runner(runner_module, engine_id, job, opts) do
    resume =
      case job.resume do
        %ResumeToken{engine: ^engine_id, value: value} ->
          LemonCore.ResumeToken.new(engine_id, value)

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

    # Pass tool_policy, session_key, and agent_id for approval context
    start_opts =
      start_opts
      |> maybe_put(:tool_policy, job.tool_policy)
      |> maybe_put(:session_key, job.session_key)
      |> maybe_put(:agent_id, get_in(job.meta || %{}, [:agent_id]))
      |> maybe_put(:model, get_in(job.meta || %{}, [:model]))
      |> maybe_put(:thinking_level, get_in(job.meta || %{}, [:thinking_level]))
      |> maybe_put(:system_prompt, get_in(job.meta || %{}, [:system_prompt]))
      |> maybe_put(:run_id, job.run_id || Map.get(opts, :run_id))
      |> maybe_put(:extra_tools, gateway_extra_tools(engine_id, job, opts))

    runner_module.start_link(start_opts)
  end

  defp gateway_extra_tools("lemon", job, opts) do
    cwd = job.cwd || Map.get(opts, :cwd) || File.cwd!()

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

    if telegram_session?(job) do
      workspace_dir = CodingAgent.Config.workspace_dir()

      [
        LemonGateway.Tools.TelegramSendImage.tool(
          cwd,
          session_key: job.session_key,
          workspace_dir: workspace_dir
        )
        | sms_tools
      ]
    else
      sms_tools
    end
  end

  defp gateway_extra_tools(_engine_id, _job, _opts), do: nil

  defp telegram_session?(job) do
    case LemonCore.SessionKey.parse(job.session_key || "") do
      %{kind: :channel_peer, channel_id: "telegram"} -> true
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

  defp consume_runner(runner_module, runner_pid, engine_id, sink_pid, run_ref) do
    stream = runner_module.stream(runner_pid)

    AgentCore.EventStream.events(stream)
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
    started = to_gateway_event(ev)
    send(sink_pid, {:engine_event, run_ref, started})
    acc
  end

  defp handle_stream_event({:cli_event, %ActionEvent{} = ev}, _engine_id, sink_pid, run_ref, acc) do
    action_event = to_gateway_event(ev)
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
    completed = to_gateway_event(ev)
    send(sink_pid, {:engine_event, run_ref, completed})
    %{acc | completed: true}
  end

  defp handle_stream_event({:error, reason, _}, engine_id, sink_pid, run_ref, acc) do
    if acc.completed do
      acc
    else
      completed = %Event.Completed{engine: engine_id, ok: false, error: reason, answer: ""}
      send(sink_pid, {:engine_event, run_ref, completed})
      %{acc | completed: true}
    end
  end

  defp handle_stream_event({:canceled, reason}, engine_id, sink_pid, run_ref, acc) do
    if acc.completed do
      acc
    else
      completed = %Event.Completed{engine: engine_id, ok: false, error: reason, answer: ""}
      send(sink_pid, {:engine_event, run_ref, completed})
      %{acc | completed: true}
    end
  end

  defp handle_stream_event(_event, _engine_id, _sink_pid, _run_ref, acc), do: acc

  def to_gateway_event(%StartedEvent{} = ev), do: to_gateway_started(ev)
  def to_gateway_event(%ActionEvent{} = ev), do: to_gateway_action(ev)
  def to_gateway_event(%CompletedEvent{} = ev), do: to_gateway_completed(ev)
  def to_gateway_event(_), do: nil

  defp to_gateway_started(%StartedEvent{
         engine: engine,
         resume: %CliResumeToken{value: value},
         title: title,
         meta: meta
       }) do
    %Event.Started{
      engine: engine,
      resume: %ResumeToken{engine: engine, value: value},
      title: title,
      meta: meta
    }
  end

  defp to_gateway_action(%ActionEvent{
         engine: engine,
         action: action,
         phase: phase,
         ok: ok,
         message: message,
         level: level
       }) do
    gw_action = %Event.Action{
      id: action.id,
      kind: to_string(action.kind),
      title: action.title,
      detail: action.detail
    }

    %Event.ActionEvent{
      engine: engine,
      action: gw_action,
      phase: phase,
      ok: ok,
      message: message,
      level: level
    }
  end

  defp to_gateway_completed(%CompletedEvent{} = ev) do
    resume =
      case ev.resume do
        %CliResumeToken{engine: engine, value: value} -> %ResumeToken{engine: engine, value: value}
        _ -> nil
      end

    %Event.Completed{
      engine: ev.engine,
      ok: ev.ok,
      answer: ev.answer,
      error: ev.error,
      usage: ev.usage,
      resume: resume
    }
  end

  defp maybe_put(list, _key, nil), do: list
  defp maybe_put(list, key, value), do: Keyword.put(list, key, value)
end
