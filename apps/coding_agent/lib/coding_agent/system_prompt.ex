defmodule CodingAgent.SystemPrompt do
  @moduledoc """
  Builds Lemon system prompts with workspace context + skills.

  This is a Lemon-specific adaptation of OpenClaw's prompt structure:
  - No tool list section (Lemon surfaces tools elsewhere)
  - No gateway restart/self-update section
  - Keeps skills + workspace file context
  """

  alias CodingAgent.{Skills, Workspace}

  @type opts :: %{
          optional(:workspace_dir) => String.t(),
          optional(:bootstrap_max_chars) => pos_integer(),
          optional(:session_scope) => :main | :subagent | String.t()
        }

  @spec build(String.t(), opts()) :: String.t()
  def build(cwd, opts \\ %{}) do
    workspace_dir = Map.get(opts, :workspace_dir, Workspace.workspace_dir())
    max_chars = Map.get(opts, :bootstrap_max_chars, Workspace.default_max_chars())
    session_scope = normalize_session_scope(Map.get(opts, :session_scope, :main))

    bootstrap_files =
      Workspace.load_bootstrap_files(
        workspace_dir: workspace_dir,
        max_chars: max_chars,
        session_scope: session_scope
      )

    sections = [
      "You are a personal assistant running inside Lemon.",
      build_runtime_section(session_scope),
      build_skills_section(cwd),
      build_memory_workflow_section(session_scope),
      build_workspace_section(workspace_dir),
      build_workspace_context_section(bootstrap_files)
    ]

    sections
    |> Enum.reject(&empty?/1)
    |> Enum.join("\n\n")
  end

  # ============================================================================
  # Sections
  # ============================================================================

  defp build_skills_section(cwd) do
    skills = Skills.list(cwd)

    if skills == [] do
      ""
    else
      body =
        skills
        |> Enum.map(fn skill ->
          [
            "  <skill>",
            "    <name>#{skill.name}</name>",
            "    <description>#{escape(skill.description)}</description>",
            "    <location>#{skill.path}</location>",
            "  </skill>"
          ]
          |> Enum.join("\n")
        end)
        |> Enum.join("\n")

      """
      ## Skills (available)
      Before replying: scan <available_skills> <description> entries.
      - If exactly one skill clearly applies: open its SKILL.md at <location> and follow it.
      - If multiple could apply: choose the most specific one, then follow it.
      - If none clearly apply: do not load any skill.

      <available_skills>
      #{body}
      </available_skills>
      """
      |> String.trim()
    end
  end

  defp build_workspace_section(workspace_dir) do
    """
    ## Workspace
    Your workspace directory is: #{workspace_dir}
    Treat it as the persistent home for identity, memory, and operating notes.
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
    Before answering about prior decisions, preferences, people, dates, or todos, inspect memory files first.
    - Use `read` to check `MEMORY.md` and relevant `memory/YYYY-MM-DD.md` files.
    - Use `write` to create missing `memory/YYYY-MM-DD.md` files.
    - Use `edit` to update `MEMORY.md` or daily memory files with durable facts.
    - If confidence is still low after checking memory files, say so explicitly.
    """
    |> String.trim()
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

  defp escape(nil), do: ""

  defp escape(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp normalize_session_scope(scope) when scope in [:main, "main"], do: :main
  defp normalize_session_scope(scope) when scope in [:subagent, "subagent"], do: :subagent
  defp normalize_session_scope(_), do: :main
end
