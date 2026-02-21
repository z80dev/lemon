defmodule LemonGateway.Engines.Claude do
  @moduledoc """
  Engine adapter for the Claude Code CLI tool.

  Delegates to `LemonGateway.Engines.CliAdapter` to manage a
  `AgentCore.CliRunners.ClaudeRunner` subprocess for each run.
  """
  @behaviour LemonGateway.Engine

  alias LemonGateway.Engines.CliAdapter
  alias LemonGateway.Types.ResumeToken

  @impl true
  def id, do: "claude"

  @impl true
  def format_resume(%ResumeToken{} = token), do: CliAdapter.format_resume(id(), token)

  @impl true
  def extract_resume(text), do: CliAdapter.extract_resume(id(), text)

  @impl true
  def is_resume_line(line), do: CliAdapter.is_resume_line(id(), line)

  @impl true
  def supports_steer?, do: false

  @impl true
  def start_run(job, opts, sink_pid) do
    CliAdapter.start_run(AgentCore.CliRunners.ClaudeRunner, id(), job, opts, sink_pid)
  end

  @impl true
  def cancel(ctx), do: CliAdapter.cancel(ctx)
end
