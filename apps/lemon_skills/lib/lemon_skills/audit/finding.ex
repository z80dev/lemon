defmodule LemonSkills.Audit.Finding do
  @moduledoc """
  A single audit finding from a skill content scan.

  ## Fields

  - `:rule` — machine-readable rule identifier (e.g. `"remote_exec"`)
  - `:severity` — `:warn` (soft, requires approval) or `:block` (hard reject)
  - `:message` — human-readable description of the finding
  - `:match` — the snippet that triggered the rule (for display)
  """

  @enforce_keys [:rule, :severity, :message]
  defstruct [:rule, :severity, :message, :match]

  @type severity :: :warn | :block

  @type t :: %__MODULE__{
          rule: String.t(),
          severity: severity(),
          message: String.t(),
          match: String.t() | nil
        }

  @doc "Builds a `:warn` finding."
  @spec warn(String.t(), String.t(), String.t() | nil) :: t()
  def warn(rule, message, match \\ nil) do
    %__MODULE__{rule: rule, severity: :warn, message: message, match: match}
  end

  @doc "Builds a `:block` finding."
  @spec block(String.t(), String.t(), String.t() | nil) :: t()
  def block(rule, message, match \\ nil) do
    %__MODULE__{rule: rule, severity: :block, message: message, match: match}
  end

  @doc "Returns a human-readable summary string."
  @spec summary(t()) :: String.t()
  def summary(%__MODULE__{severity: sev, rule: rule, message: msg}) do
    "[#{sev}] #{rule}: #{msg}"
  end

  @doc "Returns `true` when the finding blocks installation."
  @spec blocks_install?(t()) :: boolean()
  def blocks_install?(%__MODULE__{severity: :block}), do: true
  def blocks_install?(%__MODULE__{}), do: false
end
