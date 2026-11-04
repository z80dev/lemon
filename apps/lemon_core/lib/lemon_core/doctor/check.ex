defmodule LemonCore.Doctor.Check do
  @moduledoc """
  A single diagnostic check result.

  Each check has a name, a status, a human-readable message, and an optional
  remediation hint to help the user fix failing checks.

  ## Statuses

  | Status  | Meaning |
  |---------|---------|
  | `:pass` | Check succeeded — no action needed. |
  | `:warn` | Check found a potential problem — system may still work. |
  | `:fail` | Check failed — action required. |
  | `:skip` | Check was intentionally not run (e.g. dependency not available). |
  """

  @enforce_keys [:name, :status]
  defstruct [:name, :status, :message, :remediation]

  @type status :: :pass | :warn | :fail | :skip

  @type t :: %__MODULE__{
          name: String.t(),
          status: status(),
          message: String.t() | nil,
          remediation: String.t() | nil
        }

  @doc "Builds a passing check."
  @spec pass(String.t(), String.t()) :: t()
  def pass(name, message \\ "OK") do
    %__MODULE__{name: name, status: :pass, message: message}
  end

  @doc "Builds a warning check."
  @spec warn(String.t(), String.t(), String.t() | nil) :: t()
  def warn(name, message, remediation \\ nil) do
    %__MODULE__{name: name, status: :warn, message: message, remediation: remediation}
  end

  @doc "Builds a failing check."
  @spec fail(String.t(), String.t(), String.t() | nil) :: t()
  def fail(name, message, remediation \\ nil) do
    %__MODULE__{name: name, status: :fail, message: message, remediation: remediation}
  end

  @doc "Builds a skipped check."
  @spec skip(String.t(), String.t()) :: t()
  def skip(name, message \\ "Skipped") do
    %__MODULE__{name: name, status: :skip, message: message}
  end

  @doc """
  Builds the skip for a check whose subject lives in the runtime process.

  `runtime` is the `:runtime` option `LemonCore.Doctor.report/1` passes to
  check modules: `:external` when a standalone CLI found a separate healthy
  runtime, `:absent` when no runtime answered.
  """
  @spec outside_runtime(String.t(), String.t(), :external | :absent) :: t()
  def outside_runtime(name, subject, :external) do
    skip(
      name,
      "A separate Lemon runtime is healthy; #{subject} cannot be checked from this CLI process."
    )
  end

  def outside_runtime(name, subject, :absent) do
    skip(
      name,
      "No Lemon runtime is running, so #{subject} was not checked. " <>
        "Start Lemon with `lemon` or `lemon start`, then run `lemon doctor` again."
    )
  end

  @doc "Returns the ANSI color atom for a status."
  @spec color(status()) :: atom()
  def color(:pass), do: :green
  def color(:warn), do: :yellow
  def color(:fail), do: :red
  def color(:skip), do: :cyan

  @doc "Returns the display label for a status."
  @spec label(status()) :: String.t()
  def label(:pass), do: "pass"
  def label(:warn), do: "warn"
  def label(:fail), do: "FAIL"
  def label(:skip), do: "skip"
end
