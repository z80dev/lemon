defmodule LemonGateway.Engines.Lemon do
  @moduledoc """
  Lemon engine that wraps CodingAgent for native LLM interactions.

  Unlike Codex and Claude engines which wrap external CLI tools via subprocess,
  the Lemon engine drives CodingAgent.Session directly for native AI interactions.

  ## Features

  - Native Elixir implementation (no subprocess spawning)
  - Full CodingAgent tool support (read, write, edit, bash, etc.)
  - Session persistence and resume
  - Steering support for mid-run message injection

  ## Example

      job = %Job{
        scope: scope,
        user_msg_id: 123,
        text: "Create a hello world function"
      }

      {:ok, run_ref, ctx} = Lemon.start_run(job, %{cwd: "/path/to/project"}, self())

      receive do
        {:engine_event, ^run_ref, %{__event__: :started, engine: "lemon"}} ->
          IO.puts("Session started")

        {:engine_event, ^run_ref, %{__event__: :completed, ok: true, answer: answer}} ->
          IO.puts("Answer: \#{answer}")
      end

  """
  @behaviour LemonGateway.Engine

  alias LemonGateway.Engines.CliAdapter
  alias LemonGateway.Engines.Lemon.SessionRunner
  alias LemonGateway.Event
  alias LemonCore.ResumeToken

  @session_module CodingAgent.Session

  @impl true
  def id, do: "lemon"

  @impl true
  def format_resume(%ResumeToken{} = token), do: CliAdapter.format_resume(id(), token)

  @impl true
  def extract_resume(text), do: CliAdapter.extract_resume(id(), text)

  @impl true
  def is_resume_line(line), do: CliAdapter.is_resume_line(id(), line)

  @impl true
  def supports_steer?, do: true

  @impl true
  def start_run(job, opts, sink_pid) do
    # Lemon engine depends on CodingAgent (+ Ai). In some entrypoints we may end up
    # calling engine modules before the dependent OTP apps are started (e.g. when
    # only a subset of applications is booted). Ensure they're running so provider
    # registries and supervisors are available.
    case LemonGateway.DependencyManager.ensure_app(:coding_agent) do
      :ok ->
        with :ok <- ensure_session_available() do
          start_session_runner(job, opts, sink_pid)
        end

      {:error, _reason} = error ->
        error
    end
  end

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

  def steer(_ctx, _text), do: {:error, :no_runner}

  defp start_session_runner(job, opts, sink_pid) do
    run_ref = make_ref()

    case SessionRunner.start_link(job: job, opts: opts, sink_pid: sink_pid, run_ref: run_ref) do
      {:ok, runner_pid} ->
        {:ok, run_ref, %{runner_pid: runner_pid}}

      {:error, reason} ->
        completed = Event.completed(%{engine: id(), ok: false, error: reason, answer: ""})
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
