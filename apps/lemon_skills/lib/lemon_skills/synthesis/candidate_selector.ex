defmodule LemonSkills.Synthesis.CandidateSelector do
  @moduledoc """
  Selects memory documents that are good candidates for skill synthesis.

  A document qualifies when it meets all of the following:

  - `outcome` is `:success` or `:partial`
  - `prompt_summary` is at least `#{__MODULE__}.min_prompt_length/0` characters (non-trivial)
  - `answer_summary` is at least `#{__MODULE__}.min_answer_length/0` characters (substantive)
  - Neither summary contains secret-looking content
  - The task family (derived from the prompt) is not `:chat` or `:unknown`

  Duplicate candidates (identical prompt_summary after normalization) are
  collapsed to one entry — the most recent one wins.
  """

  alias LemonCore.MemoryDocument
  alias LemonCore.TaskFingerprint

  @min_prompt_length 50
  @min_answer_length 100

  # Patterns that suggest the document contains secret material.
  @secret_patterns [
    ~r/\b(password|passwd|secret|token|api[-_]?key|access[-_]?key|auth[-_]?token)\s*[:=]\s*\S+/i,
    ~r/sk-[a-zA-Z0-9]{20,}/,
    ~r/AKIA[A-Z0-9]{16}/,
    ~r/-----BEGIN\s+(?:RSA\s+)?PRIVATE\s+KEY-----/,
    ~r/eyJ[a-zA-Z0-9+\/]{30,}/
  ]

  @doc """
  Select candidate documents from `documents`.

  Returns a filtered, deduplicated list of `MemoryDocument` structs.
  """
  @spec select([MemoryDocument.t()]) :: [MemoryDocument.t()]
  def select(documents) when is_list(documents) do
    documents
    |> Enum.filter(&qualified?/1)
    |> deduplicate()
  end

  @doc "Minimum prompt_summary length for a candidate."
  @spec min_prompt_length() :: pos_integer()
  def min_prompt_length, do: @min_prompt_length

  @doc "Minimum answer_summary length for a candidate."
  @spec min_answer_length() :: pos_integer()
  def min_answer_length, do: @min_answer_length

  # ── Private helpers ─────────────────────────────────────────────────────────

  defp qualified?(%MemoryDocument{} = doc) do
    good_outcome?(doc.outcome) and
      long_enough?(doc.prompt_summary, @min_prompt_length) and
      long_enough?(doc.answer_summary, @min_answer_length) and
      not secret_content?(doc) and
      actionable_family?(doc)
  end

  defp good_outcome?(:success), do: true
  defp good_outcome?(:partial), do: true
  defp good_outcome?(_), do: false

  defp long_enough?(nil, _min), do: false
  defp long_enough?(text, min) when is_binary(text), do: String.length(text) >= min

  defp secret_content?(%MemoryDocument{prompt_summary: prompt, answer_summary: answer}) do
    combined = (prompt || "") <> " " <> (answer || "")
    Enum.any?(@secret_patterns, &Regex.match?(&1, combined))
  end

  defp actionable_family?(%MemoryDocument{} = doc) do
    fp = TaskFingerprint.from_document(doc)
    fp.task_family not in [:chat, :unknown]
  end

  # Deduplicate by normalised prompt_summary — keep the most recent (first in
  # the list, which is assumed to be sorted newest-first from MemoryStore).
  defp deduplicate(docs) do
    docs
    |> Enum.uniq_by(fn doc ->
      doc.prompt_summary |> String.downcase() |> String.trim()
    end)
  end
end
