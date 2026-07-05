defmodule LemonTcg.MarketData.Sources.OpenSea do
  @moduledoc """
  OpenSea OS2 source for EVM chains (Courtyard on Polygon, Base
  collections, ...). Collections are addressed by OpenSea slug, e.g.
  `"courtyard-nft"`.

  API keys are self-provisioned: `POST /api/v2/auth/keys` returns a free
  key instantly (~30-day expiry, read 60/m). We use `OPENSEA_API_KEY` /
  `:lemon_tcg, :opensea_api_key` when set, otherwise provision one and
  cache it until expiry. EVM tokens are identified as
  `"contract:token_id"` in `Listing.mint`.
  """

  @behaviour LemonTcg.MarketData.Source

  alias LemonTcg.MarketData.Cache
  alias LemonTcg.MarketData.{Floor, Listing}
  alias LemonTcg.MarketData.Sources.MagicEden

  @base_url "https://api.opensea.io/api/v2"
  @key_ttl_ms 25 * 24 * 60 * 60 * 1000

  @impl true
  def venue, do: "opensea"

  @impl true
  def floor(slug, opts \\ []) do
    with {:ok, key} <- api_key(opts),
         {:ok, body} <- get(opts, key, "/collections/#{slug}/stats", []) do
      case body do
        %{"total" => %{"floor_price" => floor}} when is_number(floor) ->
          currency = get_in(body, ["total", "floor_price_symbol"]) || "USDC"

          {:ok,
           %Floor{
             collection: slug,
             venue: venue(),
             chain: :evm,
             floor: floor * 1.0,
             currency: normalize_currency(currency),
             floor_usd: stable_usd(currency, floor),
             listed_count: nil,
             as_of_ms: System.system_time(:millisecond)
           }}

        other ->
          {:error, {:unexpected_response, {:stats, summarize(other)}}}
      end
    end
  end

  @impl true
  def listings(slug, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 20) |> min(100)

    with {:ok, key} <- api_key(opts),
         {:ok, body} <- get(opts, key, "/listings/collection/#{slug}/all", limit: limit) do
      case body do
        %{"listings" => entries} when is_list(entries) ->
          listings =
            entries
            |> Enum.map(&parse_listing(slug, &1))
            |> Enum.reject(&is_nil/1)
            |> Enum.sort_by(&(&1.price_usd || &1.price || 0.0))

          {:ok, listings}

        other ->
          {:error, {:unexpected_response, {:listings, summarize(other)}}}
      end
    end
  end

  @impl true
  def sol_price_usd(opts \\ []), do: MagicEden.sol_price_usd(opts)

  @doc """
  Resolve the API key: explicit opt → app env → env var → self-provision
  (cached until shortly before expiry).
  """
  def api_key(opts) do
    configured =
      Keyword.get(opts, :opensea_api_key) ||
        Application.get_env(:lemon_tcg, :opensea_api_key) ||
        System.get_env("OPENSEA_API_KEY")

    case configured do
      key when is_binary(key) and key != "" ->
        {:ok, key}

      _ ->
        Cache.get_or_run({:opensea_api_key}, fn -> provision_key(opts) end,
          ttl_ms: @key_ttl_ms
        )
    end
  end

  defp provision_key(opts) do
    req =
      [
        url: base_url(opts) <> "/auth/keys",
        method: :post,
        json: %{},
        receive_timeout: 20_000
      ]
      |> Keyword.merge(Keyword.get(opts, :req_options, []))
      |> Req.new()

    case Req.request(req) do
      {:ok, %Req.Response{status: status, body: %{"api_key" => key}}}
      when status in [200, 201] and is_binary(key) ->
        {:ok, key}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:opensea_key_provision_failed, status, summarize(body)}}

      {:error, exception} ->
        {:error, {:transport, exception}}
    end
  end

  defp parse_listing(slug, %{"protocol_data" => %{"parameters" => params}} = entry) do
    offer = params |> Map.get("offer", []) |> List.first() || %{}
    contract = Map.get(offer, "token")
    token_id = Map.get(offer, "identifierOrCriteria")
    price = get_in(entry, ["price", "current"]) || %{}
    value = parse_amount(price["value"], price["decimals"])
    currency = normalize_currency(price["currency"])

    if is_binary(contract) and not is_nil(token_id) and is_number(value) do
      %Listing{
        venue: venue(),
        chain: chain_atom(entry["chain"]),
        collection: slug,
        mint: "#{contract}:#{token_id}",
        name: nil,
        price: value,
        currency: currency,
        price_usd: stable_usd(currency, value),
        seller: Map.get(params, "offerer"),
        raw: entry
      }
    end
  end

  defp parse_listing(_slug, _entry), do: nil

  defp parse_amount(value, decimals) when is_binary(value) and is_integer(decimals) do
    case Integer.parse(value) do
      {int, ""} -> int / :math.pow(10, decimals)
      _ -> nil
    end
  end

  defp parse_amount(value, decimals) when is_integer(value) and is_integer(decimals),
    do: value / :math.pow(10, decimals)

  defp parse_amount(_value, _decimals), do: nil

  defp normalize_currency(nil), do: "USDC"
  defp normalize_currency("MATIC"), do: "POL"
  defp normalize_currency(currency) when is_binary(currency), do: String.upcase(currency)

  defp stable_usd(currency, value) when is_number(value) do
    if normalize_currency(currency) in ["USDC", "USDT", "USD"],
      do: Float.round(value * 1.0, 2)
  end

  defp stable_usd(_currency, _value), do: nil

  defp chain_atom("base"), do: :base
  defp chain_atom("matic"), do: :polygon
  defp chain_atom("polygon"), do: :polygon
  defp chain_atom("ethereum"), do: :ethereum
  defp chain_atom(_chain), do: :evm

  defp get(opts, key, path, params) do
    req =
      [
        url: base_url(opts) <> path,
        params: params,
        headers: [{"x-api-key", key}],
        receive_timeout: 20_000,
        retry: :transient,
        max_retries: 2
      ]
      |> Keyword.merge(Keyword.get(opts, :req_options, []))
      |> Req.new()

    case Req.request(req) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: 429}} -> {:error, :rate_limited}
      {:ok, %Req.Response{status: 401}} -> {:error, :opensea_unauthorized}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http, status, summarize(body)}}
      {:error, exception} -> {:error, {:transport, exception}}
    end
  end

  defp base_url(opts), do: Keyword.get(opts, :opensea_base_url, @base_url)

  defp summarize(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp summarize(body) when is_map(body), do: body |> Map.keys() |> Enum.take(10)
  defp summarize(body) when is_list(body), do: {:list, length(body)}
  defp summarize(body), do: body
end
