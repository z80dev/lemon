defmodule CodingAgent.Executor.Usage do
  @moduledoc """
  Projects completed native assistant calls to the usage ledger transport.
  The returned response cost is retained (including service-tier pricing).
  Default zero costs for uncatalogued models do not attest known pricing.
  """

  @token_keys ~w(input output cache_read cache_write cache_write_long total_tokens input_tokens
    output_tokens prompt_tokens completion_tokens cache_read_input_tokens
    cached_input_tokens cache_creation_input_tokens cache_write_input_tokens)a
  @cost_keys [:input, :output, :cache_read, :cache_write, :total]

  def occurrence(message) when is_map(message) do
    if field(message, :role) in [:assistant, "assistant"] and
         field(field(message, :error_details) || %{}, :provider_invoked) != false do
      usage =
        case field(message, :usage) do
          usage when is_map(usage) -> usage
          _ -> %{}
        end

      cost = field(usage, :cost)
      total = if is_map(cost), do: field(cost, :total), else: cost

      counters_known =
        Enum.all?([:input, :output, :total_tokens], &is_number(field(usage, &1)))

      known =
        counters_known and
          case field(usage, :price_known) do
            true ->
              is_number(total) and total >= 0

            false ->
              false

            _ ->
              is_number(total) and total >= 0 and
                (total > 0 or catalogued?(field(message, :provider), field(message, :model)))
          end

      usage =
        Enum.reduce(@token_keys, %{}, fn key, counters ->
          if Map.has_key?(usage, key) or Map.has_key?(usage, Atom.to_string(key)),
            do: Map.put(counters, key, field(usage, key)),
            else: counters
        end)
        |> then(fn counters ->
          Map.merge(
            Map.new([:input, :output, :cache_read, :cache_write, :total_tokens], &{&1, nil}),
            counters
          )
        end)

      projected_cost =
        if is_map(cost) do
          Map.new(@cost_keys, &{&1, field(cost, &1)})
          |> Map.put(:total, if(known, do: total))
        else
          if known, do: %{total: total}
        end

      usage = Map.merge(usage, %{cost: projected_cost, price_known: known})
      at = field(message, :timestamp)

      %{
        model: field(message, :model),
        provider: field(message, :provider),
        at_ms: if(is_integer(at) and at > 0, do: at, else: System.system_time(:millisecond)),
        usage: usage
      }
    end
  end

  def occurrence(_), do: nil

  defp catalogued?(provider, model) when is_binary(model) do
    provider = if is_binary(provider), do: String.to_existing_atom(provider), else: provider
    is_atom(provider) and not is_nil(LemonAi.Models.get_model(provider, model))
  rescue
    ArgumentError -> false
  end

  defp catalogued?(_, _), do: false
  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
