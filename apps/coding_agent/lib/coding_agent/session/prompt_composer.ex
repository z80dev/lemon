defmodule CodingAgent.Session.PromptComposer do
  @moduledoc """
  Composes the system prompt from multiple sources.

  Handles loading and combining explicit prompts, prompt templates, the Lemon
  base prompt (skills + workspace context), and instruction files (CLAUDE.md,
  AGENTS.md). Also resolves session scope (main vs subagent).
  """

  alias CodingAgent.ResourceLoader

  # ============================================================================
  # System Prompt Composition
  # ============================================================================

  @doc """
  Compose system prompt from multiple sources:

  1. Explicit system_prompt option (highest priority)
  2. Prompt template content (if prompt_template option provided)
  3. Lemon base prompt (skills + workspace context)
  4. CLAUDE.md/AGENTS.md content from ResourceLoader

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

    # Build Lemon base prompt (skills + workspace context)
    base_prompt =
      CodingAgent.SystemPrompt.build(
        cwd,
        %{
          workspace_dir: workspace_dir,
          session_scope: session_scope,
          skill_context: skill_context
        }
        |> Map.merge(build_opts)
      )

    # Load instructions (CLAUDE.md, AGENTS.md) from cwd and parent directories
    instructions = ResourceLoader.load_instructions(cwd)

    # Compose in order: explicit > template > base > instructions
    [explicit_prompt, template_content, base_prompt, instructions]
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

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
  returns `{:changed, new_prompt}` or `:unchanged`.

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
        ) :: {:changed, String.t()} | :unchanged
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
    next_prompt =
      compose_system_prompt(
        cwd,
        explicit_system_prompt,
        prompt_template,
        workspace_dir,
        session_scope,
        skill_context,
        build_opts
      )

    if next_prompt == current_prompt do
      :unchanged
    else
      {:changed, next_prompt}
    end
  end

  # ---- Private helpers ----

  defp first_non_empty_binary(list) when is_list(list) do
    Enum.find(list, fn v -> is_binary(v) and String.trim(v) != "" end)
  end
end
