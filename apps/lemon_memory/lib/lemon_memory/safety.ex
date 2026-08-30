defmodule LemonMemory.Safety do
  @moduledoc """
  Shared safety checks for durable memory documents.
  """

  alias LemonMemory.Document

  @secret_patterns [
    ~r/\b(password|passwd|secret|token|api[-_]?key|access[-_]?key|auth[-_]?token)\s*[:=]\s*\S+/i,
    ~r/\bsk-[a-zA-Z0-9_-]{20,}/,
    ~r/\bAKIA[A-Z0-9]{16}\b/,
    ~r/-----BEGIN\s+(?:[A-Z0-9]+\s+)*PRIVATE\s+KEY-----/,
    ~r/\beyJ[a-zA-Z0-9+\/_-]{30,}/
  ]

  @doc """
  Returns true when text contains common secret-looking material.
  """
  @spec contains_secret?(term()) :: boolean()
  def contains_secret?(text) when is_binary(text) do
    Enum.any?(@secret_patterns, &Regex.match?(&1, text))
  end

  def contains_secret?(_), do: false

  @doc """
  Redact common secret-looking material before it crosses a durable-memory or
  operator-output boundary.

  Returns the redacted text and the number of matched values. The replacement
  deliberately drops the complete match instead of preserving assignment
  names: source-learning callers must not reveal secret names either.
  """
  @spec redact(term()) :: {String.t(), non_neg_integer()}
  def redact(text) when is_binary(text) do
    Enum.reduce(@secret_patterns, {text, 0}, fn pattern, {current, count} ->
      matches = Regex.scan(pattern, current) |> length()
      {Regex.replace(pattern, current, "[REDACTED]"), count + matches}
    end)
  end

  def redact(_), do: {"", 0}

  @doc """
  Returns true when the memory document summaries are safe to store or mine.
  """
  @spec safe_document?(Document.t()) :: boolean()
  def safe_document?(%Document{prompt_summary: prompt, answer_summary: answer}) do
    combined = (prompt || "") <> " " <> (answer || "")
    not contains_secret?(combined)
  end
end
