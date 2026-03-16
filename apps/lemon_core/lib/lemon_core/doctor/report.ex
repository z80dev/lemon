defmodule LemonCore.Doctor.Report do
  @moduledoc """
  Aggregates diagnostic check results and renders them as text or JSON.

  ## Usage

      checks = [...list of %Check{}...]
      report = Report.from_checks(checks)

      Report.print(report)                     # human-readable output
      Report.print(report, verbose: true)      # include pass/skip details
      Report.to_json(report)                   # JSON string
      Report.ok?(report)                       # true if no failures
  """

  alias LemonCore.Doctor.Check

  defstruct [:checks, :pass, :warn, :fail, :skip]

  @type t :: %__MODULE__{
          checks: [Check.t()],
          pass: non_neg_integer(),
          warn: non_neg_integer(),
          fail: non_neg_integer(),
          skip: non_neg_integer()
        }

  @doc "Builds a Report from a list of Check structs."
  @spec from_checks([Check.t()]) :: t()
  def from_checks(checks) when is_list(checks) do
    counts =
      Enum.reduce(checks, %{pass: 0, warn: 0, fail: 0, skip: 0}, fn check, acc ->
        Map.update!(acc, check.status, &(&1 + 1))
      end)

    %__MODULE__{
      checks: checks,
      pass: counts.pass,
      warn: counts.warn,
      fail: counts.fail,
      skip: counts.skip
    }
  end

  @doc "Returns `true` when no checks have `:fail` status."
  @spec ok?(t()) :: boolean()
  def ok?(%__MODULE__{fail: 0}), do: true
  def ok?(%__MODULE__{}), do: false

  @doc "Returns the overall status atom (`:pass`, `:warn`, or `:fail`)."
  @spec overall(t()) :: :pass | :warn | :fail
  def overall(%__MODULE__{fail: f}) when f > 0, do: :fail
  def overall(%__MODULE__{warn: w}) when w > 0, do: :warn
  def overall(%__MODULE__{}), do: :pass

  @doc """
  Prints a formatted report to the Mix shell.

  ## Options

    * `:verbose` - include pass and skip results (default: false)
  """
  @spec print(t(), keyword()) :: :ok
  def print(%__MODULE__{} = report, opts \\ []) do
    verbose? = Keyword.get(opts, :verbose, false)
    shell = Mix.shell()

    shell.info("")
    shell.info("Lemon Doctor")
    shell.info("────────────")

    Enum.each(report.checks, fn check ->
      if verbose? or check.status in [:warn, :fail] do
        print_check(shell, check, verbose?)
      end
    end)

    print_summary(shell, report)
    :ok
  end

  @doc "Serialises the report to a JSON string."
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = report) do
    data = %{
      "overall" => Atom.to_string(overall(report)),
      "summary" => %{
        "pass" => report.pass,
        "warn" => report.warn,
        "fail" => report.fail,
        "skip" => report.skip
      },
      "checks" =>
        Enum.map(report.checks, fn c ->
          %{
            "name" => c.name,
            "status" => Atom.to_string(c.status),
            "message" => c.message,
            "remediation" => c.remediation
          }
        end)
    }

    Jason.encode!(data, pretty: true)
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Private helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp print_check(shell, %Check{} = check, verbose?) do
    status_label = String.pad_trailing("[#{Check.label(check.status)}]", 7)
    color = Check.color(check.status)

    shell.info([color, status_label, :reset, " #{check.name}"])

    if verbose? or check.status in [:warn, :fail] do
      if check.message && check.message != "OK" do
        shell.info("        #{check.message}")
      end

      if check.remediation do
        shell.info([:cyan, "        → #{check.remediation}", :reset])
      end
    end
  end

  defp print_summary(shell, %__MODULE__{} = report) do
    color = Check.color(overall(report))

    shell.info("")
    shell.info([
      color,
      "#{report.pass} passed  #{report.warn} warnings  #{report.fail} failed  #{report.skip} skipped",
      :reset
    ])

    shell.info("")
  end
end
