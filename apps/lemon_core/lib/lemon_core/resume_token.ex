defmodule LemonCore.ResumeToken do
  @moduledoc """
  Session identifier for resuming an interrupted native Lemon session.

  Tokens retain their original `engine` field for persisted-history compatibility,
  but only native `lemon resume <id>` commands are parsed from text.
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

  @resume_pattern ~r/`?lemon\s+resume\s+([a-zA-Z0-9_-]+)`?/i
  @strict_resume_pattern ~r/^`?lemon\s+resume\s+[a-zA-Z0-9_-]+`?$/i

  @doc "Create a new resume token."
  @spec new(String.t(), String.t()) :: t()
  def new(engine, value) when is_binary(engine) and is_binary(value) do
    %__MODULE__{engine: engine, value: value}
  end

  @doc "Format token for display to a user."
  @spec format(t()) :: String.t()
  def format(%__MODULE__{} = token), do: "`" <> format_plain(token) <> "`"

  @doc """
  Format token for plain-text display without code fences.

      iex> LemonCore.ResumeToken.format_plain(%LemonCore.ResumeToken{engine: "lemon", value: "abc"})
      "lemon resume abc"
  """
  @spec format_plain(t()) :: String.t()
  def format_plain(%__MODULE__{engine: engine, value: value}), do: "#{engine} resume #{value}"

  @doc """
  Extract a native Lemon resume token from text.

  The command may be backticked or surrounded by prose. Non-native resume
  commands are not recognized.
  """
  @spec extract_resume(String.t()) :: t() | nil
  def extract_resume(text) when is_binary(text) do
    case Regex.run(@resume_pattern, text) do
      [_, value] -> new("lemon", value)
      _ -> nil
    end
  end

  def extract_resume(_), do: nil

  @doc "Extract a native Lemon resume token only when `engine` is `\"lemon\"`."
  @spec extract_resume(String.t(), String.t()) :: t() | nil
  def extract_resume(text, "lemon") when is_binary(text), do: extract_resume(text)
  def extract_resume(_text, _engine), do: nil

  @doc """
  Check whether a line is exactly a native Lemon resume command.

      iex> LemonCore.ResumeToken.is_resume_line("`lemon resume abc12345`")
      true

      iex> LemonCore.ResumeToken.is_resume_line("Please run lemon resume abc")
      false
  """
  @spec is_resume_line(String.t()) :: boolean()
  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_resume_line(line) when is_binary(line) do
    Regex.match?(@strict_resume_pattern, String.trim(line))
  end

  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_resume_line(_), do: false

  @doc "Check whether a line is exactly a native Lemon resume command for `engine`."
  @spec is_resume_line(String.t(), String.t()) :: boolean()
  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_resume_line(line, "lemon") when is_binary(line), do: is_resume_line(line)

  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_resume_line(_line, _engine), do: false
end
