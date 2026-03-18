defmodule LemonSkills.Audit.SkillLint do
  @moduledoc """
  Validates skill bundle integrity and manifest compliance.

  ## Contributor contract for official skills

  Skills submitted to the `official/` registry namespace must pass all lint
  checks with no errors before merge.  The checks are:

  1. **SKILL.md present** — every skill directory must contain `SKILL.md`.
  2. **Frontmatter parses** — the YAML/TOML frontmatter must be well-formed.
  3. **`name` required** — must be a non-empty string.
  4. **`description` required** — must be a non-empty string.
  5. **Reference paths exist** — every `references[].path` entry must resolve
     to a real file inside the skill directory.
  6. **Body non-empty** — the markdown body (after frontmatter) must contain
     at least some non-whitespace content.
  7. **Audit clean** — the skill content must not trigger a `:block` verdict
     from the security audit engine.

  Checks 1–6 report severity `:error` (fail the build).
  Check 7 reports severity `:warn` for `:warn` audit results and `:error`
  for `:block` audit results.

  ## Usage

      # Lint a single skill directory
      result = LemonSkills.Audit.SkillLint.lint_skill("/path/to/skill-dir")
      result.valid?    # => true | false
      result.issues    # => [%{code: :missing_description, ...}]

      # Lint all skills under a parent directory
      results = LemonSkills.Audit.SkillLint.lint_dir("/path/to/skills")
      Enum.filter(results, &(!&1.valid?))  # failures only
  """

  alias LemonSkills.{Manifest, PathBoundary}
  alias LemonSkills.Audit.Engine, as: AuditEngine

  @type severity :: :error | :warn
  @type issue :: %{code: atom(), message: String.t(), severity: severity()}
  @type lint_result :: %{
          key: String.t(),
          path: String.t(),
          issues: [issue()],
          valid?: boolean()
        }
  @version 2

  @doc "Version tag for cache invalidation when lint rules change."
  @spec version() :: pos_integer()
  def version, do: @version

  # ──────────────────────────────────────────────────────────────────────────
  # Public API
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Lint all skill directories directly under `parent_dir`.

  A skill directory is any direct subdirectory of `parent_dir` that either:
  - contains a `SKILL.md` file, or
  - is a non-hidden directory (missing `SKILL.md` is reported as an error)

  Returns a list of `lint_result` maps, one per skill found.
  """
  @spec lint_dir(String.t()) :: [lint_result()]
  def lint_dir(parent_dir) when is_binary(parent_dir) do
    case File.ls(parent_dir) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.map(&Path.join(parent_dir, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.map(&lint_skill/1)

      {:error, reason} ->
        [
          %{
            key: Path.basename(parent_dir),
            path: parent_dir,
            issues: [error(:directory_unreadable, "Cannot list directory: #{reason}")],
            valid?: false
          }
        ]
    end
  end

  @doc """
  Lint a single skill directory.

  Returns a `lint_result` map with:
  - `:key` — directory basename (the skill key)
  - `:path` — absolute path to the skill directory
  - `:issues` — list of `%{code, message, severity}` maps
  - `:valid?` — `true` when there are no `:error`-severity issues
  """
  @spec lint_skill(String.t()) :: lint_result()
  def lint_skill(skill_path) when is_binary(skill_path) do
    lint_skill(skill_path, [])
  end

  @spec lint_skill(String.t(), keyword()) :: lint_result()
  def lint_skill(skill_path, opts) when is_binary(skill_path) and is_list(opts) do
    key = Path.basename(skill_path)
    skill_file = Path.join(skill_path, "SKILL.md")
    include_audit = Keyword.get(opts, :include_audit, true)

    issues =
      if File.exists?(skill_file) do
        lint_skill_file(skill_path, skill_file, include_audit)
      else
        [error(:missing_skill_file, "SKILL.md not found in skill directory")]
      end

    %{
      key: key,
      path: skill_path,
      issues: issues,
      valid?: not Enum.any?(issues, &(&1.severity == :error))
    }
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Internal lint steps
  # ──────────────────────────────────────────────────────────────────────────

  defp lint_skill_file(skill_path, skill_file, include_audit) do
    case File.read(skill_file) do
      {:error, reason} ->
        [error(:skill_file_unreadable, "Could not read SKILL.md: #{reason}")]

      {:ok, content} ->
        case Manifest.parse(content) do
          :error ->
            [error(:parse_error, "SKILL.md frontmatter is not valid YAML/TOML")]

          {:ok, manifest, body} ->
            []
            |> check_required_field(manifest, "name", :missing_name)
            |> check_required_field(manifest, "description", :missing_description)
            |> check_references(skill_path, manifest)
            |> check_body(body)
            |> maybe_check_audit(skill_path, content, include_audit)
        end
    end
  end

  defp check_required_field(issues, manifest, field, code) do
    value = Map.get(manifest, field)

    if is_binary(value) and String.trim(value) != "" do
      issues
    else
      issues ++ [error(code, "Required field '#{field}' is missing or empty")]
    end
  end

  defp check_references(issues, skill_path, manifest) do
    refs = Manifest.references(manifest)

    ref_issues =
      refs
      |> Enum.flat_map(fn ref ->
        case extract_ref_path(ref) do
          nil ->
            []

          rel_path ->
            full_path = Path.join(skill_path, rel_path)
            expanded = Path.expand(full_path)
            expanded_skill = Path.expand(skill_path)

            cond do
              not PathBoundary.within?(expanded_skill, expanded) ->
                [
                  error(
                    :reference_path_traversal,
                    "Reference path escapes skill directory: #{rel_path}"
                  )
                ]

              not File.exists?(expanded) ->
                [error(:reference_missing, "Referenced file does not exist: #{rel_path}")]

              true ->
                []
            end
        end
      end)

    issues ++ ref_issues
  end

  # Extract the file path from a reference entry.
  #
  # The hand-rolled YAML parser returns list items like `- path: extra.md` as
  # plain strings `"path: extra.md"` rather than maps.  This function handles
  # all three forms:
  #   - Map:    %{"path" => "extra.md"}
  #   - String: "path: extra.md"  (parsed from `- path: val` list item)
  #   - String: "extra.md"        (bare path)
  defp extract_ref_path(%{"path" => path}) when is_binary(path), do: path
  defp extract_ref_path(%{path: path}) when is_binary(path), do: path

  defp extract_ref_path(str) when is_binary(str) do
    cond do
      # "path: extra.md" → "extra.md"
      String.match?(str, ~r/^path:\s*.+/) ->
        str |> String.split(":", parts: 2) |> List.last() |> String.trim()

      # Bare path: any non-empty string without spaces (treat as a filename)
      String.trim(str) != "" and not String.contains?(str, " ") ->
        String.trim(str)

      true ->
        nil
    end
  end

  defp extract_ref_path(_), do: nil

  defp check_body(issues, body) do
    if String.trim(body) == "" do
      issues ++
        [
          error(
            :empty_body,
            "SKILL.md body (after frontmatter) is empty — add usage instructions"
          )
        ]
    else
      issues
    end
  end

  defp maybe_check_audit(issues, _skill_path, _content, false), do: issues

  defp maybe_check_audit(issues, skill_path, _content, true) do
    case AuditEngine.audit_bundle(skill_path) do
      {:pass, _} ->
        issues

      {:warn, findings} ->
        summary = findings |> Enum.map(& &1.message) |> Enum.join("; ")
        issues ++ [warn(:audit_warn, "Audit warnings: #{summary}")]

      {:block, findings} ->
        summary = findings |> Enum.map(& &1.message) |> Enum.join("; ")
        issues ++ [error(:audit_block, "Audit block — skill contains unsafe content: #{summary}")]
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Issue constructors
  # ──────────────────────────────────────────────────────────────────────────

  defp error(code, message), do: %{code: code, message: message, severity: :error}
  defp warn(code, message), do: %{code: code, message: message, severity: :warn}
end
