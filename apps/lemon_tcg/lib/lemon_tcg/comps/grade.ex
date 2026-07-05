defmodule LemonTcg.Comps.Grade do
  @moduledoc """
  Grade extraction from card/token names and mapping to comp buckets.

  Tokenized-card listings usually carry the grade in the name
  ("Charizard Base Set PSA 9"). `parse/1` pulls the grading company and
  numeric grade out; `bucket/1` maps that to the comp price bucket.

  Bucket mapping is approximate below 9: sparse sales data means most comp
  sources only publish ungraded / 9 / 9.5 / 10 prices, so mid grades fall
  back to the grade-9 bucket and callers should treat those comps as an
  upper bound.
  """

  @type parsed :: {company :: atom(), grade :: float()} | :ungraded

  @grade_pattern ~r/\b(PSA|BGS|CGC|SGC)[\s-]*(10|9(?:\.5)?|[1-8](?:\.5)?)\b/i

  @spec parse(String.t() | nil) :: parsed()
  def parse(nil), do: :ungraded

  def parse(name) when is_binary(name) do
    case Regex.run(@grade_pattern, name) do
      [_, company, grade] ->
        {company |> String.downcase() |> String.to_atom(), parse_grade(grade)}

      nil ->
        :ungraded
    end
  end

  @doc "Comp price bucket for a parsed grade (see moduledoc for caveats)."
  @spec bucket(parsed()) :: String.t()
  def bucket(:ungraded), do: "ungraded"
  def bucket({:psa, 10.0}), do: "psa_10"
  def bucket({:bgs, 10.0}), do: "bgs_10"
  def bucket({:cgc, 10.0}), do: "cgc_10"
  def bucket({:sgc, 10.0}), do: "sgc_10"
  def bucket({_company, 10.0}), do: "psa_10"
  def bucket({_company, 9.5}), do: "grade_9_5"
  def bucket({_company, _grade}), do: "grade_9"

  @doc "Parse a user/agent-supplied grade string (\"PSA 10\", \"ungraded\")."
  @spec parse_label(String.t() | nil) :: parsed()
  def parse_label(nil), do: :ungraded
  def parse_label(""), do: :ungraded

  def parse_label(label) when is_binary(label) do
    case String.downcase(String.trim(label)) do
      "ungraded" -> :ungraded
      "raw" -> :ungraded
      _ -> parse(label)
    end
  end

  defp parse_grade(grade) do
    {value, _rest} = Float.parse(grade)
    value
  end
end
