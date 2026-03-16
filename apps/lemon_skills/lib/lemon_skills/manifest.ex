defmodule LemonSkills.Manifest do
  @moduledoc """
  Manifest parsing and validation for skill files.

  Handles parsing of `SKILL.md` files with YAML (`---`) or TOML (`+++`)
  frontmatter, plus validation against the manifest v2 schema.

  ## Manifest v2

  Manifest v2 extends the legacy schema with additional fields used by the
  skills platform for progressive loading, platform gating, and the audit
  pipeline. See `docs/reference/skill-manifest-v2.md` for the full schema.

  New v2 fields (all optional; defaults are applied automatically):

  - `platforms` — list of `"linux"`, `"darwin"`, `"win32"`, or `"any"`
  - `metadata.lemon.category` — categorisation string for registry browsing
  - `requires_tools` — tools required by this skill (semantic, not just bins)
  - `fallback_for_tools` — tools this skill provides fallback guidance for
  - `required_environment_variables` — replaces `requires.config` (both are
    accepted; legacy value is promoted automatically)
  - `verification` — a map describing how to check the skill works
  - `references` — list of paths or URLs to supplementary files

  ## Legacy skills

  Skills with only v1 fields continue to parse and validate without changes.
  Defaults for v2 fields are applied so all callers can rely on them being
  present in normalised manifests (see `validate/1`).

  ## Examples

  Parse a skill file:

      {:ok, manifest, body} = LemonSkills.Manifest.parse(content)
      manifest["name"]   # => "k8s-rollout"
      manifest["platforms"]  # => ["linux", "darwin"]  (v2)

  Validate and normalise:

      {:ok, normalised} = LemonSkills.Manifest.validate(manifest)
      normalised["required_environment_variables"]  # always a list

  """

  alias LemonSkills.Manifest.{Parser, Validator}

  @type manifest :: %{String.t() => any()}

  # ---------------------------------------------------------------------------
  # Parsing
  # ---------------------------------------------------------------------------

  @doc """
  Parse skill file content, extracting frontmatter and body.

  Returns `{:ok, manifest_map, body}` where `manifest_map` contains raw
  (non-validated) frontmatter fields and `body` is the remaining markdown.

  Returns `:error` for malformed frontmatter (open delimiter, no close).
  Returns `{:ok, %{}, content}` when no frontmatter is present.
  """
  @spec parse(String.t()) :: {:ok, manifest(), String.t()} | :error
  def parse(content) when is_binary(content) do
    Parser.parse(content)
  end

  @doc """
  Parse only the frontmatter, ignoring the body.
  """
  @spec parse_frontmatter(String.t()) :: {:ok, manifest()} | :error
  def parse_frontmatter(content) do
    case parse(content) do
      {:ok, manifest, _body} -> {:ok, manifest}
      :error -> :error
    end
  end

  @doc """
  Strip frontmatter and return only the body content.
  """
  @spec parse_body(String.t()) :: String.t()
  def parse_body(content) do
    case parse(content) do
      {:ok, _manifest, body} -> body
      :error -> content
    end
  end

  @doc """
  Parse, validate, and normalize a skill manifest in one step.

  Returns `{:ok, normalised_manifest, body}` on success or `{:error, reason}`
  when frontmatter is malformed or validation fails.
  """
  @spec parse_and_validate(String.t()) :: {:ok, manifest(), String.t()} | {:error, String.t()}
  def parse_and_validate(content) when is_binary(content) do
    with {:ok, manifest, body} <- parse_with_reason(content),
         {:ok, normalised} <- validate(manifest) do
      {:ok, normalised, body}
    end
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  @doc """
  Validate a parsed manifest and return a normalised copy with v2 defaults.

  Accepts both v1 and v2 manifests. Returns `{:ok, normalised}` on success
  or `{:error, reason}` when a field fails schema validation.

  **Important:** always use the normalised manifest returned here; do not call
  `parse/1` and skip validation when you need reliable field access.
  """
  @spec validate(manifest()) :: {:ok, manifest()} | {:error, String.t()}
  def validate(manifest) when is_map(manifest) do
    Validator.validate(manifest)
  end

  @doc """
  Return `:v1` or `:v2` depending on which fields are present.
  """
  @spec version(manifest()) :: :v1 | :v2
  def version(manifest), do: Validator.version(manifest)

  # ---------------------------------------------------------------------------
  # Field accessors
  #
  # These work on both raw and normalised manifests.  For the v2 list fields
  # (`requires_tools`, `fallback_for_tools`, `required_environment_variables`)
  # the accessors always return a list even when the field is absent.
  # ---------------------------------------------------------------------------

  @doc "Get required binaries (legacy `requires.bins` field)."
  @spec required_bins(manifest()) :: [String.t()]
  def required_bins(manifest) do
    manifest |> Map.get("requires", %{}) |> Map.get("bins", []) |> ensure_list()
  end

  @doc "Get required config/env vars from legacy `requires.config`."
  @spec required_config(manifest()) :: [String.t()]
  def required_config(manifest) do
    manifest |> Map.get("requires", %{}) |> Map.get("config", []) |> ensure_list()
  end

  @doc "Get v2 `required_environment_variables` (falls back to `requires.config`)."
  @spec required_environment_variables(manifest()) :: [String.t()]
  def required_environment_variables(manifest) do
    case Map.get(manifest, "required_environment_variables") do
      nil -> required_config(manifest)
      vars -> ensure_list(vars)
    end
  end

  @doc "Get v2 `requires_tools` list."
  @spec requires_tools(manifest()) :: [String.t()]
  def requires_tools(manifest) do
    manifest |> Map.get("requires_tools", []) |> ensure_list()
  end

  @doc "Get v2 `fallback_for_tools` list."
  @spec fallback_for_tools(manifest()) :: [String.t()]
  def fallback_for_tools(manifest) do
    manifest |> Map.get("fallback_for_tools", []) |> ensure_list()
  end

  @doc "Get v2 `platforms` list (defaults to `[\"any\"]` when absent)."
  @spec platforms(manifest()) :: [String.t()]
  def platforms(manifest) do
    manifest |> Map.get("platforms", ["any"]) |> ensure_list()
  end

  @doc "Get v2 `references` list."
  @spec references(manifest()) :: [map() | String.t()]
  def references(manifest) do
    manifest |> Map.get("references", []) |> ensure_list()
  end

  @doc """
  Get `metadata.lemon.category` if present.

  Returns `nil` when the field is absent.
  """
  @spec lemon_category(manifest()) :: String.t() | nil
  def lemon_category(manifest) do
    get_in(manifest, ["metadata", "lemon", "category"])
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp parse_with_reason(content) do
    case parse(content) do
      {:ok, manifest, body} -> {:ok, manifest, body}
      :error -> {:error, "invalid frontmatter"}
    end
  end

  defp ensure_list(v) when is_list(v), do: v
  defp ensure_list(_), do: []
end
