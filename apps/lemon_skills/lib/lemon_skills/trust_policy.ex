defmodule LemonSkills.TrustPolicy do
  @moduledoc """
  Defines install, update, and audit rules for each skill trust level.

  ## Trust Tier Hierarchy

  Skills carry one of four trust levels, assigned at install time based on
  their source. From highest to lowest trust:

  | Level       | Source                                  | Audit? | Auto-approve? |
  |-------------|-----------------------------------------|--------|---------------|
  | `:builtin`  | Bundled in `priv/builtin_skills/`       | No     | Yes           |
  | `:official` | `official/<category>/<name>` namespace  | No     | No            |
  | `:trusted`  | Local filesystem path you control       | No     | No            |
  | `:community`| Third-party git URL or unknown registry | Yes    | No            |

  ## Audit policy

  The audit engine scans SKILL.md content for destructive commands, remote
  code execution, data exfiltration, and path traversal patterns.

  `:community` skills are always audited — they come from arbitrary third-party
  sources and may contain unsafe instructions.

  `:builtin`, `:official`, and `:trusted` skills skip the audit:
  - `:builtin` — pre-vetted and bundled by the Lemon application maintainers.
  - `:official` — curated content from the official skills registry namespace.
  - `:trusted` — files on the user's own filesystem, which they control
    directly and can inspect at any time.

  ## Approval policy

  Only `:builtin` skills are auto-approved — they are embedded in the
  application itself and require no additional user consent at runtime.
  All other tiers require the user to explicitly approve install, update,
  and uninstall operations (unless globally disabled or pre-authorized).
  """

  alias LemonSkills.Entry

  @doc """
  Returns `true` when the audit engine should scan skill content before install.

  ## Examples

      iex> LemonSkills.TrustPolicy.requires_audit?(:community)
      true

      iex> LemonSkills.TrustPolicy.requires_audit?(:official)
      false
  """
  @spec requires_audit?(Entry.trust_level() | nil) :: boolean()
  def requires_audit?(:community), do: true
  def requires_audit?(nil), do: true
  def requires_audit?(_), do: false

  @doc """
  Returns `true` when install/update/uninstall approval can be skipped.

  Only `:builtin` skills are auto-approved. All other trust levels require
  explicit user consent regardless of global approval settings.

  ## Examples

      iex> LemonSkills.TrustPolicy.auto_approve?(:builtin)
      true

      iex> LemonSkills.TrustPolicy.auto_approve?(:community)
      false
  """
  @spec auto_approve?(Entry.trust_level() | nil) :: boolean()
  def auto_approve?(:builtin), do: true
  def auto_approve?(_), do: false

  @doc """
  Returns a short human-readable label for the trust level.

  ## Examples

      iex> LemonSkills.TrustPolicy.label(:official)
      "Official"
  """
  @spec label(Entry.trust_level() | nil) :: String.t()
  def label(:builtin), do: "Built-in"
  def label(:official), do: "Official"
  def label(:trusted), do: "Trusted"
  def label(:community), do: "Community"
  def label(nil), do: "Unknown"

  @doc """
  Returns a description of what the trust level means.
  """
  @spec description(Entry.trust_level() | nil) :: String.t()
  def description(:builtin),
    do: "Pre-bundled with the Lemon application; always safe."

  def description(:official),
    do: "From the official/ registry namespace; curated and verified."

  def description(:trusted),
    do: "Installed from a local filesystem path you control."

  def description(:community),
    do: "From a third-party source; audited for safety before installation."

  def description(nil), do: "Trust level not recorded for this skill."
end
