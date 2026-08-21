defmodule LemonCore.ResumeToken do
  @moduledoc """
  Session identifier for resuming an interrupted session.

  A token pairs the engine with the value that engine understands. Printing and
  parsing go through `LemonCore.ResumeFormats`: each engine registers its own
  syntax at boot, so nothing here knows how any particular CLI spells "resume".

  Engines with no registered format fall back to `<engine> resume <value>`,
  which is also what the platform prints for an engine it has never seen.

  ## Examples

      # Codex session
      %LemonCore.ResumeToken{engine: "codex", value: "thread_abc123"}

      # Claude session
      %LemonCore.ResumeToken{engine: "claude", value: "session_xyz"}

  """
  alias LemonCore.ResumeFormat
  alias LemonCore.ResumeFormats

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
  def format(%__MODULE__{} = token), do: "`" <> format_plain(token) <> "`"

  @doc """
  Format token for plain-text display without code fences.

      iex> LemonCore.ResumeToken.format_plain(%LemonCore.ResumeToken{engine: "lemon", value: "abc"})
      "lemon resume abc"

      iex> LemonCore.ResumeToken.format_plain(%LemonCore.ResumeToken{engine: "custom", value: "abc"})
      "custom resume abc"
  """
  @spec format_plain(t()) :: String.t()
  def format_plain(%__MODULE__{engine: engine, value: value}) do
    case ResumeFormats.fetch(engine) do
      {:ok, format} -> ResumeFormat.render(format, value)
      :error -> generic_line(engine, value)
    end
  end

  @doc """
  Extract a resume token from text.

  Tries every registered format in registration order and returns the first
  token found, or `nil`. Formats match anywhere in the text, so backticks and
  surrounding prose are fine.

  ## Examples

      iex> LemonCore.ResumeToken.extract_resume("Continue with `lemon resume abc12345`")
      %LemonCore.ResumeToken{engine: "lemon", value: "abc12345"}

      iex> LemonCore.ResumeToken.extract_resume("No resume token here")
      nil

  """
  @spec extract_resume(String.t()) :: t() | nil
  def extract_resume(text) when is_binary(text) do
    Enum.find_value(ResumeFormats.all(), fn format ->
      case ResumeFormat.capture(format, text) do
        value when is_binary(value) -> new(format.engine, value)
        _ -> nil
      end
    end)
  end

  def extract_resume(_), do: nil

  @doc """
  Extract a resume token for a specific engine from text.

  ## Examples

      iex> LemonCore.ResumeToken.extract_resume("custom resume abc", "custom")
      %LemonCore.ResumeToken{engine: "custom", value: "abc"}

      iex> LemonCore.ResumeToken.extract_resume("custom resume abc", "other")
      nil

  """
  @spec extract_resume(String.t(), String.t()) :: t() | nil
  def extract_resume(text, engine) when is_binary(text) and is_binary(engine) do
    case Regex.run(pattern_for(engine), text) do
      [_, value] -> new(engine, normalize_for(engine, value))
      _ -> nil
    end
  end

  @doc """
  Check if a line is exactly a resume line (for truncation preservation).

  This is a strict check - the line should be primarily a resume command,
  not just contain one among other text.

  ## Examples

      iex> LemonCore.ResumeToken.is_resume_line("`lemon resume abc12345`")
      true

      iex> LemonCore.ResumeToken.is_resume_line("Please run lemon resume abc")
      false

  """
  @spec is_resume_line(String.t()) :: boolean()
  # Public predicate name retained for resume-format consumers.
  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_resume_line(line) when is_binary(line) do
    Enum.any?(ResumeFormats.all(), &ResumeFormat.resume_line?(&1, line))
  end

  # Public predicate name retained for resume-format consumers.
  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_resume_line(_), do: false

  @doc """
  Check if a line is a resume line for a specific engine.
  """
  @spec is_resume_line(String.t(), String.t()) :: boolean()
  # Public predicate name retained for resume-format consumers.
  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_resume_line(line, engine) when is_binary(line) and is_binary(engine) do
    case ResumeFormats.fetch(engine) do
      {:ok, format} -> ResumeFormat.resume_line?(format, line)
      :error -> Regex.match?(generic_strict_pattern(engine), String.trim(line))
    end
  end

  defp pattern_for(engine) do
    case ResumeFormats.fetch(engine) do
      {:ok, format} -> format.pattern
      :error -> generic_pattern(engine)
    end
  end

  defp normalize_for(engine, value) do
    case ResumeFormats.fetch(engine) do
      {:ok, %ResumeFormat{normalize: normalize}} when is_function(normalize, 1) ->
        normalize.(value)

      _ ->
        value
    end
  end

  defp generic_line(engine, value), do: "#{engine} resume #{value}"

  defp generic_pattern(engine),
    do: ~r/`?#{Regex.escape(engine)}\s+resume\s+([a-zA-Z0-9_-]+)`?/i

  defp generic_strict_pattern(engine),
    do: ~r/^`?#{Regex.escape(engine)}\s+resume\s+[a-zA-Z0-9_-]+`?$/i
end
