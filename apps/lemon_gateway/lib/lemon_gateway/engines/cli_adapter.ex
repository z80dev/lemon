defmodule LemonGateway.Engines.CliAdapter do
  @moduledoc false

  alias AgentCore.CliRunners.Types.{ActionEvent, CompletedEvent, ResumeToken, StartedEvent}
  alias LemonGateway.Event
  alias LemonGateway.Types.ResumeToken, as: GatewayToken

  def start_run(runner_module, engine_id, job, opts, sink_pid) do
    run_ref = make_ref()

    case start_runner(runner_module, engine_id, job, opts) do
      {:ok, runner_pid} ->
        {:ok, task_pid} =
          Task.start_link(fn ->
            consume_runner(runner_module, runner_pid, engine_id, sink_pid, run_ref)
          end)

        {:ok, run_ref, %{task_pid: task_pid, runner_pid: runner_pid, runner_module: runner_module}}

      {:error, reason} ->
        completed = %Event.Completed{engine: engine_id, ok: false, error: reason, answer: ""}
        send(sink_pid, {:engine_event, run_ref, completed})
        {:ok, run_ref, %{task_pid: nil, runner_pid: nil, runner_module: runner_module}}
    end
  end

  def cancel(%{runner_pid: pid, runner_module: mod}) when is_pid(pid) do
    mod.cancel(pid, :user_requested)
    :ok
  end

  def cancel(%{task_pid: pid}) when is_pid(pid) do
    Process.exit(pid, :kill)
    :ok
  end

  def format_resume(engine_id, %GatewayToken{value: value}) do
    case engine_id do
      "codex" -> "codex resume #{value}"
      "claude" -> "claude --resume #{value}"
      _ -> "#{engine_id} resume #{value}"
    end
  end

  def extract_resume(engine_id, text) do
    case ResumeToken.extract_resume(text, engine_id) do
      %ResumeToken{engine: ^engine_id, value: value} -> %GatewayToken{engine: engine_id, value: value}
      _ -> nil
    end
  end

  def is_resume_line(engine_id, line) do
    ResumeToken.is_resume_line(line, engine_id)
  end

  defp start_runner(runner_module, engine_id, job, opts) do
    resume =
      case job.resume do
        %GatewayToken{engine: ^engine_id, value: value} -> ResumeToken.new(engine_id, value)
        _ -> nil
      end

    start_opts = [
      prompt: job.text,
      resume: resume,
      owner: self()
    ]

    start_opts =
      start_opts
      |> maybe_put(:cwd, Map.get(opts, :cwd))
      |> maybe_put(:env, Map.get(opts, :env))
      |> maybe_put(:timeout, Map.get(opts, :timeout_ms))

    runner_module.start_link(start_opts)
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

  defp handle_stream_event({:cli_event, %CompletedEvent{} = ev}, _engine_id, sink_pid, run_ref, acc) do
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

  defp to_gateway_started(%StartedEvent{engine: engine, resume: %ResumeToken{value: value}, title: title, meta: meta}) do
    %Event.Started{engine: engine, resume: %GatewayToken{engine: engine, value: value}, title: title, meta: meta}
  end

  defp to_gateway_action(%ActionEvent{engine: engine, action: action, phase: phase, ok: ok, message: message, level: level}) do
    gw_action = %Event.Action{
      id: action.id,
      kind: to_string(action.kind),
      title: action.title,
      detail: action.detail
    }

    %Event.ActionEvent{engine: engine, action: gw_action, phase: phase, ok: ok, message: message, level: level}
  end

  defp to_gateway_completed(%CompletedEvent{} = ev) do
    resume =
      case ev.resume do
        %ResumeToken{engine: engine, value: value} -> %GatewayToken{engine: engine, value: value}
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
