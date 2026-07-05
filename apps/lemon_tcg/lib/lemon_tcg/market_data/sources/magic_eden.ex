defmodule LemonTcg.MarketData.Sources.MagicEden do
  @moduledoc """
  Magic Eden v2 public API source (Solana).

  Works unauthenticated at reduced rate limits; set `MAGIC_EDEN_API_KEY`
  (or `:lemon_tcg, :magic_eden_api_key`) for a bearer token. SOL/USD comes
  from CoinGecko's keyless simple-price endpoint since Magic Eden does not
  expose FX.

  Collections are addressed by Magic Eden symbol, e.g. tokenized-card vaults
  such as Collector Crypt collections. Symbols are config, not code — pass
  them in from the desk watchlist.
  """

  @behaviour LemonTcg.MarketData.Source

  alias LemonTcg.MarketData.{Floor, Listing}

  @base_url "https://api-mainnet.magiceden.dev/v2"
  @sol_price_url "https://api.coingecko.com/api/v3/simple/price"

  @impl true
  def venue, do: "magic_eden"

  @impl true
  def floor(collection, opts \\ []) do
    case get(opts, url: "#{base_url(opts)}/collections/#{collection}/stats") do
      {:ok, %{"floorPrice" => floor_lamports} = body} when is_integer(floor_lamports) ->
        {:ok,
         %Floor{
           collection: collection,
           venue: venue(),
           chain: :solana,
           currency: "SOL",
           floor: Listing.lamports_to_sol(floor_lamports),
           floor_lamports: floor_lamports,
           floor_sol: Listing.lamports_to_sol(floor_lamports),
           listed_count: Map.get(body, "listedCount"),
           as_of_ms: System.system_time(:millisecond)
         }}

      {:ok, body} ->
        {:error, {:unexpected_response, {:stats, summarize(body)}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def listings(collection, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 20) |> min(100)

    case get(opts,
           url: "#{base_url(opts)}/collections/#{collection}/listings",
           params: [offset: 0, limit: limit]
         ) do
      {:ok, entries} when is_list(entries) ->
        {:ok,
         entries
         |> Enum.map(&parse_listing(collection, &1))
         |> Enum.reject(&is_nil/1)
         |> Enum.sort_by(& &1.price_lamports)}

      {:ok, body} ->
        {:error, {:unexpected_response, {:listings, summarize(body)}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def sol_price_usd(opts \\ []) do
    url = Keyword.get(opts, :sol_price_url, @sol_price_url)

    case get(opts, url: url, params: [ids: "solana", vs_currencies: "usd"], auth?: false) do
      {:ok, %{"solana" => %{"usd" => price}}} when is_number(price) ->
        {:ok, price * 1.0}

      {:ok, body} ->
        {:error, {:unexpected_response, {:sol_price, summarize(body)}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_listing(collection, %{"tokenMint" => mint, "price" => price} = entry)
       when is_binary(mint) and is_number(price) do
    %Listing{
      venue: venue(),
      chain: :solana,
      collection: collection,
      mint: mint,
      name: get_in(entry, ["token", "name"]),
      price: price * 1.0,
      currency: "SOL",
      price_lamports: Listing.sol_to_lamports(price),
      price_sol: price * 1.0,
      seller: Map.get(entry, "seller"),
      raw: entry
    }
  end

  defp parse_listing(_collection, _entry), do: nil

  defp get(opts, request) do
    {auth?, request} = Keyword.pop(request, :auth?, true)

    req =
      [receive_timeout: 15_000, retry: :transient, max_retries: 2]
      |> Keyword.merge(request)
      |> Keyword.merge(Keyword.get(opts, :req_options, []))
      |> maybe_auth(auth?)
      |> Req.new()

    case Req.request(req) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http, status, summarize(body)}}

      {:error, exception} ->
        {:error, {:transport, exception}}
    end
  end

  defp maybe_auth(request, false), do: request

  defp maybe_auth(request, true) do
    case api_key() do
      nil -> request
      key -> Keyword.put(request, :auth, {:bearer, key})
    end
  end

  defp api_key do
    Application.get_env(:lemon_tcg, :magic_eden_api_key) || System.get_env("MAGIC_EDEN_API_KEY")
  end

  defp base_url(opts), do: Keyword.get(opts, :base_url, @base_url)

  defp summarize(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp summarize(body) when is_map(body), do: body |> Map.keys() |> Enum.take(10)
  defp summarize(body) when is_list(body), do: {:list, length(body)}
  defp summarize(body), do: body
end
