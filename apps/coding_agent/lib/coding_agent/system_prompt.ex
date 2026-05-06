defmodule CodingAgent.SystemPrompt do
  @moduledoc """
  Builds Lemon system prompts with workspace context + skills.

  This is a Lemon-specific adaptation of OpenClaw's prompt structure:
  - No tool list section (Lemon surfaces tools elsewhere)
  - No gateway restart/self-update section
  - Keeps skills + workspace file context
  """

  alias CodingAgent.Workspace
  alias LemonSkills.PromptView

  @type opts :: %{
          optional(:workspace_dir) => String.t(),
          optional(:bootstrap_max_chars) => pos_integer(),
          optional(:session_scope) => :main | :subagent | String.t(),
          optional(:skill_context) => String.t(),
          optional(:max_relevant_skills) => pos_integer(),
          optional(:run_id) => String.t(),
          optional(:session_key) => String.t(),
          optional(:session_id) => String.t(),
          optional(:agent_id) => String.t()
        }

  @doc """
  Build the system prompt for a Lemon coding agent session.

  Assembles workspace context files, skills, memory workflow guidance,
  and runtime metadata into a single prompt string.
  """
  @spec build(String.t(), opts()) :: String.t()
  def build(cwd, opts \\ %{}) do
    workspace_dir = Map.get(opts, :workspace_dir, Workspace.workspace_dir())
    max_chars = Map.get(opts, :bootstrap_max_chars, Workspace.default_max_chars())
    session_scope = normalize_session_scope(Map.get(opts, :session_scope, :main))
    skill_context = Map.get(opts, :skill_context, "")
    max_relevant_skills = Map.get(opts, :max_relevant_skills, 3)
    skill_trace_opts = skill_trace_opts(opts)

    bootstrap_files =
      Workspace.load_bootstrap_files(
        workspace_dir: workspace_dir,
        max_chars: max_chars,
        session_scope: session_scope
      )

    sections = [
      "You are a personal assistant running inside Lemon.",
      build_runtime_section(session_scope),
      build_relevant_skills_section(cwd, skill_context, max_relevant_skills, skill_trace_opts),
      build_skills_section(cwd, skill_trace_opts),
      build_memory_workflow_section(session_scope),
      build_learning_workflow_section(session_scope),
      build_workspace_section(cwd, workspace_dir),
      build_workspace_context_section(bootstrap_files)
    ]

    sections
    |> Enum.reject(&empty?/1)
    |> Enum.join("\n\n")
  end

  @doc """
  Extract tool names that the prompt explicitly instructs the agent to use.

  This is intentionally narrower than "all backticked lowercase words" so file
  names, XML tags, and parameter examples do not become false tool references.
  It powers prompt-contract tests that keep system-prompt tool guidance aligned
  with the default native Lemon tool set.
  """
  @spec referenced_tool_names(String.t()) :: [String.t()]
  def referenced_tool_names(prompt) when is_binary(prompt) do
    ~r/\b(?:Use|use|If)\s+`([a-z][a-z0-9_]*)`/
    |> Regex.scan(prompt, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  # ============================================================================
  # Sections
  # ============================================================================

  defp build_relevant_skills_section(_cwd, context, _max_skills, _trace_opts)
       when context in [nil, ""],
       do: ""

  defp build_relevant_skills_section(cwd, context, max_skills, trace_opts)
       when is_binary(context) do
    views =
      context
      |> LemonSkills.find_relevant(cwd: cwd, max_results: max_skills, refresh: false)
      |> Enum.map(&LemonSkills.SkillView.from_entry(&1, cwd: cwd))
      |> Enum.filter(&LemonSkills.SkillView.displayable?/1)

    PromptView.render_relevant_skills(views, Keyword.put(trace_opts, :cwd, cwd))
  end

  defp build_skills_section(cwd, trace_opts) do
    PromptView.render_for_prompt(cwd, trace_opts)
  end

  defp build_workspace_section(cwd, workspace_dir) do
    """
    ## Boundaries
    Assistant home: #{workspace_dir}
    Project root (cwd): #{cwd}
    Use the assistant home for persistent identity, memory, and operating notes.
    Use the project root for repo files, shell commands, and task execution.
    """
    |> String.trim()
  end

  defp build_runtime_section(session_scope) do
    """
    ## Runtime
    Session scope: #{session_scope}
    """
    |> String.trim()
  end

  defp build_memory_workflow_section(:subagent) do
    """
    ## Memory Workflow
    This is a subagent session. Do not read or modify MEMORY.md unless the parent task explicitly asks for it.
    """
    |> String.trim()
  end

  defp build_memory_workflow_section(:main) do
    """
    ## Memory Workflow
    Before answering about prior decisions, preferences, people, dates, or todos, inspect the right memory surface first.
    - Use `search_memory` to recall completed run history (past bug fixes, commands run, earlier answers, "last time" context).
      Prefer `scope: "current"` to search both the project root and assistant home.
      Use `scope: "project"` for repo-specific history, `scope: "home"` for assistant-home history, and `scope: "agent"` for longer-term patterns.
    - Use `read` to inspect user-editable workspace notes such as `MEMORY.md`, relevant `memory/topics/*.md` files, and recent `memory/YYYY-MM-DD.md` files.
    - Use `grep` with `path: "memory"` to quickly find relevant workspace notes before opening files.
    - Use `memory_topic` to scaffold durable topic notes from `memory/topics/TEMPLATE.md` for facts, preferences, decisions, people, dates, or project context.
    - Use `write` only when creating missing workspace memory files directly (`memory/topics/<topic-slug>.md` or `memory/YYYY-MM-DD.md`); prefer `memory_topic` for new topic notes.
    - Use `skill_manage` to create or update a skill when you learn a reusable procedure, command sequence, integration, debugging playbook, or verification checklist.
    - Use `todo` only for the active run's work queue and progress tracking; todos are not durable memory.
    - Use `edit` to keep `MEMORY.md` concise as an index of key facts and topic files.
    - If confidence is still low after checking memory files, say so explicitly.
    """
    |> String.trim()
  end

  defp build_learning_workflow_section(:subagent), do: ""

  defp build_learning_workflow_section(:main) do
    CodingAgent.PromptBuilder.build_learning_section()
  end

  defp skill_trace_opts(opts) do
    opts
    |> Map.take([:run_id, :session_key, :session_id, :agent_id])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp build_workspace_context_section([]), do: ""

  defp build_workspace_context_section(files) do
    has_soul =
      Enum.any?(files, fn file ->
        file.name |> String.downcase() == "soul.md"
      end)

    header = [
      "## Workspace Files (injected)",
      "These user-editable files are loaded by Lemon and included below.",
      "# Project Context",
      "The following workspace files have been loaded:"
    ]

    header =
      if has_soul do
        header ++
          [
            "If SOUL.md is present, embody its persona and tone. Avoid stiff, generic replies; follow its guidance unless higher-priority instructions override it."
          ]
      else
        header
      end

    body =
      files
      |> Enum.map(fn file ->
        [
          "## #{file.name}",
          file.content
        ]
        |> Enum.join("\n")
      end)
      |> Enum.join("\n\n")

    (header ++ ["", body])
    |> Enum.join("\n")
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp empty?(nil), do: true
  defp empty?(""), do: true
  defp empty?(s) when is_binary(s), do: String.trim(s) == ""
  defp empty?(_), do: false

  defp normalize_session_scope(scope) when scope in [:main, "main"], do: :main
  defp normalize_session_scope(scope) when scope in [:subagent, "subagent"], do: :subagent
  defp normalize_session_scope(_), do: :main
end
