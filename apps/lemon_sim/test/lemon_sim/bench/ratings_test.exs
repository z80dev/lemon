defmodule LemonSim.Bench.RatingsTest do
  use ExUnit.Case, async: false

  alias LemonSim.Bench.Ratings

  test "aggregates overlapping suites into an exact pairwise matrix and ordered ratings" do
    suite_a =
      write_suite!("ratings_overlap_a", "stock_market", :maximize, [1, 2], [
        {"A", %{"1" => 10, "2" => 10}},
        {"B", %{"1" => 5, "2" => 15}},
        {"C", %{"1" => 0}}
      ])

    suite_b =
      write_suite!("ratings_overlap_b", "stock_market", :maximize, [3], [
        {"A", %{"3" => 20}},
        {"B", %{"3" => 10}},
        {"C", %{"3" => 30}}
      ])

    assert {:ok, %{ratings: ratings}} = Ratings.rate([suite_b, suite_a])

    assert ratings["pairwise"]["A"]["B"] == %{
             "wins" => 2,
             "losses" => 1,
             "draws" => 0,
             "n" => 3
           }

    assert ratings["pairwise"]["A"]["C"] == %{
             "wins" => 1,
             "losses" => 1,
             "draws" => 0,
             "n" => 2
           }

    assert ratings["pairwise"]["B"]["C"] == %{
             "wins" => 1,
             "losses" => 1,
             "draws" => 0,
             "n" => 2
           }

    rows_by_id = Map.new(ratings["competitors"], &{&1["competitor"], &1})

    assert Enum.map(ratings["competitors"], & &1["competitor"]) == ["A", "C", "B"]
    assert rows_by_id["A"]["wins"] > rows_by_id["B"]["wins"]
    assert rows_by_id["A"]["rating"] > rows_by_id["B"]["rating"]
  end

  test "minimize direction gives the lower value the win" do
    suite =
      write_suite!("ratings_minimize", "pandemic", :minimize, [1], [
        {"lower", %{"1" => 0.1}},
        {"higher", %{"1" => 0.2}}
      ])

    assert {:ok, %{ratings: ratings}} = Ratings.rate([suite])
    assert ratings["pairwise"]["lower"]["higher"]["wins"] == 1
    assert ratings["pairwise"]["higher"]["lower"]["losses"] == 1
    assert Enum.map(ratings["competitors"], & &1["competitor"]) == ["lower", "higher"]
  end

  test "unverified runs omitted from rankings are excluded" do
    suite =
      write_suite!("ratings_unverified", "stock_market", :maximize, [1, 2], [
        {"A", %{"1" => 10}},
        {"B", %{"1" => 5, "2" => 100}}
      ])

    assert {:ok, %{ratings: ratings}} = Ratings.rate([suite])
    assert ratings["pairwise"]["A"]["B"] == %{"wins" => 1, "losses" => 0, "draws" => 0, "n" => 1}
    assert ratings["pairwise"]["B"]["A"] == %{"wins" => 0, "losses" => 1, "draws" => 0, "n" => 1}
  end

  test "ratings json is byte deterministic" do
    suite_a =
      write_suite!("ratings_determinism_a", "stock_market", :maximize, [1], [
        {"A", %{"1" => 3}},
        {"B", %{"1" => 2}}
      ])

    suite_b =
      write_suite!("ratings_determinism_b", "stock_market", :maximize, [2], [
        {"A", %{"2" => 2}},
        {"B", %{"2" => 2}}
      ])

    out_a = tmp_dir("ratings_out_a")
    out_b = tmp_dir("ratings_out_b")

    assert {:ok, _result} = Ratings.write([suite_a, suite_b], out_a)
    assert {:ok, _result} = Ratings.write([suite_b, suite_a], out_b)

    assert File.read!(Path.join(out_a, "ratings.json")) ==
             File.read!(Path.join(out_b, "ratings.json"))
  end

  test "zero-comparison competitors are unrated" do
    suite =
      write_suite!("ratings_zero_comparison", "stock_market", :maximize, [1, 2], [
        {"A", %{"1" => 10}},
        {"B", %{"2" => 20}}
      ])

    assert {:ok, %{ratings: ratings}} = Ratings.rate([suite])

    assert Enum.map(ratings["competitors"], & &1["competitor"]) == ["A", "B"]
    assert Enum.all?(ratings["competitors"], &(&1["rating"] == nil))
    assert Enum.all?(ratings["competitors"], &(&1["rated"] == false))
  end

  test "transitivity sanity orders A above B above C" do
    suite =
      write_suite!("ratings_transitivity", "stock_market", :maximize, [1, 2, 3], [
        {"A", %{"1" => 3, "2" => 3, "3" => 3}},
        {"B", %{"1" => 2, "2" => 2, "3" => 2}},
        {"C", %{"1" => 1, "2" => 1, "3" => 1}}
      ])

    assert {:ok, %{ratings: ratings}} = Ratings.rate([suite])
    assert Enum.map(ratings["competitors"], & &1["competitor"]) == ["A", "B", "C"]

    [a, b, c] = ratings["competitors"]
    assert a["rating"] > b["rating"]
    assert b["rating"] > c["rating"]
  end

  defp write_suite!(prefix, scenario, direction, seeds, rankings) do
    dir = tmp_dir(prefix)

    competitors =
      Enum.map(rankings, fn {id, _values} -> %{"id" => id, "offline_strategy" => id} end)

    suite = %{
      "schema_version" => "lemon_sim.suite.v1",
      "spec" => %{
        "scenario" => scenario,
        "preset" => "fixture",
        "seeds" => seeds,
        "competitors" => competitors
      },
      "primary_metric" => %{
        "key" => ["fixture"],
        "name" => "fixture",
        "direction" => Atom.to_string(direction)
      },
      "runs" => [],
      "rankings" =>
        Enum.map(rankings, fn {id, values_by_seed} ->
          %{
            "competitor" => id,
            "values_by_seed" => values_by_seed,
            "mean" => mean(Map.values(values_by_seed)),
            "included_runs" => map_size(values_by_seed),
            "failed_runs" => length(seeds) - map_size(values_by_seed),
            "usage_totals" => %{}
          }
        end),
      "failures" => []
    }

    File.write!(Path.join(dir, "suite.json"), Jason.encode!(suite, pretty: true))
    dir
  end

  defp mean([]), do: nil
  defp mean(values), do: Enum.sum(values) / length(values)

  defp tmp_dir(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
