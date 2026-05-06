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

  alias CodingAgent.{Commands, Subagents}

  @type build_opts :: %{
          optional(:base_prompt) => String.t(),
          optional(:context) => String.t(),
          optional(:include_skills) => boolean(),
          optional(:include_commands) => boolean(),
          optional(:include_mentions) => boolean(),
          optional(:max_skills) => pos_integer(),
          optional(:run_id) => String.t(),
          optional(:session_key) => String.t(),
          optional(:session_id) => String.t(),
          optional(:agent_id) => String.t(),
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
    skills_section = maybe_build_skills_section(cwd, opts)

    sections = [
      {:base, opts.base_prompt},
      {:skills, skills_section},
      {:learning, maybe_build_learning_section(skills_section, opts)},
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
  @spec build_skills_section(String.t(), String.t(), pos_integer(), map()) :: String.t()
  def build_skills_section(cwd, context, max_skills \\ 3, opts \\ %{}) do
    if context != "" do
      views =
        LemonSkills.find_relevant(context, cwd: cwd, max_results: max_skills, refresh: true)
        |> Enum.map(&LemonSkills.SkillView.from_entry(&1, cwd: cwd))
        |> Enum.filter(&LemonSkills.SkillView.displayable?/1)

      LemonSkills.PromptView.render_relevant_skills(views, skill_trace_opts(opts, cwd))
    else
      ""
    end
  end

  @doc """
  Build procedural learning guidance for prompts that expose skill and memory tools.
  """
  @spec build_learning_section() :: String.t()
  def build_learning_section do
    """
    <learning-workflow>
    Choose the right persistence surface:
    - Use `read_skill` before following a relevant installed skill; skill hints are summaries, not the full procedure.
    - Use `search_memory` before answering prompts that mention prior work, previous decisions, remembered context, or "last time"; this recalls completed run history.
    - Use `memory_topic` for durable facts, preferences, decisions, people, dates, or project context that should be recalled later but is not a reusable procedure.
    - Use `skill_manage` when you discover a reusable workflow, recurring command sequence, API integration, debugging playbook, project convention, or verification checklist that will likely help future runs.
    - Use `todo` for the active run's task list and progress tracking; do not use todos as long-term memory.
    - At the end of substantial work, before the final answer, decide whether the run produced durable context or a reusable workflow; write the memory topic or skill before finalizing when the lesson is clear.
    </learning-workflow>
    """
    |> String.trim()
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
      build_skills_section(cwd, opts.context, opts.max_skills, opts)
    else
      ""
    end
  end

  defp maybe_build_learning_section("", _opts), do: ""
  defp maybe_build_learning_section(_skills_section, %{include_skills: false}), do: ""

  defp maybe_build_learning_section(_skills_section, %{context: context})
       when is_binary(context) do
    if String.trim(context) == "" do
      ""
    else
      build_learning_section()
    end
  end

  defp maybe_build_learning_section(_skills_section, _opts), do: ""

  defp skill_trace_opts(opts, cwd) do
    opts
    |> Map.take([:run_id, :session_key, :session_id, :agent_id])
    |> Map.put(:cwd, cwd)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
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
