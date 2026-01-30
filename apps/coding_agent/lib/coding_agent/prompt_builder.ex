defmodule CodingAgent.PromptBuilder do
  @moduledoc """
  Builds system prompts with dynamic context injection.

  This module constructs system prompts by combining:
  - Base system prompt
  - Relevant skills (based on context)
  - Available commands
  - Available subagents (@mentions)
  - Project-specific instructions (CLAUDE.md, AGENTS.md)

  ## Usage

      prompt = PromptBuilder.build(cwd, %{
        base_prompt: "You are a helpful coding assistant.",
        context: "working on file I/O",
        include_skills: true,
        include_commands: true,
        include_mentions: true
      })
  """

  alias CodingAgent.{Skills, Commands, Subagents}

  @type build_opts :: %{
          optional(:base_prompt) => String.t(),
          optional(:context) => String.t(),
          optional(:include_skills) => boolean(),
          optional(:include_commands) => boolean(),
          optional(:include_mentions) => boolean(),
          optional(:max_skills) => pos_integer(),
          optional(:custom_sections) => [{String.t(), String.t()}]
        }

  @default_opts %{
    base_prompt: "",
    context: "",
    include_skills: true,
    include_commands: true,
    include_mentions: true,
    max_skills: 3,
    custom_sections: []
  }

  @doc """
  Build a complete system prompt with all dynamic sections.

  ## Parameters

    * `cwd` - Current working directory
    * `opts` - Build options (see module docs)

  ## Returns

  A complete system prompt string.
  """
  @spec build(String.t(), build_opts()) :: String.t()
  def build(cwd, opts \\ %{}) do
    opts = Map.merge(@default_opts, opts)

    sections = [
      {:base, opts.base_prompt},
      {:skills, maybe_build_skills_section(cwd, opts)},
      {:commands, maybe_build_commands_section(cwd, opts)},
      {:mentions, maybe_build_mentions_section(cwd, opts)},
      {:custom, build_custom_sections(opts)}
    ]

    sections
    |> Enum.map(fn {_name, content} -> content end)
    |> Enum.reject(&empty?/1)
    |> Enum.join("\n\n")
  end

  @doc """
  Build only the skills section of a prompt.

  ## Parameters

    * `cwd` - Current working directory
    * `context` - Context string for relevance matching
    * `max_skills` - Maximum number of skills to include

  ## Returns

  Formatted skills section or empty string.
  """
  @spec build_skills_section(String.t(), String.t(), pos_integer()) :: String.t()
  def build_skills_section(cwd, context, max_skills \\ 3) do
    if context != "" do
      skills = Skills.find_relevant(cwd, context, max_skills)

      if skills != [] do
        content = Skills.format_for_prompt(skills)

        """
        <relevant-skills>
        #{content}
        </relevant-skills>
        """
      else
        ""
      end
    else
      ""
    end
  end

  @doc """
  Build only the commands section of a prompt.

  ## Parameters

    * `cwd` - Current working directory

  ## Returns

  Formatted commands section or empty string.
  """
  @spec build_commands_section(String.t()) :: String.t()
  def build_commands_section(cwd) do
    commands = Commands.list(cwd)

    if commands != [] do
      list = Commands.format_for_description(cwd)

      """
      <available-commands>
      The following slash commands are available:

      #{list}

      To use a command, the user will type `/command_name arguments`.
      </available-commands>
      """
    else
      ""
    end
  end

  @doc """
  Build only the mentions section of a prompt.

  ## Parameters

    * `cwd` - Current working directory

  ## Returns

  Formatted mentions section or empty string.
  """
  @spec build_mentions_section(String.t()) :: String.t()
  def build_mentions_section(cwd) do
    agents = Subagents.list(cwd)

    if agents != [] do
      list = Subagents.format_for_description(cwd)

      """
      <available-agents>
      The following agents can be invoked with @mention syntax:

      #{list}

      Users can invoke agents by typing `@agent_name prompt`.
      </available-agents>
      """
    else
      ""
    end
  end

  @doc """
  Load project instructions from CLAUDE.md or AGENTS.md.

  ## Parameters

    * `cwd` - Current working directory

  ## Returns

  Project instructions content or empty string.
  """
  @spec load_project_instructions(String.t()) :: String.t()
  def load_project_instructions(cwd) do
    files = [
      Path.join(cwd, "CLAUDE.md"),
      Path.join(cwd, "AGENTS.md"),
      Path.join([cwd, ".lemon", "AGENTS.md"]),
      Path.join([cwd, ".lemon", "instructions.md"])
    ]

    files
    |> Enum.find_value("", fn path ->
      case File.read(path) do
        {:ok, content} -> String.trim(content)
        _ -> nil
      end
    end)
  end

  @doc """
  Build a prompt section from project instructions.

  ## Parameters

    * `cwd` - Current working directory

  ## Returns

  Formatted project instructions section or empty string.
  """
  @spec build_project_instructions_section(String.t()) :: String.t()
  def build_project_instructions_section(cwd) do
    content = load_project_instructions(cwd)

    if content != "" do
      """
      <project-instructions>
      #{content}
      </project-instructions>
      """
    else
      ""
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp maybe_build_skills_section(cwd, opts) do
    if opts.include_skills do
      build_skills_section(cwd, opts.context, opts.max_skills)
    else
      ""
    end
  end

  defp maybe_build_commands_section(cwd, opts) do
    if opts.include_commands do
      build_commands_section(cwd)
    else
      ""
    end
  end

  defp maybe_build_mentions_section(cwd, opts) do
    if opts.include_mentions do
      build_mentions_section(cwd)
    else
      ""
    end
  end

  defp build_custom_sections(opts) do
    opts.custom_sections
    |> Enum.map(fn {title, content} ->
      """
      <#{title}>
      #{content}
      </#{title}>
      """
    end)
    |> Enum.join("\n")
  end

  defp empty?(nil), do: true
  defp empty?(""), do: true
  defp empty?(s) when is_binary(s), do: String.trim(s) == ""
  defp empty?(_), do: false
end
