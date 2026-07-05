defmodule LemonTcg.Fx do
  @moduledoc """
  USD conversion for quotes across currencies.

  Stables (USDC/USDT/USD) convert 1:1. SOL uses the resolved market
  source's FX (fixture in tests, CoinGecko-backed live). ETH/WETH/POL
  spot comes from CoinGecko's keyless simple-price endpoint, cached.
  """

  alias LemonTcg.MarketData
  alias LemonTcg.MarketData.{Cache, Floor, Listing}

  @stables ~w(USD USDC USDT)
  @coingecko_ids %{"ETH" => "ethereum", "WETH" => "ethereum", "POL" => "polygon-ecosystem-token"}
  @spot_url "https://api.coingecko.com/api/v3/simple/price"
  @spot_ttl_ms 60_000

  @doc "USD value of a listing's ask."
  @spec listing_usd(Listing.t(), keyword()) :: {:ok, float()} | {:error, term()}
  def listing_usd(%Listing{} = listing, opts \\ []) do
    case listing.price_usd do
      usd when is_number(usd) -> {:ok, round2(usd)}
      _ -> to_usd(listing.currency, Listing.native_price(listing), opts)
    end
  end

  @doc "USD value of a collection floor."
  @spec floor_usd(Floor.t(), keyword()) :: {:ok, float()} | {:error, term()}
  def floor_usd(%Floor{} = floor, opts \\ []) do
    case floor.floor_usd do
      usd when is_number(usd) -> {:ok, round2(usd)}
      _ -> to_usd(floor.currency, Floor.native_floor(floor), opts)
    end
  end

  @doc "Convert an amount of `currency` to USD."
  @spec to_usd(String.t(), number() | nil, keyword()) :: {:ok, float()} | {:error, term()}
  def to_usd(currency, amount, opts \\ [])

  def to_usd(_currency, nil, _opts), do: {:error, :missing_price}

  def to_usd(currency, amount, opts) when is_number(amount) do
    cond do
      currency in @stables ->
        {:ok, round2(amount)}

      currency == "SOL" ->
        with {:ok, fx} <- MarketData.sol_price_usd(opts), do: {:ok, round2(amount * fx)}

      Map.has_key?(@coingecko_ids, currency) ->
        with {:ok, fx} <- spot_usd(Map.fetch!(@coingecko_ids, currency), opts),
             do: {:ok, round2(amount * fx)}

      true ->
        {:error, {:unsupported_currency, currency}}
    end
  end

  @doc "Cached CoinGecko spot price in USD for a coin id."
  @spec spot_usd(String.t(), keyword()) :: {:ok, float()} | {:error, term()}
  def spot_usd(coin_id, opts \\ []) do
    Cache.get_or_run(
      {:fx_spot, coin_id},
      fn -> fetch_spot(coin_id, opts) end,
      ttl_ms: Keyword.get(opts, :fx_ttl_ms, @spot_ttl_ms),
      fresh?: Keyword.get(opts, :fresh?, false)
    )
  end

  defp fetch_spot(coin_id, opts) do
    req =
      [
        url: Keyword.get(opts, :spot_url, @spot_url),
        params: [ids: coin_id, vs_currencies: "usd"],
        receive_timeout: 15_000,
        retry: :transient,
        max_retries: 2
      ]
      |> Keyword.merge(Keyword.get(opts, :req_options, []))
      |> Req.new()

    case Req.request(req) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        case get_in(body, [coin_id, "usd"]) do
          price when is_number(price) -> {:ok, price * 1.0}
          _ -> {:error, {:unexpected_response, {:fx_spot, coin_id}}}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http, status}}

      {:error, exception} ->
        {:error, {:transport, exception}}
    end
  end

  defp round2(value), do: Float.round(value * 1.0, 2)
end
