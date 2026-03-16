#!/usr/bin/env elixir
# One-time migration script: copy Hermes skills into Lemon's skill directory.
#
# Usage:
#   elixir scripts/migrate_hermes_skills.exs [--dry-run]
#
# Reads SKILL.md files from ~/dev/hermes-agent/skills/ and optional-skills/,
# converts frontmatter to Lemon's format, and writes to ~/.lemon/agent/skill/.

defmodule HermesSkillMigrator do
  @hermes_dirs [
    Path.expand("~/dev/hermes-agent/skills"),
    Path.expand("~/dev/hermes-agent/optional-skills")
  ]

  @lemon_skill_dir Path.expand("~/.lemon/agent/skill")

  def run(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false)

    skills = discover_hermes_skills()
    existing = existing_lemon_skills()

    IO.puts("Found #{length(skills)} Hermes skills")
    IO.puts("Found #{MapSet.size(existing)} existing Lemon skills")
    IO.puts(if dry_run?, do: "DRY RUN — no files will be written\n", else: "")

    {migrated, skipped, errors} =
      Enum.reduce(skills, {0, 0, []}, fn skill, {m, s, errs} ->
        if MapSet.member?(existing, skill.key) do
          IO.puts("  SKIP  #{skill.key} (already exists)")
          {m, s + 1, errs}
        else
          case migrate_skill(skill, dry_run?) do
            :ok ->
              IO.puts("  OK    #{skill.key} [#{skill.category}]")
              {m + 1, s, errs}

            {:error, reason} ->
              IO.puts("  ERR   #{skill.key}: #{inspect(reason)}")
              {m, s, [{skill.key, reason} | errs]}
          end
        end
      end)

    IO.puts("\nDone: #{migrated} migrated, #{skipped} skipped, #{length(errors)} errors")
  end

  # ---------------------------------------------------------------------------
  # Discovery
  # ---------------------------------------------------------------------------

  defp discover_hermes_skills do
    @hermes_dirs
    |> Enum.flat_map(fn base_dir ->
      if File.dir?(base_dir) do
        base_dir
        |> find_skill_files()
        |> Enum.map(fn path -> parse_skill_path(path, base_dir) end)
      else
        []
      end
    end)
    |> Enum.sort_by(& &1.key)
  end

  defp find_skill_files(dir) do
    Path.wildcard(Path.join(dir, "**/SKILL.md"))
  end

  defp parse_skill_path(path, base_dir) do
    # Path relative to base: e.g. "mlops/training/axolotl/SKILL.md"
    rel = Path.relative_to(path, base_dir)
    parts = Path.split(rel) |> Enum.drop(-1)  # drop "SKILL.md"

    key = List.last(parts)
    category = parts |> Enum.drop(-1) |> Enum.join("/")
    category = if category == "", do: "general", else: category

    %{path: path, key: key, category: category}
  end

  defp existing_lemon_skills do
    if File.dir?(@lemon_skill_dir) do
      @lemon_skill_dir
      |> File.ls!()
      |> MapSet.new()
    else
      MapSet.new()
    end
  end

  # ---------------------------------------------------------------------------
  # Migration
  # ---------------------------------------------------------------------------

  defp migrate_skill(skill, dry_run?) do
    case File.read(skill.path) do
      {:ok, content} ->
        new_content = convert_content(content, skill.category)
        dest_dir = Path.join(@lemon_skill_dir, skill.key)
        dest_file = Path.join(dest_dir, "SKILL.md")

        if dry_run? do
          :ok
        else
          File.mkdir_p!(dest_dir)
          File.write!(dest_file, new_content)
          :ok
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp convert_content(content, category) do
    case split_frontmatter(content) do
      {:ok, raw_yaml, body} ->
        fields = parse_yaml_simple(raw_yaml)
        new_yaml = build_lemon_frontmatter(fields, category)
        "---\n#{new_yaml}---\n#{body}"

      :no_frontmatter ->
        # No frontmatter — wrap the whole thing with minimal metadata
        "---\nname: unknown\ndescription: \"\"\nmetadata:\n  lemon:\n    category: #{category}\n---\n#{content}"
    end
  end

  defp split_frontmatter(content) do
    case String.split(content, ~r/^---\s*$/m, parts: 3) do
      [before, yaml, rest] when before == "" ->
        {:ok, yaml, rest}

      [before, yaml, rest] ->
        if String.trim(before) == "" do
          {:ok, yaml, rest}
        else
          :no_frontmatter
        end

      _ ->
        :no_frontmatter
    end
  end

  defp parse_yaml_simple(yaml) do
    # Simple top-level YAML field extraction. We don't need deep parsing —
    # just enough to pull out name, description, version, author, license,
    # tags, and detect metadata.hermes.tags.
    lines = String.split(yaml, "\n")

    %{
      name: extract_field(lines, "name"),
      description: extract_field(lines, "description"),
      version: extract_field(lines, "version"),
      author: extract_field(lines, "author"),
      license: extract_field(lines, "license"),
      tags: extract_tags(yaml),
      keywords: extract_array_field(lines, "tags"),
      dependencies: extract_array_field(lines, "dependencies"),
      prereq_commands: extract_prereq_commands(yaml),
      env_vars: extract_env_vars(yaml)
    }
  end

  defp extract_field(lines, field) do
    Enum.find_value(lines, fn line ->
      case Regex.run(~r/^#{field}:\s*(.+)$/i, String.trim(line)) do
        [_, value] -> String.trim(value) |> unquote_yaml()
        nil -> nil
      end
    end)
  end

  defp extract_array_field(lines, field) do
    Enum.find_value(lines, fn line ->
      case Regex.run(~r/^#{field}:\s*\[(.+)\]$/i, String.trim(line)) do
        [_, values] ->
          values
          |> String.split(",")
          |> Enum.map(&(String.trim(&1) |> unquote_yaml()))

        nil ->
          nil
      end
    end) || []
  end

  defp extract_tags(yaml) do
    # Try metadata.hermes.tags first (inline array format)
    case Regex.run(~r/tags:\s*\[([^\]]+)\]/m, yaml) do
      [_, values] ->
        values
        |> String.split(",")
        |> Enum.map(&(String.trim(&1) |> unquote_yaml()))

      nil ->
        []
    end
  end

  defp extract_prereq_commands(yaml) do
    case Regex.run(~r/commands:\s*\[([^\]]+)\]/m, yaml) do
      [_, values] ->
        values
        |> String.split(",")
        |> Enum.map(&(String.trim(&1) |> unquote_yaml()))

      nil ->
        []
    end
  end

  defp extract_env_vars(yaml) do
    Regex.scan(~r/env_var:\s*(\S+)/m, yaml)
    |> Enum.map(fn [_, var] -> unquote_yaml(var) end)
  end

  defp unquote_yaml(s) do
    s
    |> String.trim()
    |> String.trim("\"")
    |> String.trim("'")
  end

  defp build_lemon_frontmatter(fields, category) do
    lines =
      [
        "name: #{fields.name || "unknown"}",
        "description: #{yaml_quote(fields.description || "")}"
      ]

    lines = if fields.version, do: lines ++ ["version: #{fields.version}"], else: lines
    lines = if fields.author, do: lines ++ ["author: #{fields.author}"], else: lines
    lines = if fields.license, do: lines ++ ["license: #{fields.license}"], else: lines

    # Merge tags from top-level tags field and metadata.hermes.tags
    all_keywords =
      (fields.keywords ++ fields.tags)
      |> Enum.uniq_by(&String.downcase/1)

    lines =
      if all_keywords != [] do
        kw_str = Enum.map(all_keywords, &yaml_quote/1) |> Enum.join(", ")
        lines ++ ["keywords: [#{kw_str}]"]
      else
        lines
      end

    lines =
      if fields.prereq_commands != [] do
        bins_str = Enum.map(fields.prereq_commands, &yaml_quote/1) |> Enum.join(", ")
        lines ++ ["requires:", "  bins: [#{bins_str}]"]
      else
        lines
      end

    lines =
      if fields.env_vars != [] do
        vars_str = Enum.map(fields.env_vars, &yaml_quote/1) |> Enum.join(", ")
        lines ++ ["required_environment_variables: [#{vars_str}]"]
      else
        lines
      end

    # Category
    lines = lines ++ ["metadata:", "  lemon:", "    category: #{category}"]

    Enum.join(lines, "\n") <> "\n"
  end

  defp yaml_quote(s) do
    if String.contains?(s, [":", "#", "'", "\"", "[", "]", "{", "}", ",", "\n", "&", "*", "!", "|", ">", "%", "@"]) do
      "\"#{String.replace(s, "\"", "\\\"")}\""
    else
      s
    end
  end
end

# Parse CLI args
dry_run? = "--dry-run" in System.argv()
HermesSkillMigrator.run(dry_run: dry_run?)
