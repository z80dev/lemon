defmodule CodingAgent.Executor do
  @moduledoc """
  Native executor for in-process `CodingAgent.Session` runs.

  Starts a session runner for each submitted execution request.
  """

  @behaviour LemonGateway.Executor

  alias CodingAgent.Executor.SessionRunner
  alias LemonGateway.Event
  alias LemonGateway.ExecutionRequest

  @session_module CodingAgent.Session
  @engine "lemon"

  @impl true
  def start_run(%ExecutionRequest{} = request, opts, sink_pid) when is_pid(sink_pid) do
    # An entrypoint may boot only a subset of applications, so make sure the
    # agent's own supervision tree (provider registries, session supervisor) is
    # running before starting a session.
    case Application.ensure_all_started(:coding_agent) do
      {:ok, _started} ->
        with :ok <- ensure_session_available() do
          start_session_runner(request, opts, sink_pid)
        end

      {:error, reason} ->
        {:error, {:coding_agent_unavailable, reason}}
    end
  end

  def start_run(_request, _opts, _sink_pid), do: {:error, :invalid_execution_request}

  @impl true
  def cancel(%{runner_pid: pid}) when is_pid(pid) do
    SessionRunner.cancel(pid, :user_requested)
    :ok
  end

  def cancel(_ctx), do: :ok

  @impl true
  def steer(%{runner_pid: pid}, text) when is_pid(pid) do
    SessionRunner.steer(pid, text)
  end

  def steer(_ctx, _text), do: {:error, :unsupported}

  @impl true
  def redirect(%{runner_pid: pid}, text) when is_pid(pid) do
    SessionRunner.redirect(pid, text)
  end

  def redirect(_ctx, _text), do: {:error, :unsupported}

  defp start_session_runner(request, opts, sink_pid) do
    run_ref = make_ref()

    case SessionRunner.start_link(
           request: request,
           opts: opts,
           sink_pid: sink_pid,
           run_ref: run_ref
         ) do
      {:ok, runner_pid} ->
        {:ok, run_ref, %{runner_pid: runner_pid}}

      {:error, reason} ->
        completed = Event.completed(%{engine: @engine, ok: false, error: reason, answer: ""})
        send(sink_pid, {:engine_event, run_ref, completed})
        {:ok, run_ref, %{runner_pid: nil}}
    end
  end

  defp ensure_session_available do
    case Code.ensure_loaded(@session_module) do
      {:module, @session_module} ->
        if function_exported?(@session_module, :start_link, 1) do
          :ok
        else
          {:error, {:session_unavailable, @session_module}}
        end

      {:error, reason} ->
        {:error, {:session_unavailable, @session_module, reason}}
    end
  end
end
