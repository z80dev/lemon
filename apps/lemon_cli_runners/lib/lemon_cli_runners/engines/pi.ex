defmodule LemonCliRunners.Engines.Pi do
  @moduledoc """
  Gateway engine adapter for the Pi runner CLI tool.

  Delegates to `LemonGateway.Engines.CliAdapter` to manage a
  `LemonCliRunners.PiRunner` subprocess for each run. Registered with
  `LemonGateway.EngineRegistry` at boot by `LemonCliRunners.Application`,
  so the gateway itself never names this vendor.
  """
  @behaviour LemonGateway.Engine

  alias LemonCore.ResumeToken
  alias LemonGateway.Engines.CliAdapter

  @impl true
  def id, do: "pi"

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
    CliAdapter.start_run(LemonCliRunners.PiRunner, id(), job, opts, sink_pid)
  end

  @impl true
  def cancel(ctx), do: CliAdapter.cancel(ctx)
end
