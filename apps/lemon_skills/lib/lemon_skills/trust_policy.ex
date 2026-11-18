defmodule LemonSkills.TrustPolicy do
  @moduledoc """
  Defines install, update, and audit rules for each skill trust level.

  ## Trust Tier Hierarchy

  Skills carry one of four trust levels, assigned at install time based on
  their source. From highest to lowest trust:

  | Level       | Source                                  | Audit? | Auto-approve? |
  |-------------|-----------------------------------------|--------|---------------|
  | `:builtin`  | Bundled in `priv/builtin_skills/`       | No     | Yes           |
  | `:official` | `official/<category>/<name>` namespace  | Yes    | No            |
  | `:trusted`  | Local filesystem path you control       | Yes    | No            |
  | `:community`| Third-party git URL or unknown registry | Yes    | No            |

  ## Audit policy

  The audit engine scans SKILL.md content for destructive commands, remote
  code execution, data exfiltration, and path traversal patterns.

  All non-builtin skills are audited before install/update:
  - `:official` — curated content from the official skills registry namespace,
    but still scanned so `warn` and `block` findings are enforced consistently.
  - `:trusted` — files on the user's own filesystem, still scanned to catch
    accidental unsafe content and to drive warning acknowledgements.
  - `:community` — arbitrary third-party content, always scanned.

  ## Approval policy

  Only `:builtin` skills are auto-approved — they are embedded in the
  application itself and require no additional user consent at runtime.
  All other tiers require the user to explicitly approve install, update,
  and uninstall operations (unless globally disabled or pre-authorized).
  """

  alias LemonSkills.{Entry, SourceRouter}

  require Logger

  @doc """
  Returns `true` when the audit engine should scan skill content before install.

  Only `:builtin` skips the audit; every other value, including `nil` and any
  unknown level, fails closed.

  ## Examples

      iex> LemonSkills.TrustPolicy.requires_audit?(:builtin)
      false

      iex> LemonSkills.TrustPolicy.requires_audit?(:official)
      true

      iex> LemonSkills.TrustPolicy.requires_audit?(:trusted)
      true

      iex> LemonSkills.TrustPolicy.requires_audit?(:community)
      true

      iex> LemonSkills.TrustPolicy.requires_audit?(nil)
      true

      iex> LemonSkills.TrustPolicy.requires_audit?(:unknown)
      true
  """
  @spec requires_audit?(Entry.trust_level() | nil | term()) :: boolean()
  def requires_audit?(:builtin), do: false
  def requires_audit?(_), do: true

  @doc """
  Returns `true` when install/update/uninstall approval can be skipped.

  Only `:builtin` skills are auto-approved. All other trust levels require
  explicit user consent regardless of global approval settings.

  ## Examples

      iex> LemonSkills.TrustPolicy.auto_approve?(:builtin)
      true

      iex> LemonSkills.TrustPolicy.auto_approve?(:official)
      false

      iex> LemonSkills.TrustPolicy.auto_approve?(:trusted)
      false

      iex> LemonSkills.TrustPolicy.auto_approve?(:community)
      false

      iex> LemonSkills.TrustPolicy.auto_approve?(nil)
      false

      iex> LemonSkills.TrustPolicy.auto_approve?(:unknown)
      false
  """
  @spec auto_approve?(Entry.trust_level() | nil) :: boolean()
  def auto_approve?(:builtin), do: true
  def auto_approve?(_), do: false

  @doc """
  Reconciles lockfile provenance with what the recorded source can produce.

  Lockfile records are descriptive and, for projects, repository-controlled.
  A record's `source_kind`/`trust_level` pair is kept only when re-routing its
  `source_id` through `LemonSkills.SourceRouter` yields that same pair, or, for
  a record without a routable source, when it claims neither `builtin` kind nor
  `builtin` trust (a global builtin record with no `source_id` is the one
  exception; its bytes are verified against the shipped bundle wherever trust
  gates on it). Any other record takes the source-derived values (or `nil`)
  and an `audit_status` of `:pending`, unless it was `:block`.
  """
  @spec reconcile_provenance(Entry.t(), :global | {:project, String.t()}) :: Entry.t()
  def reconcile_provenance(%Entry{} = entry, scope) do
    expected = expected_provenance(entry, scope)
    claimed = {entry.source_kind, entry.trust_level}

    consistent? =
      case expected do
        nil -> entry.source_kind != :builtin and entry.trust_level != :builtin
        pair -> pair == claimed
      end

    if consistent? do
      entry
    else
      {kind, trust} = expected || {nil, nil}

      Logger.warning(
        "[TrustPolicy] lockfile provenance for '#{entry.key}' (#{inspect(claimed)}) " <>
          "does not match its source; treating it as #{inspect({kind, trust})} pending audit"
      )

      %{
        entry
        | source_kind: kind,
          trust_level: trust,
          audit_status: if(entry.audit_status == :block, do: :block, else: :pending)
      }
    end
  end

  defp expected_provenance(%Entry{source_id: id}, _scope) when is_binary(id) do
    case SourceRouter.resolve(id) do
      {:ok, mod, canonical} -> {SourceRouter.source_kind(mod), mod.trust_for_ref(canonical)}
      {:error, _} -> nil
    end
  end

  defp expected_provenance(%Entry{source_kind: :builtin}, :global), do: {:builtin, :builtin}
  defp expected_provenance(_entry, _scope), do: nil

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
    do: "From the official/ registry namespace; curated and still audited before install."

  def description(:trusted),
    do: "Installed from a local filesystem path you control and audited before install."

  def description(:community),
    do: "From a third-party source; audited for safety before installation."

  def description(nil), do: "Trust level not recorded for this skill."
end
