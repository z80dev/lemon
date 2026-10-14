defmodule CodingAgent.Executor.Usage do
  @moduledoc """
  Projects completed native assistant calls to the usage ledger transport.
  The returned response cost is retained (including service-tier pricing).
  Default zero costs for uncatalogued models do not attest known pricing.
  """

  @token_keys ~w(input output cache_read cache_write total_tokens input_tokens
    output_tokens prompt_tokens completion_tokens cache_read_input_tokens
    cached_input_tokens cache_creation_input_tokens cache_write_input_tokens)a
  @transport_token_keys @token_keys ++ Enum.map(@token_keys, &Atom.to_string/1)

  def occurrence(message) when is_map(message) do
    if field(message, :role) in [:assistant, "assistant"] do
      usage =
        case field(message, :usage) do
          usage when is_map(usage) -> usage
          _ -> %{input: 0, output: 0, total_tokens: 0}
        end

      cost = field(usage, :cost)
      total = if is_map(cost), do: field(cost, :total), else: cost

      known =
        case field(usage, :price_known) do
          true ->
            is_number(total) and total >= 0

          false ->
            false

          _ ->
            is_number(total) and total >= 0 and
              (total > 0 or catalogued?(field(message, :provider), field(message, :model)))
        end

      usage = Map.take(plain(usage), @transport_token_keys)
      usage = Map.merge(usage, %{cost: if(known, do: total, else: nil), price_known: known})
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
  defp plain(%{__struct__: _} = value), do: Map.from_struct(value)
  defp plain(value), do: value
  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
