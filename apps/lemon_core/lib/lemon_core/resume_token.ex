defmodule LemonCore.ResumeToken do
  @moduledoc """
  Session identifier for resuming interrupted CLI sessions.

  Each CLI tool (codex, claude, etc.) provides its own session ID format.
  The ResumeToken captures both the engine and the session value.

  ## Examples

      # Codex session
      %LemonCore.ResumeToken{engine: "codex", value: "thread_abc123"}

      # Claude session
      %LemonCore.ResumeToken{engine: "claude", value: "session_xyz"}

      # Kimi session
      %LemonCore.ResumeToken{engine: "kimi", value: "session_kimi"}

  """
  @type t :: %__MODULE__{
          engine: String.t(),
          value: String.t()
        }

  @enforce_keys [:engine, :value]
  # Resume tokens are persisted into session JSONL files (via CodingAgent.SessionManager).
  # Encode only the explicit fields to avoid accidental leakage if this struct grows.
  @derive {Jason.Encoder, only: [:engine, :value]}
  defstruct [:engine, :value]

  @doc "Create a new resume token"
  def new(engine, value) when is_binary(engine) and is_binary(value) do
    %__MODULE__{engine: engine, value: value}
  end

  @doc "Format token for display to user"
  def format(%__MODULE__{engine: engine, value: value}) do
    case engine do
      "codex" -> "`codex resume #{value}`"
      "claude" -> "`claude --resume #{value}`"
      "kimi" -> "`kimi --session #{value}`"
      "opencode" -> "`opencode --session #{value}`"
      "pi" -> "`pi --session #{quote_token(value)}`"
      "lemon" -> "`lemon resume #{value}`"
      _ -> "`#{engine} resume #{value}`"
    end
  end

  @doc """
  Extract a resume token from text.

  Searches text for resume line patterns from any supported engine.
  Returns the first token found, or nil if none.

  Handles various formats:
  - Plain text: `codex resume abc123`
  - Backticks: `` `claude --resume xyz` ``
  - Code blocks: ```codex resume abc123```

  ## Examples

      iex> LemonCore.ResumeToken.extract_resume("Please run `codex resume thread_abc123`")
      %LemonCore.ResumeToken{engine: "codex", value: "thread_abc123"}

      iex> LemonCore.ResumeToken.extract_resume("Continue with claude --resume session_xyz")
      %LemonCore.ResumeToken{engine: "claude", value: "session_xyz"}

      iex> LemonCore.ResumeToken.extract_resume("Continue with kimi --session session_kimi")
      %LemonCore.ResumeToken{engine: "kimi", value: "session_kimi"}

      iex> LemonCore.ResumeToken.extract_resume("lemon resume abc12345")
      %LemonCore.ResumeToken{engine: "lemon", value: "abc12345"}

      iex> LemonCore.ResumeToken.extract_resume("No resume token here")
      nil

  """
  @spec extract_resume(String.t()) :: t() | nil
  def extract_resume(text) when is_binary(text) do
    # Try each engine's pattern in order
    patterns = [
      # Codex: `codex resume <thread_id>` or codex resume <thread_id>
      {~r/`?codex\s+resume\s+([a-zA-Z0-9_-]+)`?/i, "codex"},
      # Claude: `claude --resume <session_id>` or claude --resume <session_id>
      {~r/`?claude\s+--resume\s+([a-zA-Z0-9_-]+)`?/i, "claude"},
      # Kimi: `kimi --session <session_id>` or kimi --session <session_id>
      {~r/`?kimi\s+--session\s+([a-zA-Z0-9_-]+)`?/i, "kimi"},
      # OpenCode: `opencode --session <ses_...>` (optionally `opencode run --session`)
      {~r/`?opencode(?:\s+run)?\s+(?:--session|-s)\s+(ses_[A-Za-z0-9]+)`?/i, "opencode"},
      # Pi: `pi --session <token>` (token may be quoted)
      {~r/`?pi\s+--session\s+("(?:[^"\\]|\\.)+"|'(?:[^'\\]|\\.)+'|\S+)`?/i, "pi"},
      # Lemon: `lemon resume <session_id>` or lemon resume <session_id>
      {~r/`?lemon\s+resume\s+([a-zA-Z0-9_-]+)`?/i, "lemon"}
    ]

    Enum.find_value(patterns, fn {regex, engine} ->
      case Regex.run(regex, text) do
        [_, value] ->
          value =
            if engine == "pi" do
              strip_quotes(value)
            else
              value
            end

          new(engine, value)

        _ ->
          nil
      end
    end)
  end

  def extract_resume(_), do: nil

  @doc """
  Extract a resume token for a specific engine from text.

  ## Examples

      iex> LemonCore.ResumeToken.extract_resume("codex resume abc", "codex")
      %LemonCore.ResumeToken{engine: "codex", value: "abc"}

      iex> LemonCore.ResumeToken.extract_resume("codex resume abc", "claude")
      nil

  """
  @spec extract_resume(String.t(), String.t()) :: t() | nil
  def extract_resume(text, engine) when is_binary(text) and is_binary(engine) do
    regex = resume_regex(engine)

    case Regex.run(regex, text) do
      [_, value] ->
        value = if engine == "pi", do: strip_quotes(value), else: value
        new(engine, value)

      _ ->
        nil
    end
  end

  @doc """
  Check if a line is exactly a resume line (for truncation preservation).

  This is a strict check - the line should be primarily a resume command,
  not just contain one among other text.

  ## Examples

      iex> LemonCore.ResumeToken.is_resume_line("codex resume thread_abc123")
      true

      iex> LemonCore.ResumeToken.is_resume_line("`claude --resume session_xyz`")
      true

      iex> LemonCore.ResumeToken.is_resume_line("Please run codex resume abc")
      false

      iex> LemonCore.ResumeToken.is_resume_line("Some other text")
      false

  """
  @spec is_resume_line(String.t()) :: boolean()
  def is_resume_line(line) when is_binary(line) do
    line = String.trim(line)

    patterns = [
      # Strict patterns - line should be essentially just the resume command
      # Codex
      ~r/^`?codex\s+resume\s+[a-zA-Z0-9_-]+`?$/i,
      # Claude
      ~r/^`?claude\s+--resume\s+[a-zA-Z0-9_-]+`?$/i,
      # Kimi
      ~r/^`?kimi\s+--session\s+[a-zA-Z0-9_-]+`?$/i,
      # OpenCode
      ~r/^`?opencode(?:\s+run)?\s+(?:--session|-s)\s+ses_[A-Za-z0-9]+`?$/i,
      # Pi (token may be quoted)
      ~r/^`?pi\s+--session\s+("(?:[^"\\]|\\.)+"|'(?:[^'\\]|\\.)+'|\S+)`?$/i,
      # Lemon
      ~r/^`?lemon\s+resume\s+[a-zA-Z0-9_-]+`?$/i
    ]

    Enum.any?(patterns, fn regex -> Regex.match?(regex, line) end)
  end

  def is_resume_line(_), do: false

  @doc """
  Check if a line is a resume line for a specific engine.
  """
  @spec is_resume_line(String.t(), String.t()) :: boolean()
  def is_resume_line(line, engine) when is_binary(line) and is_binary(engine) do
    line = String.trim(line)
    regex = strict_resume_regex(engine)
    Regex.match?(regex, line)
  end

  # Private helpers for engine-specific regex patterns

  defp resume_regex("codex"), do: ~r/`?codex\s+resume\s+([a-zA-Z0-9_-]+)`?/i
  defp resume_regex("claude"), do: ~r/`?claude\s+--resume\s+([a-zA-Z0-9_-]+)`?/i
  defp resume_regex("kimi"), do: ~r/`?kimi\s+--session\s+([a-zA-Z0-9_-]+)`?/i

  defp resume_regex("opencode"),
    do: ~r/`?opencode(?:\s+run)?\s+(?:--session|-s)\s+(ses_[A-Za-z0-9]+)`?/i

  defp resume_regex("pi"),
    do: ~r/`?pi\s+--session\s+("(?:[^"\\]|\\.)+"|'(?:[^'\\]|\\.)+'|\S+)`?/i

  defp resume_regex("lemon"), do: ~r/`?lemon\s+resume\s+([a-zA-Z0-9_-]+)`?/i
  defp resume_regex(engine), do: ~r/`?#{Regex.escape(engine)}\s+resume\s+([a-zA-Z0-9_-]+)`?/i

  defp strict_resume_regex("codex"), do: ~r/^`?codex\s+resume\s+[a-zA-Z0-9_-]+`?$/i
  defp strict_resume_regex("claude"), do: ~r/^`?claude\s+--resume\s+[a-zA-Z0-9_-]+`?$/i
  defp strict_resume_regex("kimi"), do: ~r/^`?kimi\s+--session\s+[a-zA-Z0-9_-]+`?$/i

  defp strict_resume_regex("opencode"),
    do: ~r/^`?opencode(?:\s+run)?\s+(?:--session|-s)\s+ses_[A-Za-z0-9]+`?$/i

  defp strict_resume_regex("pi"),
    do: ~r/^`?pi\s+--session\s+("(?:[^"\\]|\\.)+"|'(?:[^'\\]|\\.)+'|\S+)`?$/i

  defp strict_resume_regex("lemon"), do: ~r/^`?lemon\s+resume\s+[a-zA-Z0-9_-]+`?$/i

  defp strict_resume_regex(engine),
    do: ~r/^`?#{Regex.escape(engine)}\s+resume\s+[a-zA-Z0-9_-]+`?$/i

  defp strip_quotes(value) when is_binary(value) do
    trimmed = String.trim(value)

    if String.length(trimmed) >= 2 do
      first = String.first(trimmed)
      last = String.last(trimmed)

      if first == last and first in ["\"", "'"] do
        String.slice(trimmed, 1, String.length(trimmed) - 2)
      else
        trimmed
      end
    else
      trimmed
    end
  end

  defp quote_token(value) when is_binary(value) do
    needs_quotes = Regex.match?(~r/\s/, value)

    cond do
      not needs_quotes and not String.contains?(value, "\"") ->
        value

      true ->
        escaped = String.replace(value, "\"", "\\\"")
        "\"#{escaped}\""
    end
  end

  defp quote_token(value), do: to_string(value)
end
