defmodule LemonCore.Doctor do
  @moduledoc """
  Runs the Lemon doctor check suite and builds the aggregate diagnostic report used by CLI and support tooling.
  """
  alias LemonCore.Doctor.Checks.{
    ACP,
    Browser,
    Channels,
    Config,
    Cron,
    Extensions,
    LSP,
    Media,
    MCP,
    NodeTools,
    OpenAICompat,
    Providers,
    Runtime,
    Secrets,
    Skills,
    TerminalBackends,
    Usage
  }

  alias LemonCore.Doctor.Report

  @spec checks(keyword()) :: [LemonCore.Doctor.Check.t()]
  def checks(opts \\ []) do
    []
    |> append_checks(Config.run(opts))
    |> append_checks(Secrets.run(opts))
    |> append_checks(Runtime.run(opts))
    |> append_checks(Providers.run(opts))
    |> append_checks(Usage.run(opts))
    |> append_checks(Channels.run(opts))
    |> append_checks(Media.run(opts))
    |> append_checks(Browser.run(opts))
    |> append_checks(Cron.run(opts))
    |> append_checks(TerminalBackends.run(opts))
    |> append_checks(OpenAICompat.run(opts))
    |> append_checks(ACP.run(opts))
    |> append_checks(MCP.run(opts))
    |> append_checks(LSP.run(opts))
    |> append_checks(Extensions.run(opts))
    |> append_checks(NodeTools.run(opts))
    |> append_checks(Skills.run(opts))
  end

  @spec report(keyword()) :: Report.t()
  def report(opts \\ []) do
    opts
    |> checks()
    |> Report.from_checks()
  end

  defp append_checks(acc, checks), do: acc ++ checks
end
