defmodule LemonSkills.Synthesis.CandidateSelector do
  @moduledoc """
  Selects memory documents that are good candidates for skill synthesis.

  A document qualifies when it meets all of the following:

  - `outcome` is `:success` (`:partial` is deliberately excluded — see anti-capture below)
  - `prompt_summary` is at least `#{__MODULE__}.min_prompt_length/0` characters (non-trivial)
  - `answer_summary` is at least `#{__MODULE__}.min_answer_length/0` characters (substantive)
  - Neither summary contains secret-looking content
  - Neither summary asserts a negative capability claim or unresolved failure
    ("doesn't work", "not supported", "gave up", ...) — see anti-capture below
  - The task family (derived from the prompt) is not `:chat` or `:unknown`

  ## Anti-capture

  Synthesized skills feed back into future agent behavior, so a memory that
  records a clean give-up ("this tool doesn't work", "that can't be done")
  hardens into a learned refusal: the agent stops trying things it could in
  fact do. Two guardrails keep those documents out of the candidate pool:

  - **Outcome level** — only `:success` qualifies. `LemonCore.RunOutcome.infer/1`
    labels a run `:partial` when it completed ok but produced no substantive
    answer, which is exactly the clean-give-up shape.
  - **Content level** — documents whose summaries assert negative tool or
    capability claims are rejected even when the outcome is `:success`, since
    a "successful" run can still conclude with a confident (and possibly
    wrong) "there is no way to do X".

  Duplicate candidates (identical prompt_summary after normalization) are
  collapsed to one entry — the most recent one wins.
  """

  alias LemonMemory.Document
  alias LemonMemory.Safety
  alias LemonMemory.TaskFingerprint

  @min_prompt_length 50
  @min_answer_length 100

  # Anti-capture (Hermes rationale): phrases that assert a negative tool or
  # capability claim, or an unresolved failure, as the substance of the
  # document. Learning these as skills hardens them into refusals, so we
  # reject the document outright. Patterns are conservative and anchored on
  # word boundaries to avoid over-blocking ordinary prose.
  @negative_claim_patterns [
    ~r/\bdoesn'?t\s+(?:seem\s+to\s+)?work\b/iu,
    ~r/\bdoes\s+not\s+(?:seem\s+to\s+)?work\b/iu,
    ~r/\bnot\s+supported\b/iu,
    ~r/\bunable\s+to\b/iu,
    ~r/\bcan'?t\s+be\s+done\b/iu,
    ~r/\bcannot\s+be\s+done\b/iu,
    ~r/\b(?:gave|giving)\s+up\b/iu,
    ~r/\bis\s+broken\b/iu,
    ~r/\bno\s+way\s+to\b/iu
  ]

  # "failed to" is only a capture signal when it reads as the *final state* of
  # the run — a success narrative legitimately mentions intermediate failures
  # ("the first build failed to compile, so I ..."). We therefore only check
  # the closing sentence of the answer summary for it.
  @final_failure_pattern ~r/\bfailed\s+to\b/iu

  @doc """
  Select candidate documents from `documents`.

  Returns a filtered, deduplicated list of `Document` structs.
  """
  @spec select([Document.t()]) :: [Document.t()]
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

  defp qualified?(%Document{} = doc) do
    good_outcome?(doc.outcome) and
      long_enough?(doc.prompt_summary, @min_prompt_length) and
      long_enough?(doc.answer_summary, @min_answer_length) and
      Safety.safe_document?(doc) and
      actionable_family?(doc) and
      not negative_capture?(doc)
  end

  # Anti-capture: :partial is excluded on purpose. RunOutcome.infer/1 labels a
  # run :partial when it completed ok but produced no substantive answer — the
  # "clean give-up / this tool doesn't work" shape. Synthesizing skills from
  # those hardens the give-up into a learned refusal.
  defp good_outcome?(:success), do: true
  defp good_outcome?(_), do: false

  defp long_enough?(nil, _min), do: false
  defp long_enough?(text, min) when is_binary(text), do: String.length(text) >= min

  # Anti-capture, content level (Hermes rationale): reject documents whose
  # summaries assert that a tool/capability doesn't work or that the task was
  # abandoned. Even a :success-labelled run can end with a confident negative
  # claim, and once synthesized into a skill that claim keeps the agent from
  # ever retrying. See @negative_claim_patterns / @final_failure_pattern.
  defp negative_capture?(%Document{} = doc) do
    negative_claim?(doc.prompt_summary) or
      negative_claim?(doc.answer_summary) or
      ends_in_failure_claim?(doc.answer_summary)
  end

  defp negative_claim?(nil), do: false

  defp negative_claim?(text) when is_binary(text) do
    Enum.any?(@negative_claim_patterns, &Regex.match?(&1, text))
  end

  defp ends_in_failure_claim?(nil), do: false

  defp ends_in_failure_claim?(text) when is_binary(text) do
    Regex.match?(@final_failure_pattern, last_sentence(text))
  end

  defp last_sentence(text) do
    text
    |> String.trim()
    |> String.split(~r/(?<=[.!?])\s+|\n+/u, trim: true)
    |> List.last()
    |> Kernel.||("")
  end

  defp actionable_family?(%Document{} = doc) do
    fp = TaskFingerprint.from_document(doc)
    fp.task_family not in [:chat, :unknown]
  end

  # Deduplicate by normalised prompt_summary — keep the most recent. The input
  # order is NOT assumed: a watermark-driven fetch returns documents
  # oldest-first, so we sort newest-first explicitly before collapsing.
  defp deduplicate(docs) do
    docs
    |> Enum.sort_by(&{&1.ingested_at_ms || 0, &1.doc_id}, :desc)
    |> Enum.uniq_by(fn doc ->
      doc.prompt_summary |> String.downcase() |> String.trim()
    end)
  end
end
