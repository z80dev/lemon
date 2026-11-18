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

  1. Explicit system_prompt option
  2. Directory-independent Lemon guidance (identity, coding rules and runtime)
  3. Directory-derived footer: prompt template, skills, contributed context,
     workspace files, instruction files, rules and captured environment

  `prompt_blocks/2` preserves these exact bytes while separating the shared
  static prefix from the directory-derived footer. Anthropic caches the prefix
  before that footer; other providers concatenate the blocks.
  Layout and instruction paths are stable session-start snapshots. Current date
  and Git status belong in user-turn context, not this prefix.

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

    # Only these built-in sections are independent of cwd. Skill discovery,
    # contributed context, templates and bootstrap files can all depend on it.
    {static, directory} =
      Enum.split_with(base_sections, fn section ->
        section.label in [
          "Identity",
          "Coding guidance",
          "Terminal visuals",
          "Runtime",
          "Memory guidance",
          "Learning workflow"
        ]
      end)

    static_sections =
      [top_level(:system_prompt, "Custom system prompt", explicit_prompt), static]
      |> List.flatten()
      |> Enum.map(&Map.put(&1, :directory_derived, false))

    directory_sections =
      [
        top_level(:system_prompt, "Prompt template", template_content),
        directory,
        ResourceLoader.instruction_sections(cwd,
          foreign_globals: build_opts[:session_mode] in [:coding, "coding"]
        ),
        Rules.sections(cwd),
        top_level(:system_prompt, "Environment", environment)
      ]
      |> List.flatten()
      |> Enum.map(&Map.put(&1, :directory_derived, true))

    static_sections ++ directory_sections
  end

  defp top_level(_category, _label, text) when text in [nil, ""], do: []
  defp top_level(category, label, text), do: [%{category: category, label: label, text: text}]

  @doc """
  Convert the composed text to ordered provider blocks without changing bytes.

  The shared static prefix is one block; directory-derived sections form the
  footer. Separators belong to the footer, so the prefix is identical even when
  directories have different instruction files. An unmatched prompt (for example
  a planning overlay or restored legacy prompt) is conservatively directory-derived.
  """
  @spec prompt_blocks(String.t(), [map()]) :: [map()]
  def prompt_blocks(prompt, sections) when is_binary(prompt) and is_list(sections) do
    if CodingAgent.SystemPrompt.join_sections(sections) == prompt do
      {static, directory} =
        Enum.split_while(sections, &(Map.get(&1, :directory_derived, true) == false))

      prefix = CodingAgent.SystemPrompt.join_sections(static)
      footer = CodingAgent.SystemPrompt.join_sections(directory)

      [
        %{text: prefix, directory_derived: false},
        %{
          text: if(prefix != "" and footer != "", do: "\n\n" <> footer, else: footer),
          directory_derived: true
        }
      ]
      |> Enum.reject(&(&1.text == ""))
    else
      [%{text: prompt, directory_derived: true}]
    end
  end

  @doc """
  Classify native sessions without treating every session with a cwd as chat.
  Main/profile and messaging sessions retain assistant context; local TUI, ACP,
  CLI and direct cwd-scoped sessions default to coding. Explicit mode wins.
  """
  def resolve_session_mode(opts) do
    case Keyword.get(opts, :session_mode) do
      mode when mode in [:coding, "coding"] ->
        :coding

      mode when mode in [:chat, "chat"] ->
        :chat

      _ ->
        case LemonCore.SessionKey.parse(Keyword.get(opts, :session_key) || "") do
          %{kind: :main} -> :chat
          %{channel_id: channel} when channel not in ["tui", "acp", "cli"] -> :chat
          _ -> :coding
        end
    end
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
