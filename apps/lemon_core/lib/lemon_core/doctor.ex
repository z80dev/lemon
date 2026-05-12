defmodule LemonCore.Doctor do
  alias LemonCore.Doctor.Checks.{Config, NodeTools, Providers, Runtime, Secrets, Skills}
  alias LemonCore.Doctor.Report

  @spec checks(keyword()) :: [LemonCore.Doctor.Check.t()]
  def checks(opts \\ []) do
    []
    |> append_checks(Config.run(opts))
    |> append_checks(Secrets.run(opts))
    |> append_checks(Runtime.run(opts))
    |> append_checks(Providers.run(opts))
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
