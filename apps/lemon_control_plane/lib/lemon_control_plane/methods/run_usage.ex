defmodule LemonControlPlane.Methods.RunUsage do
  @moduledoc "Bounded usage joins shared by run history and timeline projections."

  def attach(runs) do
    known = Enum.filter(runs, &is_integer(&1["startedAtMs"]))

    with {:ok, grouped} <- fetch_usage(known) do
      {:ok,
       Enum.map(runs, fn run ->
         records =
           if is_integer(run["startedAtMs"]),
             do: Map.get(grouped, run["runId"], []),
             else: []

         Map.merge(run, usage_fields(records))
       end)}
    end
  end

  defp fetch_usage([]), do: {:ok, %{}}

  defp fetch_usage(runs) do
    timestamps =
      Enum.flat_map(runs, &[&1["startedAtMs"], &1["completedAtMs"]])
      |> Enum.filter(&is_integer/1)

    with {:ok, page} <-
           LemonCore.UsageRecords.query(%{
             "fromMs" => max(Enum.min(timestamps), 0),
             "toMs" => Enum.max(timestamps) + 1,
             "limit" => 500
           }) do
      {:ok,
       if(is_nil(page.next_cursor),
         do: Enum.group_by(page.records, & &1.run_id),
         else: %{}
       )}
    end
  end

  defp usage_fields([]) do
    Map.new(["tokens", "costUsd", "priceKnown", "model", "provider"], &{&1, nil})
  end

  defp usage_fields(records) do
    priced? = Enum.all?(records, &(&1.price_known and is_number(&1.cost_usd)))

    %{
      "tokens" => %{
        "input" => sum_known(records, :input_tokens),
        "output" => sum_known(records, :output_tokens),
        "total" => sum_known(records, :total_tokens)
      },
      "costUsd" => if(priced?, do: Enum.sum(Enum.map(records, & &1.cost_usd)), else: nil),
      "priceKnown" => priced?,
      "model" => single_value(records, :model),
      "provider" => single_value(records, :provider)
    }
  end

  defp sum_known(records, key) do
    values = Enum.map(records, &Map.get(&1, key))
    if Enum.all?(values, &is_integer/1), do: Enum.sum(values), else: nil
  end

  defp single_value(records, key) do
    case records |> Enum.map(&Map.get(&1, key)) |> Enum.uniq() do
      [value] -> value
      _ -> nil
    end
  end
end
