defmodule CodingAgent.Session.PromptComposer do
  @moduledoc """
  Composes the system prompt from multiple sources.

  Handles loading and combining explicit prompts, prompt templates, the Lemon
  base prompt (skills + workspace context), instruction files (CLAUDE.md,
  AGENTS.md, ...) and rule files (`CodingAgent.Rules`). Also resolves session
  scope (main vs subagent).
  """

  alias CodingAgent.ResourceLoader
  alias CodingAgent.Rules

  # ============================================================================
  # System Prompt Composition
  # ============================================================================

  @doc """
  Compose system prompt from multiple sources:

  1. Explicit system_prompt option (highest priority)
  2. Prompt template content (if prompt_template option provided)
  3. Lemon base prompt (coding rules + skills + workspace context)
  4. CLAUDE.md/AGENTS.md/... content from ResourceLoader, then always-apply
     rules and the rulebook index from `CodingAgent.Rules`
  5. The session's environment block (`build_opts[:environment]`, captured once
     per session by `CodingAgent.SystemPrompt.Environment`)

  The environment block goes last on purpose: it holds the most volatile text
  (date, git status), and provider prompt caches keep every byte before the
  first difference.

  `build_opts` is merged into the map handed to `CodingAgent.SystemPrompt.build/2`.
  It carries the run identifiers used for skill-resolution tracing, and — from a
  caller that has already collected this turn's contributed sections —
  `:contributed_sections`.

  Passing those sections matters, and not only as an optimisation.
  `CodingAgent.SystemPrompt.build/2` collects them itself when they are absent,
  so a caller that collected and then did not pass them would run every
  contributor twice in one turn: twice the budget, twice the cost, and — for a
  contributor whose whole reason for existing is that its text changes — two
  different answers for the same turn, one placed in the system prompt and one
  in the user message. A caller with no sections of its own (a one-shot build
  outside a session) simply omits the key and gets the collect it always did.

  `skill_context` remains the turn query supplied to context contributors. It
  does not add relevance-selected skill metadata to the system prompt; the
  complete bounded available-skills list is stable across unrelated turns.
  """
  @spec compose_system_prompt(
          String.t(),
          String.t() | nil,
          String.t() | nil,
          String.t(),
          :main | :subagent,
          String.t(),
          map()
        ) :: String.t()
  def compose_system_prompt(
        cwd,
        explicit_prompt,
        prompt_template,
        workspace_dir,
        session_scope,
        skill_context \\ "",
        build_opts \\ %{}
      ) do
    cwd
    |> compose_sections(
      explicit_prompt,
      prompt_template,
      workspace_dir,
      session_scope,
      skill_context,
      build_opts
    )
    |> CodingAgent.SystemPrompt.join_sections()
  end

  @doc """
  The labelled sections `compose_system_prompt/7` joins, in prompt order, for
  context-usage accounting. Joining their texts with blank lines reproduces the
  composed prompt byte for byte.
  """
  @spec compose_sections(
          String.t(),
          String.t() | nil,
          String.t() | nil,
          String.t(),
          :main | :subagent,
          String.t(),
          map()
        ) :: [CodingAgent.SystemPrompt.section()]
  def compose_sections(
        cwd,
        explicit_prompt,
        prompt_template,
        workspace_dir,
        session_scope,
        skill_context \\ "",
        build_opts \\ %{}
      ) do
    # Load prompt template if specified
    template_content =
      case prompt_template do
        nil ->
          nil

        name ->
          case ResourceLoader.load_prompt(cwd, name) do
            {:ok, content} -> content
            {:error, :not_found} -> nil
          end
      end

    {environment, build_opts} = Map.pop(build_opts, :environment)

    # Build Lemon base prompt (coding rules + skills + workspace context)
    base_sections =
      CodingAgent.SystemPrompt.build_sections(
        cwd,
        %{
          workspace_dir: workspace_dir,
          session_scope: session_scope,
          skill_context: skill_context
        }
        |> Map.merge(build_opts)
      )

    # Static first, volatile last: explicit > template > base > instructions > rules > environment
    [
      top_level(:system_prompt, "Custom system prompt", explicit_prompt),
      top_level(:system_prompt, "Prompt template", template_content),
      base_sections,
      # Instructions (CLAUDE.md, AGENTS.md, ...) from global, ancestor and cwd scopes
      ResourceLoader.instruction_sections(cwd),
      # Rule files (.cursor/rules, .windsurf/rules, .lemon/rules, ...)
      Rules.sections(cwd),
      top_level(:system_prompt, "Environment", environment)
    ]
    |> List.flatten()
  end

  defp top_level(_category, _label, text) when text in [nil, ""], do: []
  defp top_level(category, label, text), do: [%{category: category, label: label, text: text}]

  # ============================================================================
  # Session Scope Resolution
  # ============================================================================

  @doc """
  Resolve session scope from options and parent session information.

  Returns `:main` or `:subagent` based on explicit option, or inferred from
  parent session presence.
  """
  @spec resolve_session_scope(keyword(), String.t() | nil, String.t() | nil) :: :main | :subagent
  def resolve_session_scope(opts, parent_session_opt, parent_session_from_file) do
    case Keyword.get(opts, :session_scope) do
      scope when scope in [:main, "main"] ->
        :main

      scope when scope in [:subagent, "subagent"] ->
        :subagent

      _ ->
        parent = first_non_empty_binary([parent_session_opt, parent_session_from_file])

        if is_binary(parent) do
          :subagent
        else
          :main
        end
    end
  end

  @doc """
  Refresh the system prompt if any source files have changed.

  Takes the current state fields needed for prompt composition and
  returns `{:changed, new_prompt, sections}` (see `compose_sections/7`) or
  `:unchanged`.

  "Changed" is a byte comparison, which is the right test precisely because the
  provider's prompt cache is keyed the same way: any difference at all
  invalidates the cached prefix, so any difference at all is worth propagating.
  The corollary is the one that shapes callers — everything reaching this
  function through `build_opts` should be text that does *not* differ turn to
  turn. Volatile material belongs after the last cache breakpoint, in the user
  message, and never in `:contributed_sections`.
  """
  @spec maybe_refresh_system_prompt(
          String.t(),
          String.t() | nil,
          String.t() | nil,
          String.t(),
          :main | :subagent,
          String.t(),
          String.t(),
          map()
        ) :: {:changed, String.t(), [CodingAgent.SystemPrompt.section()]} | :unchanged
  def maybe_refresh_system_prompt(
        cwd,
        explicit_system_prompt,
        prompt_template,
        workspace_dir,
        session_scope,
        current_prompt,
        skill_context \\ "",
        build_opts \\ %{}
      ) do
    sections =
      compose_sections(
        cwd,
        explicit_system_prompt,
        prompt_template,
        workspace_dir,
        session_scope,
        skill_context,
        build_opts
      )

    next_prompt = CodingAgent.SystemPrompt.join_sections(sections)

    if next_prompt == current_prompt do
      :unchanged
    else
      {:changed, next_prompt, sections}
    end
  end

  # ---- Private helpers ----

  defp first_non_empty_binary(list) when is_list(list) do
    Enum.find(list, fn v -> is_binary(v) and String.trim(v) != "" end)
  end
end
