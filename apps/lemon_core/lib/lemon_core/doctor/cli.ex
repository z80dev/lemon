defmodule LemonCore.Doctor.CLI do
  alias LemonCore.Doctor
  alias LemonCore.Doctor.{Report, SupportBundle}

  @spec bundle!(keyword()) :: String.t()
  def bundle!(opts \\ []) do
    report = Doctor.report(opts)

    case SupportBundle.write(report, opts) do
      {:ok, path} ->
        IO.puts("Support bundle written: #{path}")

        unless Report.ok?(report) do
          IO.puts(:stderr, "Diagnostics failed: #{report.fail} check(s) failed.")
        end

        path

      {:error, reason} ->
        raise "Failed to write support bundle: #{inspect(reason)}"
    end
  end
end
