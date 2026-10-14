defmodule LemonMemory.Safety do
  @moduledoc """
  Shared safety checks for durable memory documents.

  Credential matching is shared with `LemonCore.Redact`. Operator previews add
  URL/path, standalone Basic authorization, and secret-name omission on top.
  """

  alias LemonMemory.Document

  @unsafe_controls ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}\x{FEFF}]/u
  @injection ~r/ignore (all )?(previous|prior|above) instructions|disregard (all )?(previous|prior|above) instructions|reveal (the )?(system|developer) prompt|system prompt|developer message|<\|\/?(?:system|developer|assistant|user)\|>/iu

  @doc "Screen prompt-injected notes without changing their accepted bytes."
  def validate_note(text, opts \\ []) do
    max_bytes = Keyword.get(opts, :max_bytes, 4_096)
    cond do
      not is_binary(text) -> {:error, :invalid_text}
      not String.valid?(text) or byte_size(text) > max_bytes -> {:error, :invalid_text}
      String.trim(text) == "" -> {:error, :empty_text}
      note_refusal_reason(text) != nil -> {:error, :unsafe_text}
      true -> :ok
    end
  end

  @doc "Detailed screening reason, shared by private and legacy preference owners."
  def note_refusal_reason(text) when is_binary(text) do
    cond do
      contains_secret?(text) -> :secret
      Regex.match?(@unsafe_controls, text) -> :invisible
      Regex.match?(@injection, text) -> :prompt_injection
      true -> nil
    end
  end
  def note_refusal_reason(_), do: nil

  @doc """
  Returns true when text contains common secret-looking material.
  """
  @spec contains_secret?(term()) :: boolean()
  def contains_secret?(text) when is_binary(text) do
    LemonCore.Redact.text(text) != text
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
  def redact(text) when is_binary(text),
    do: LemonCore.Redact.text(text, drop_keys: true, count: true)

  def redact(_), do: {"", 0}

  @operator_patterns [
    ~r/\b[a-z][a-z0-9+.-]*:\/\/[^\s<>"']+/iu,
    ~r/\bmailto:[^\s<>"']+/iu,
    ~r/(?<![\w.-])\/(?:[^\s\/<>"']+\/)*[^\s\/<>"']+/u,
    ~r/\b[A-Za-z]:\\[^\s<>"']+/u,
    ~r/\bbasic\s+[A-Za-z0-9._~+\/=:-]{8,}\b/iu,
    ~r/\b[A-Z][A-Z0-9_]{1,63}(?:KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|CREDENTIALS)\b/u
  ]

  @doc """
  Redact text for authenticated operator surfaces.

  This applies the durable-memory secret redaction first, then removes raw
  URLs, common absolute path forms, and standalone secret/environment names.
  Invisible controls are discarded and the result is capped on a UTF-8
  boundary. The returned count includes every replacement.
  """
  @spec redact_for_operator(term(), keyword()) :: {String.t(), non_neg_integer()}
  def redact_for_operator(text, opts \\ []) do
    max_bytes = opts |> Keyword.get(:max_bytes, 1_200) |> clamp_max_bytes()
    {redacted, count} = redact(text)

    {redacted, count} =
      Enum.reduce(@operator_patterns, {redacted, count}, fn pattern, {current, total} ->
        matches = Regex.scan(pattern, current) |> length()
        {Regex.replace(pattern, current, "[REDACTED]"), total + matches}
      end)

    cleaned =
      redacted
      |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u, "")
      |> truncate_utf8(max_bytes)

    {cleaned, count}
  end

  @doc """
  Returns true when the memory document summaries are safe to store or mine.
  """
  @spec safe_document?(Document.t()) :: boolean()
  def safe_document?(%Document{prompt_summary: prompt, answer_summary: answer}) do
    combined = (prompt || "") <> " " <> (answer || "")
    not contains_secret?(combined)
  end

  defp clamp_max_bytes(value) when is_integer(value) and value in 1..8_000, do: value
  defp clamp_max_bytes(_), do: 1_200

  defp truncate_utf8(text, max_bytes) when byte_size(text) <= max_bytes, do: text

  defp truncate_utf8(text, max_bytes) do
    boundary = utf8_boundary(text, max_bytes)
    binary_part(text, 0, boundary) <> "…"
  end

  defp utf8_boundary(text, position) when position > 0 do
    if String.valid?(binary_part(text, 0, position)),
      do: position,
      else: utf8_boundary(text, position - 1)
  end

  defp utf8_boundary(_text, 0), do: 0
end
