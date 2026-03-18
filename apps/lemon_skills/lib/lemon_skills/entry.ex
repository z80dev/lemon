defmodule LemonSkills.Entry do
  @moduledoc """
  Skill entry struct representing a registered skill.

  Contains all metadata about a skill including its manifest, source
  provenance, trust level, content hashes, install timestamps, and audit
  status.

  ## v1 fields (always present)

  - `key` — unique identifier (typically the directory name)
  - `name` — human-readable display name
  - `description` — brief description for relevance matching
  - `source` — legacy install location atom (`:global`, `:project`) or URL
  - `path` — absolute path to the skill directory
  - `enabled` — whether the skill is currently enabled
  - `manifest` — parsed manifest data (see `LemonSkills.Manifest`)
  - `status` — current status atom

  ## v2 provenance fields (optional, nil when absent)

  - `source_kind` — one of `:builtin`, `:local`, `:git`, `:registry`, `:well_known`
  - `source_id` — original install identifier (URL, path, registry ref)
  - `trust_level` — one of `:builtin`, `:official`, `:trusted`, `:community`
  - `content_hash` — SHA-256 hex of the installed `SKILL.md` content
  - `bundle_hash` — SHA-256 hex of the auditable bundle (`SKILL.md` + supported files)
  - `upstream_hash` — last known remote hash (used for update detection)
  - `installed_at` — `DateTime` of first install
  - `updated_at` — `DateTime` of last update
  - `audit_status` — `:pending`, `:pass`, `:warn`, or `:block`
  - `audit_findings` — list of audit finding strings

  Backward-compatible: all v2 fields default to `nil`. Existing call sites
  that only read v1 fields continue to work without changes.

  ## Examples

      %LemonSkills.Entry{
        key: "k8s-rollout",
        name: "K8s Rollout",
        description: "Manage Kubernetes rollouts",
        source: :global,
        path: "/home/user/.lemon/agent/skill/k8s-rollout",
        enabled: true,
          source_kind: :git,
          source_id: "https://github.com/acme/k8s-rollout-skill",
          trust_level: :community,
          content_hash: "abc123...",
          bundle_hash: "def456...",
          installed_at: ~U[2026-01-01 00:00:00Z]
      }
  """

  @type source :: :global | :project | String.t()
  @type status :: :ready | :missing_deps | :missing_config | :disabled | :error
  @type source_kind :: :builtin | :local | :git | :registry | :well_known
  @type trust_level :: :builtin | :official | :trusted | :community
  @type audit_status :: :pending | :pass | :warn | :block

  @type t :: %__MODULE__{
          key: String.t(),
          name: String.t(),
          description: String.t(),
          source: source(),
          path: String.t(),
          enabled: boolean(),
          manifest: map() | nil,
          status: status(),
          # v2 provenance
          source_kind: source_kind() | nil,
          source_id: String.t() | nil,
          trust_level: trust_level() | nil,
          content_hash: String.t() | nil,
          bundle_hash: String.t() | nil,
          upstream_hash: String.t() | nil,
          installed_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil,
          audit_status: audit_status() | nil,
          audit_findings: [String.t()]
        }

  @enforce_keys [:key, :path]
  defstruct [
    :key,
    :name,
    :description,
    :source,
    :path,
    :manifest,
    # v2
    :source_kind,
    :source_id,
    :trust_level,
    :content_hash,
    :bundle_hash,
    :upstream_hash,
    :installed_at,
    :updated_at,
    :audit_status,
    enabled: true,
    status: :ready,
    audit_findings: []
  ]

  # ---------------------------------------------------------------------------
  # Constructors
  # ---------------------------------------------------------------------------

  @doc """
  Create a new skill entry from a local path.

  ## Options

  - `:source` — legacy source atom (`:global`, `:project`, or string URL)
  - `:source_kind` — v2 source kind atom
  - `:source_id` — original install identifier
  - `:trust_level` — trust level atom
  - `:enabled` — whether enabled (default: `true`)
  """
  @spec new(String.t(), keyword()) :: t()
  def new(path, opts \\ []) do
    key = Path.basename(path)

    %__MODULE__{
      key: key,
      name: key,
      description: "",
      source: Keyword.get(opts, :source, :global),
      path: path,
      enabled: Keyword.get(opts, :enabled, true),
      manifest: nil,
      status: :ready,
      source_kind: Keyword.get(opts, :source_kind),
      source_id: Keyword.get(opts, :source_id),
      trust_level: Keyword.get(opts, :trust_level),
      content_hash: Keyword.get(opts, :content_hash),
      bundle_hash: Keyword.get(opts, :bundle_hash),
      upstream_hash: Keyword.get(opts, :upstream_hash),
      installed_at: Keyword.get(opts, :installed_at),
      updated_at: Keyword.get(opts, :updated_at),
      audit_status: Keyword.get(opts, :audit_status),
      audit_findings: Keyword.get(opts, :audit_findings, [])
    }
  end

  @doc """
  Create a new skill entry from a discovered manifest (online source).

  ## Options

  - `:source` — source atom (`:github`, `:registry`, etc.)
  - `:source_kind` — v2 source kind atom
  - `:trust_level` — trust level atom
  - `:metadata` — additional metadata stored in `manifest["_discovery_metadata"]`
  """
  @spec from_manifest(map(), String.t(), keyword()) :: t()
  def from_manifest(manifest, url, opts \\ []) when is_map(manifest) do
    key =
      Map.get(manifest, "key") ||
        manifest |> Map.get("name", "discovered") |> String.downcase() |> String.replace(" ", "-")

    source = Keyword.get(opts, :source, :discovered)
    metadata = Keyword.get(opts, :metadata, %{})
    manifest_with_meta = Map.put(manifest, "_discovery_metadata", metadata)

    %__MODULE__{
      key: key,
      name: Map.get(manifest, "name", key),
      description: Map.get(manifest, "description", ""),
      source: source,
      path: url,
      enabled: true,
      manifest: manifest_with_meta,
      status: :ready,
      source_kind: Keyword.get(opts, :source_kind),
      source_id: url,
      trust_level: Keyword.get(opts, :trust_level),
      audit_findings: []
    }
  end

  # ---------------------------------------------------------------------------
  # Updaters
  # ---------------------------------------------------------------------------

  @doc "Apply parsed manifest data to the entry."
  @spec with_manifest(t(), map()) :: t()
  def with_manifest(%__MODULE__{} = entry, manifest) when is_map(manifest) do
    %{
      entry
      | name: Map.get(manifest, "name", entry.key),
        description: Map.get(manifest, "description", ""),
        manifest: manifest
    }
  end

  @doc "Set the status of the entry."
  @spec with_status(t(), status()) :: t()
  def with_status(%__MODULE__{} = entry, status), do: %{entry | status: status}

  @doc "Apply v2 provenance fields from a lockfile record."
  @spec with_provenance(t(), map()) :: t()
  def with_provenance(%__MODULE__{} = entry, prov) when is_map(prov) do
    %{
      entry
      | source_kind: parse_atom(prov["source_kind"]),
        source_id: prov["source_id"],
        trust_level: parse_atom(prov["trust_level"]),
        content_hash: prov["content_hash"],
        bundle_hash: prov["bundle_hash"],
        upstream_hash: prov["upstream_hash"],
        installed_at: parse_datetime(prov["installed_at"]),
        updated_at: parse_datetime(prov["updated_at"]),
        audit_status: parse_atom(prov["audit_status"]),
        audit_findings: List.wrap(prov["audit_findings"])
    }
  end

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  @doc "Return `true` if the skill is ready (enabled and no missing deps)."
  @spec ready?(t()) :: boolean()
  def ready?(%__MODULE__{enabled: false}), do: false
  def ready?(%__MODULE__{status: :ready}), do: true
  def ready?(_), do: false

  @doc "Return the path to the SKILL.md file."
  @spec skill_file(t()) :: String.t()
  def skill_file(%__MODULE__{path: path}), do: Path.join(path, "SKILL.md")

  @doc "Read the SKILL.md content."
  @spec content(t()) :: {:ok, String.t()} | {:error, term()}
  def content(%__MODULE__{} = entry), do: entry |> skill_file() |> File.read()

  @doc """
  Compute the SHA-256 hex digest of the entry's SKILL.md content.

  Returns `nil` when the file cannot be read.
  """
  @spec compute_content_hash(t()) :: String.t() | nil
  def compute_content_hash(%__MODULE__{} = entry) do
    case content(entry) do
      {:ok, data} ->
        :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

      _ ->
        nil
    end
  end

  @doc """
  Compute the SHA-256 hex digest of the full auditable skill bundle.

  Returns `nil` when the bundle cannot be read.
  """
  @spec compute_bundle_hash(t()) :: String.t() | nil
  def compute_bundle_hash(%__MODULE__{} = entry) do
    case LemonSkills.Bundle.compute_hash(entry.path) do
      {:ok, hash} -> hash
      _ -> nil
    end
  end

  @doc """
  Return a map of provenance fields suitable for lockfile serialisation.
  """
  @spec to_lockfile_record(t()) :: map()
  def to_lockfile_record(%__MODULE__{} = entry) do
    %{
      "key" => entry.key,
      "source_kind" => to_string_or_nil(entry.source_kind),
      "source_id" => entry.source_id,
      "trust_level" => to_string_or_nil(entry.trust_level),
      "content_hash" => entry.content_hash,
      "bundle_hash" => entry.bundle_hash,
      "upstream_hash" => entry.upstream_hash,
      "installed_at" => datetime_to_iso(entry.installed_at),
      "updated_at" => datetime_to_iso(entry.updated_at),
      "audit_status" => to_string_or_nil(entry.audit_status),
      "audit_findings" => entry.audit_findings
    }
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @valid_atoms ~w(
    builtin local git registry well_known
    official trusted community
    pending pass warn block
    ready missing_deps missing_config disabled error
    global project
  )a

  defp parse_atom(nil), do: nil

  defp parse_atom(s) when is_binary(s) do
    Enum.find(@valid_atoms, fn a -> Atom.to_string(a) == s end)
  end

  defp parse_atom(a) when is_atom(a), do: a

  defp parse_datetime(nil), do: nil

  defp parse_datetime(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp datetime_to_iso(nil), do: nil
  defp datetime_to_iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(a) when is_atom(a), do: Atom.to_string(a)
  defp to_string_or_nil(s) when is_binary(s), do: s
end
