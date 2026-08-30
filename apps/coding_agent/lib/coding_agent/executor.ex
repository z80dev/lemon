defmodule CodingAgent.Executor do
  @moduledoc """
  Native executor for local and named-node `CodingAgent.Session` runs.

  Requests with no execution node, or with `node: "local"`, start the normal
  in-process session runner. A named node starts a remote runner backed by
  `LemonCore.NodeRegistry`; model credentials are always resolved by the
  destination because executor options are never serialized to that node.
  """

  @behaviour LemonGateway.Executor

  alias CodingAgent.Executor.{RemoteSessionRunner, SessionRunner}
  alias CodingAgent.Session.Presentation
  alias LemonCore.ResumeToken
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
  def cancel(%{runner_pid: pid, runner_module: RemoteSessionRunner}) when is_pid(pid) do
    RemoteSessionRunner.cancel(pid, :user_requested)
  end

  def cancel(%{runner_pid: pid}) when is_pid(pid) do
    SessionRunner.cancel(pid, :user_requested)
    :ok
  end

  def cancel(_ctx), do: :ok

  @impl true
  def steer(%{runner_module: RemoteSessionRunner}, _text), do: {:error, :unsupported}

  def steer(%{runner_pid: pid}, text) when is_pid(pid) do
    SessionRunner.steer(pid, text)
  end

  def steer(_ctx, _text), do: {:error, :unsupported}

  @impl true
  def redirect(%{runner_module: RemoteSessionRunner}, _text), do: {:error, :unsupported}

  def redirect(%{runner_pid: pid}, text) when is_pid(pid) do
    SessionRunner.redirect(pid, text)
  end

  def redirect(_ctx, _text), do: {:error, :unsupported}

  defp start_session_runner(request, opts, sink_pid) do
    case execution_node(request) do
      nil -> start_local_session_runner(request, opts, sink_pid)
      "local" -> start_local_session_runner(request, opts, sink_pid)
      node -> start_remote_session_runner(node, request, opts, sink_pid)
    end
  end

  defp start_local_session_runner(request, opts, sink_pid) do
    run_ref = make_ref()
    cwd = request.cwd || get_opt(opts, :cwd) || File.cwd!()
    resume = normalize_resume(request.resume)
    resume_source = get_resume_source(request)

    session_opts = [
      resume_source: resume_source
    ]

    with :ok <- Presentation.validate_resume_for_start(resume, session_opts, cwd),
         {:ok, runner_pid} <-
           SessionRunner.start_link(
             request: request,
             opts: opts,
             sink_pid: sink_pid,
             run_ref: run_ref
           ) do
      {:ok, run_ref, %{runner_pid: runner_pid}}
    else
      {:error, reason} ->
        completed = Event.completed(%{engine: @engine, ok: false, error: reason, answer: ""})
        send(sink_pid, {:engine_event, run_ref, completed})
        {:error, reason}
    end
  end

  defp start_remote_session_runner(node, request, opts, sink_pid) do
    run_ref = make_ref()

    case RemoteSessionRunner.start_link(
           node: node,
           request: request,
           opts: opts,
           sink_pid: sink_pid,
           run_ref: run_ref
         ) do
      {:ok, runner_pid} ->
        {:ok, run_ref, %{runner_pid: runner_pid, runner_module: RemoteSessionRunner}}

      {:error, reason} ->
        completed = Event.completed(%{engine: @engine, ok: false, error: reason, answer: ""})
        send(sink_pid, {:engine_event, run_ref, completed})
        {:error, reason}
    end
  end

  defp normalize_resume(%ResumeToken{engine: @engine} = token), do: token

  defp normalize_resume(%{engine: @engine, value: value}) when is_binary(value),
    do: ResumeToken.new(@engine, value)

  defp normalize_resume(_), do: nil

  defp get_resume_source(request) do
    meta = request.meta || %{}

    case meta[:resume_source] || meta["resume_source"] do
      :auto -> :auto
      "auto" -> :auto
      _ -> :explicit
    end
  end

  defp execution_node(request) do
    meta = request.meta || %{}

    case meta[:node] || meta["node"] do
      node when is_binary(node) ->
        node = String.trim(node)
        if node == "", do: nil, else: node

      _ ->
        nil
    end
  end

  defp get_opt(opts, key) when is_map(opts), do: Map.get(opts, key)
  defp get_opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp get_opt(_opts, _key), do: nil

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
