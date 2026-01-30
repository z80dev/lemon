defmodule CodingAgent.Skills do
  @moduledoc """
  Skill definitions and loading.

  Skills are reusable knowledge modules that get injected into context when relevant.
  They are markdown files with YAML frontmatter stored in:

  - Project: .lemon/skill/*/SKILL.md
  - Global: ~/.lemon/agent/skill/*/SKILL.md

  ## Skill File Format

  Each skill should have a SKILL.md file with frontmatter:

      ---
      name: bun-file-io
      description: Use this when working on file operations like reading, writing, or scanning files.
      ---

      ## When to use

      - Editing file I/O code
      - Handling directory operations

      ## Patterns

      - Use `Bun.file(path)` for file access
      - Check `exists()` before reading

  The `description` field is used to determine relevance to the current context.
  """

  alias CodingAgent.Config

  @type skill :: %{
          name: String.t(),
          description: String.t(),
          content: String.t(),
          path: String.t()
        }

  @doc """
  List all available skills for a working directory.

  Returns a list of skill maps with name, description, content, and path.

  ## Parameters

    * `cwd` - The current working directory

  ## Returns

  A list of skill maps.

  ## Examples

      skills = CodingAgent.Skills.list("/path/to/project")
      # => [%{name: "bun-file-io", description: "...", content: "...", path: "..."}]
  """
  @spec list(String.t()) :: [skill()]
  def list(cwd) do
    global_skills = load_skills_from_dir(global_skills_dir())
    project_skills = load_skills_from_dir(project_skills_dir(cwd))

    # Project skills override global ones by name
    global_skills
    |> merge_by_name(project_skills)
  end

  @doc """
  Get a skill by name.

  ## Parameters

    * `cwd` - The current working directory
    * `name` - The skill name to look up

  ## Returns

  The skill map or nil if not found.
  """
  @spec get(String.t(), String.t()) :: skill() | nil
  def get(cwd, name) when is_binary(name) do
    list(cwd)
    |> Enum.find(fn skill -> skill.name == name end)
  end

  @doc """
  Find skills relevant to a given context/query.

  Uses simple keyword matching on the description field.
  Returns skills that might be relevant to the given text.

  ## Parameters

    * `cwd` - The current working directory
    * `context` - Text to match against skill descriptions
    * `max_results` - Maximum number of skills to return (default: 3)

  ## Returns

  A list of relevant skill maps, sorted by relevance score.
  """
  @spec find_relevant(String.t(), String.t(), pos_integer()) :: [skill()]
  def find_relevant(cwd, context, max_results \\ 3) do
    context_lower = String.downcase(context)
    context_words = extract_words(context_lower)

    list(cwd)
    |> Enum.map(fn skill ->
      score = calculate_relevance(skill, context_lower, context_words)
      {skill, score}
    end)
    |> Enum.filter(fn {_skill, score} -> score > 0 end)
    |> Enum.sort_by(fn {_skill, score} -> score end, :desc)
    |> Enum.take(max_results)
    |> Enum.map(fn {skill, _score} -> skill end)
  end

  @doc """
  Format skills for injection into system prompt.

  ## Parameters

    * `skills` - List of skill maps

  ## Returns

  Formatted string with skill contents.
  """
  @spec format_for_prompt([skill()]) :: String.t()
  def format_for_prompt([]), do: ""

  def format_for_prompt(skills) do
    skills
    |> Enum.map(fn skill ->
      """
      <skill name="#{skill.name}">
      #{skill.content}
      </skill>
      """
    end)
    |> Enum.join("\n")
  end

  @doc """
  Format skill list for display/description.

  ## Parameters

    * `cwd` - The current working directory

  ## Returns

  Formatted string listing available skills.
  """
  @spec format_for_description(String.t()) :: String.t()
  def format_for_description(cwd) do
    skills = list(cwd)

    if skills == [] do
      ""
    else
      skills
      |> Enum.map(fn skill ->
        "- #{skill.name}: #{skill.description}"
      end)
      |> Enum.join("\n")
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp load_skills_from_dir(nil), do: []

  defp load_skills_from_dir(dir) do
    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(fn name ->
        path = Path.join(dir, name)
        File.dir?(path)
      end)
      |> Enum.map(fn skill_dir ->
        load_skill(Path.join(dir, skill_dir))
      end)
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  rescue
    _ -> []
  end

  defp load_skill(skill_dir) do
    skill_file = Path.join(skill_dir, "SKILL.md")

    case File.read(skill_file) do
      {:ok, content} ->
        parse_skill(content, skill_file)

      {:error, _} ->
        nil
    end
  end

  defp parse_skill(content, path) do
    case parse_frontmatter(content) do
      {:ok, frontmatter, body} ->
        name = frontmatter["name"] || Path.basename(Path.dirname(path))
        description = frontmatter["description"] || ""

        %{
          name: name,
          description: description,
          content: String.trim(body),
          path: path
        }

      :error ->
        nil
    end
  end

  defp parse_frontmatter(content) do
    # Check if content starts with YAML frontmatter
    if String.starts_with?(content, "---\n") do
      case String.split(content, ~r/\n---\n/, parts: 2) do
        [frontmatter_raw, body] ->
          frontmatter_clean = String.trim_leading(frontmatter_raw, "---\n")
          frontmatter = parse_yaml_simple(frontmatter_clean)
          {:ok, frontmatter, body}

        _ ->
          :error
      end
    else
      :error
    end
  end

  # Simple YAML-like parser for frontmatter
  # Handles basic key: value pairs
  defp parse_yaml_simple(yaml_text) do
    yaml_text
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [key, value] ->
          key = String.trim(key)
          value = String.trim(value)
          Map.put(acc, key, value)

        _ ->
          acc
      end
    end)
  end

  defp merge_by_name(base, overrides) do
    base_map = Map.new(base, fn skill -> {skill.name, skill} end)
    overrides_map = Map.new(overrides, fn skill -> {skill.name, skill} end)

    merged = Map.merge(base_map, overrides_map)
    merged |> Map.values() |> Enum.sort_by(& &1.name)
  end

  defp calculate_relevance(skill, context_lower, context_words) do
    desc_lower = String.downcase(skill.description)
    name_lower = String.downcase(skill.name)
    content_lower = String.downcase(skill.content)

    # Score based on matches
    name_score = if String.contains?(context_lower, name_lower), do: 10, else: 0

    desc_word_matches =
      context_words
      |> Enum.count(fn word -> String.contains?(desc_lower, word) end)

    content_word_matches =
      context_words
      |> Enum.count(fn word -> String.contains?(content_lower, word) end)

    name_score + desc_word_matches * 3 + content_word_matches
  end

  defp extract_words(text) do
    text
    |> String.split(~r/[^\w]+/)
    |> Enum.filter(fn word -> String.length(word) > 2 end)
    |> Enum.uniq()
  end

  defp global_skills_dir do
    Path.join(Config.agent_dir(), "skill")
  end

  defp project_skills_dir(cwd) do
    Path.join(Config.project_config_dir(cwd), "skill")
  end
end
