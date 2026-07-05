defmodule LemonTcg.Comps.Sources.PriceCharting do
  @moduledoc """
  PriceCharting comp source (sold-listing based, prices graded slabs).

  Requires a paid API token via `PRICECHARTING_API_TOKEN` or
  `:lemon_tcg, :pricecharting_api_token`. Prices come back in pennies;
  we normalize to USD and map PriceCharting's trading-card fields to the
  canonical grade buckets:

      loose-price        → ungraded
      graded-price       → grade_9
      box-only-price     → grade_9_5
      manual-only-price  → psa_10
      bgs-10-price       → bgs_10
      condition-17-price → cgc_10
      condition-18-price → sgc_10
  """

  @behaviour LemonTcg.Comps.Source

  alias LemonTcg.Comps.Comp

  @base_url "https://www.pricecharting.com/api/product"

  @field_buckets [
    {"loose-price", "ungraded"},
    {"graded-price", "grade_9"},
    {"box-only-price", "grade_9_5"},
    {"manual-only-price", "psa_10"},
    {"bgs-10-price", "bgs_10"},
    {"condition-17-price", "cgc_10"},
    {"condition-18-price", "sgc_10"}
  ]

  @impl true
  def source_name, do: "pricecharting"

  @impl true
  def comp(query, opts \\ []) do
    with {:ok, token} <- fetch_token(),
         {:ok, body} <- get(query, token, opts) do
      parse_product(query, body)
    end
  end

  defp parse_product(query, %{"status" => "success"} = body) do
    prices =
      Enum.reduce(@field_buckets, %{}, fn {field, bucket}, acc ->
        case Map.get(body, field) do
          pennies when is_integer(pennies) and pennies > 0 ->
            Map.put(acc, bucket, Float.round(pennies / 100, 2))

          _ ->
            acc
        end
      end)

    if prices == %{} do
      {:error, {:no_comp_prices, query}}
    else
      {:ok,
       %Comp{
         query: query,
         id: to_string(Map.get(body, "id", "")),
         name: Map.get(body, "product-name"),
         set: Map.get(body, "console-name"),
         prices: prices,
         source: source_name(),
         as_of_ms: System.system_time(:millisecond),
         raw: body
       }}
    end
  end

  defp parse_product(query, %{"status" => _} = body) do
    {:error, {:comp_not_found, query, Map.get(body, "error-message")}}
  end

  defp parse_product(query, _body), do: {:error, {:unexpected_response, {:comp, query}}}

  defp get(query, token, opts) do
    req =
      [
        url: Keyword.get(opts, :base_url, @base_url),
        params: [t: token, q: query],
        receive_timeout: 15_000,
        retry: :transient,
        max_retries: 2
      ]
      |> Keyword.merge(Keyword.get(opts, :req_options, []))
      |> Req.new()

    case Req.request(req) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %Req.Response{status: 200, body: body}} -> {:error, {:unexpected_body, body}}
      {:ok, %Req.Response{status: status}} -> {:error, {:http, status}}
      {:error, exception} -> {:error, {:transport, exception}}
    end
  end

  defp fetch_token do
    token =
      Application.get_env(:lemon_tcg, :pricecharting_api_token) ||
        System.get_env("PRICECHARTING_API_TOKEN")

    case token do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_pricecharting_api_token}
    end
  end
end
