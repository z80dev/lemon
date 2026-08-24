defmodule LemonTcg.Comps.Sources.Fixture do
  @moduledoc """
  Deterministic offline comp source for tests, CI, and demos.

  Prices derive from the query string: a stable ungraded base in the
  $20-$220 band, with fixed grade multipliers on top. Override whole
  comps with `put_comp/2`; overrides live in a shared ETS table, so async
  tests should use unique query strings for isolation.
  """

  @behaviour LemonTcg.Comps.Source

  alias LemonTcg.Comps.Comp

  @table :lemon_tcg_comp_fixture_overrides

  @grade_multipliers %{
    "ungraded" => 1.0,
    "grade_9" => 2.2,
    "grade_9_5" => 3.1,
    "psa_10" => 6.5,
    "bgs_10" => 8.0,
    "cgc_10" => 5.8,
    "sgc_10" => 5.2
  }

  @impl true
  def source_name, do: "fixture"

  @impl true
  def comp(query, _opts \\ []) do
    case override(query) do
      %Comp{} = comp ->
        {:ok, comp}

      nil ->
        base = 20.0 + rem(:erlang.phash2(query), 200)

        prices =
          Enum.into(@grade_multipliers, %{}, fn {bucket, multiplier} ->
            {bucket, Float.round(base * multiplier, 2)}
          end)

        {:ok,
         %Comp{
           query: query,
           id: "fixture_#{:erlang.phash2(query)}",
           name: query,
           set: "Fixture Set",
           prices: prices,
           source: source_name(),
           as_of_ms: System.system_time(:millisecond)
         }}
    end
  end

  def put_comp(query, %Comp{} = comp) do
    _ = ensure_table()
    :ets.insert(@table, {query, comp})
    :ok
  end

  def clear_overrides do
    _ = ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  defp override(query) do
    _ = ensure_table()

    case :ets.lookup(@table, query) do
      [{^query, comp}] -> comp
      [] -> nil
    end
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          # Raced another process creating it; the table now exists.
          ArgumentError -> @table
        end

      _ ->
        @table
    end
  end
end
