defmodule LemonSkills.PromptView do
  @moduledoc """
  Renders skill metadata into system-prompt fragments.

  This module owns the canonical XML format used to surface available skills
  to the agent. Keeping the rendering logic here (in `lemon_skills`) rather
  than in `coding_agent` means both the main agent and any other agent or
  process can produce consistent skill listings without duplicating code.

  ## Output format

  Skills are rendered as an `<available_skills>` XML block:

      <available_skills>
        <skill>
          <name>K8s Rollout</name>
          <description>Manage Kubernetes rollouts</description>
          <location>/home/user/.lemon/agent/skill/k8s-rollout</location>
          <key>k8s-rollout</key>
          <activation_state>active</activation_state>
        </skill>
        <skill>
          <name>AWS Deploy</name>
          <description>Deploy to AWS</description>
          <location>/home/user/.lemon/agent/skill/aws-deploy</location>
          <key>aws-deploy</key>
          <activation_state>not_ready</activation_state>
          <missing>AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY</missing>
        </skill>
      </available_skills>

  ## Usage

      # Full section with header (for system prompts)
      section = LemonSkills.PromptView.render_for_prompt(cwd)

      # Just the XML block from pre-built views
      block = LemonSkills.PromptView.render_skill_list(views)
  """

  alias LemonSkills.{Registry, SkillView}

  @header """
  ## Skills (available)
  Before replying: scan <available_skills> <description> entries.
  - If exactly one skill clearly applies:
    Use `read_skill` with <key> to load it, then follow it.
    If `read_skill` isn't available, open its SKILL.md at <location> and follow it.
  - If multiple could apply: choose the most specific one, then follow it.
  - If none clearly apply: do not load any skill.
  - Prefer skills where <activation_state>active</activation_state> unless you are
    intentionally diagnosing missing requirements.\
  """

  @doc """
  Build the complete skills section (header + XML block) for a system prompt.

  Returns an empty string when no displayable skills are present.

  ## Options

  - `:cwd` — project working directory
  """
  @spec render_for_prompt(String.t() | nil, keyword()) :: String.t()
  def render_for_prompt(cwd, opts \\ []) do
    all_opts = if cwd, do: Keyword.put(opts, :cwd, cwd), else: opts

    views =
      Registry.list(all_opts)
      |> Enum.map(&SkillView.from_entry(&1, all_opts))
      |> Enum.filter(&SkillView.displayable?/1)

    if views == [] do
      ""
    else
      block = render_skill_list(views)

      """
      #{@header}

      #{block}\
      """
      |> String.trim()
    end
  end

  @doc """
  Render a `<relevant-skills>` XML block for context-filtered skills.

  Used by `CodingAgent.PromptBuilder` when only a relevance-selected subset of
  skills should appear (e.g. based on the current user message). Unlike the
  full `<available_skills>` list in the system prompt, this block shows only
  the skills that match the current context, with a `read_skill` reminder.

  Returns an empty string when `views` is empty.
  """
  @spec render_relevant_skills([SkillView.t()]) :: String.t()
  def render_relevant_skills([]), do: ""

  def render_relevant_skills(views) when is_list(views) do
    inner =
      views
      |> Enum.map(&render_entry/1)
      |> Enum.join("\n")

    """
    <relevant-skills>
    #{inner}
    Use `read_skill` with <key> to load the full content of any relevant skill.
    </relevant-skills>\
    """
    |> String.trim()
  end

  @doc """
  Render an `<available_skills>` XML block from a list of `SkillView`s.

  Returns an empty string when `views` is empty.
  """
  @spec render_skill_list([SkillView.t()]) :: String.t()
  def render_skill_list([]), do: ""

  def render_skill_list(views) when is_list(views) do
    inner =
      views
      |> Enum.map(&render_entry/1)
      |> Enum.join("\n")

    "<available_skills>\n#{inner}\n</available_skills>"
  end

  @doc """
  Render a single `<skill>` XML element from a `SkillView`.
  """
  @spec render_entry(SkillView.t()) :: String.t()
  def render_entry(%SkillView{} = view) do
    missing = SkillView.all_missing(view)

    lines = [
      "  <skill>",
      "    <name>#{escape(view.name)}</name>",
      "    <description>#{escape(view.description)}</description>",
      "    <location>#{escape(view.path)}</location>",
      "    <key>#{escape(view.key)}</key>",
      "    <activation_state>#{view.activation_state}</activation_state>"
    ]

    lines =
      if missing != [] do
        lines ++ ["    <missing>#{escape(Enum.join(missing, ", "))}</missing>"]
      else
        lines
      end

    (lines ++ ["  </skill>"]) |> Enum.join("\n")
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp escape(nil), do: ""

  defp escape(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
