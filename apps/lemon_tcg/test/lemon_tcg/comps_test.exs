defmodule LemonTcg.CompsTest do
  use ExUnit.Case, async: true

  alias LemonTcg.Comps
  alias LemonTcg.Comps.Comp
  alias LemonTcg.Comps.Sources.Fixture

  defp opts, do: [comp_source: Fixture, fresh?: true]

  test "fixture comps are deterministic and grade-ordered" do
    query = "comps_deterministic_#{System.unique_integer([:positive])}"

    {:ok, comp} = Comps.comp(query, opts())
    {:ok, again} = Comps.comp(query, opts())

    assert comp.prices == again.prices
    assert comp.prices["psa_10"] > comp.prices["grade_9"]
    assert comp.prices["grade_9"] > comp.prices["ungraded"]
  end

  test "comp_for_grade parses the grade out of the query" do
    query = "comps_grade_#{System.unique_integer([:positive])} PSA 10"

    {:ok, matched} = Comps.comp_for_grade(query, nil, opts())

    assert matched.bucket == "psa_10"
    assert matched.price_usd == matched.comp.prices["psa_10"]
  end

  test "explicit grade label overrides the query" do
    query = "comps_label_#{System.unique_integer([:positive])} PSA 9"

    {:ok, matched} = Comps.comp_for_grade(query, "BGS 10", opts())
    assert matched.bucket == "bgs_10"
  end

  test "missing bucket surfaces a tagged error" do
    query = "comps_missing_#{System.unique_integer([:positive])}"

    Fixture.put_comp(query, %Comp{
      query: query,
      prices: %{"ungraded" => 10.0},
      source: "fixture",
      as_of_ms: System.system_time(:millisecond)
    })

    assert {:error, {:no_comp_for_grade, ^query, "psa_10"}} =
             Comps.comp_for_grade(query, "PSA 10", opts())
  end
end
