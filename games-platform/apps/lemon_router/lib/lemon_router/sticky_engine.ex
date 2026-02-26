defmodule LemonRouter.StickyEngine do
  @moduledoc """
  Extracts engine preference from user prompts.

  Detects patterns like "use codex", "switch to claude", "with gemini" at the
  start of a message and returns the engine ID if it matches a known engine.
  """

  @doc """
  Attempt to extract an engine preference from the beginning of a prompt.

  Returns `{:ok, engine_id}` if a known engine switch pattern is found,
  or `:none` if no engine preference is detected.

  ## Patterns matched

  - "use <engine>"
  - "switch to <engine>"
  - "with <engine>"

  These are matched case-insensitively and only at the start of the prompt
  (with optional leading whitespace).
  """
  @spec extract_from_prompt(String.t() | nil) :: {:ok, String.t()} | :none
  def extract_from_prompt(nil), do: :none
  def extract_from_prompt(""), do: :none

  def extract_from_prompt(prompt) when is_binary(prompt) do
    trimmed = String.trim(prompt)

    case extract_engine_token(trimmed) do
      nil -> :none
      engine_id -> {:ok, engine_id}
    end
  end

  def extract_from_prompt(_), do: :none

  @doc """
  Apply sticky engine logic for a run.

  Given the current session config, the run's explicit engine_id, and the prompt,
  determines the effective engine_id and any updates to the session policy.

  Returns `{effective_engine_id, session_updates}` where:
  - `effective_engine_id` is the engine to use for this run (or nil for default)
  - `session_updates` is a map to merge into session policy (may contain `:preferred_engine`)
  """
  @spec resolve(map()) :: {String.t() | nil, map()}
  def resolve(opts) do
    explicit_engine = opts[:explicit_engine_id]
    prompt = opts[:prompt]
    session_preferred = opts[:session_preferred_engine]

    # Priority: explicit request engine > prompt-detected engine > session sticky engine
    cond do
      # Explicit engine_id on the request takes priority and becomes the new sticky
      is_binary(explicit_engine) and explicit_engine != "" ->
        {explicit_engine, %{preferred_engine: explicit_engine}}

      # Check if the prompt contains an engine switch directive
      true ->
        case extract_from_prompt(prompt) do
          {:ok, engine_id} ->
            {engine_id, %{preferred_engine: engine_id}}

          :none ->
            # Fall back to session's sticky engine preference
            if is_binary(session_preferred) and session_preferred != "" do
              {session_preferred, %{}}
            else
              {nil, %{}}
            end
        end
    end
  end

  # -- Private --

  # Pattern: "use <engine>", "switch to <engine>", "with <engine>"
  # Matched case-insensitively at start of prompt.
  @engine_pattern ~r/\A\s*(?:use|switch\s+to|with)\s+([a-z][a-z0-9_-]*)\b/i

  defp extract_engine_token(text) do
    case Regex.run(@engine_pattern, text) do
      [_full, candidate] ->
        engine_id = String.downcase(candidate)

        if engine_known?(engine_id) do
          engine_id
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp engine_known?(engine_id) do
    LemonChannels.EngineRegistry.engine_known?(engine_id)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end
end
