defmodule LemonTcg.MarketData.Sources.Phygitals do
  @moduledoc """
  Phygitals marketplace API source (Solana, read-only, no API key).

  `GET https://api.phygitals.com/api/marketplace/marketplace-listings`
  is the normalized union of Phygitals inventory listed across Tensor
  (~86%) and Magic Eden (~14%) — every row carries the venue that
  actually holds the listing in `raw["marketplace"]` (`"TENSOR"` /
  `"MAGICEDEN"`), which is what an execution router needs since
  Phygitals itself runs no marketplace program. Prices are micro-USDC
  strings; rows priced at $1M+ are placeholder sentinels for
  not-really-listed inventory and are dropped.

  The `collection` argument is a free-text search term ("charizard",
  a set name, ...) or `"all"`/`""` for the whole feed. CORS on the API
  only restricts browsers; server-side reads work with a browser-like
  User-Agent. Responses are edge-cached ~60s upstream, so keep the
  local cache TTL at or above that.
  """

  @behaviour LemonTcg.MarketData.Source

  alias LemonTcg.MarketData.{Floor, Listing}
  alias LemonTcg.MarketData.Sources.MagicEden

  @base_url "https://api.phygitals.com/api"
  @max_page 100
  @usdc_mint "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
  @micro_per_usdc 1_000_000
  # Observed placeholder prices for not-really-listed rows: exactly $1M,
  # $10M, and ~$1B. No real card trades near $1M, so gate on that.
  @sentinel_min_micro 1_000_000_000_000

  @impl true
  def venue, do: "phygitals"

  @impl true
  def floor(collection, opts \\ []) do
    case listings(collection, Keyword.put(opts, :limit, 25)) do
      {:ok, [cheapest | _rest]} ->
        {:ok,
         %Floor{
           collection: collection,
           venue: venue(),
           chain: :solana,
           floor: cheapest.price,
           currency: cheapest.currency,
           floor_usd: cheapest.price_usd,
           listed_count: listed_count(cheapest),
           as_of_ms: System.system_time(:millisecond)
         }}

      {:ok, []} ->
        {:error, {:no_listings, collection}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def listings(collection, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 20) |> min(@max_page)

    params = [
      searchTerm: search_term(collection),
      sortBy: "price-low-high",
      itemsPerPage: limit,
      page: 0,
      listedStatus: "listed"
    ]

    case get(opts, "/marketplace/marketplace-listings", params) do
      {:ok, %{"listings" => rows} = body} when is_list(rows) ->
        listings =
          rows
          |> Enum.map(&parse_row(collection, &1, body["amount"]))
          |> Enum.reject(&is_nil/1)
          |> Enum.sort_by(& &1.price_usd)

        {:ok, listings}

      {:ok, body} ->
        {:error, {:unexpected_response, {:marketplace_listings, summarize(body)}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def sol_price_usd(opts \\ []), do: MagicEden.sol_price_usd(opts)

  defp search_term(collection) do
    case String.downcase(collection) do
      "all" -> ""
      _ -> collection
    end
  end

  defp parse_row(collection, %{"address" => mint, "listed" => true} = row, total)
       when is_binary(mint) do
    with false <- row["burned"] == true,
         micro when is_integer(micro) and micro > 0 and micro < @sentinel_min_micro <-
           micro_price(row["price"]),
         @usdc_mint <- row["currency"] do
      usd = Float.round(micro / @micro_per_usdc, 2)

      %Listing{
        venue: venue(),
        chain: :solana,
        collection: collection,
        mint: mint,
        name: display_name(row),
        price: usd,
        currency: "USDC",
        price_usd: usd,
        seller: row["owner"],
        raw: Map.put(row, "amount", total)
      }
    else
      _skip -> nil
    end
  end

  defp parse_row(_collection, _row, _total), do: nil

  defp micro_price(price) when is_integer(price), do: price

  defp micro_price(price) when is_binary(price) do
    case Integer.parse(price) do
      {micro, ""} -> micro
      _ -> nil
    end
  end

  defp micro_price(_price), do: nil

  # On-chain names are short and often omit the grade; the Grade trait
  # row carries it ("PSA 10", "CGC 10.0", or "Ungraded").
  defp display_name(row) do
    base = row["name"]
    grade = trait(row, "Grade")

    cond do
      is_nil(base) -> nil
      grade in [nil, "", "Ungraded"] -> base
      String.contains?(base, grade) -> base
      true -> "#{base} #{grade}"
    end
  end

  defp trait(%{"metadata" => rows}, key) when is_list(rows) do
    Enum.find_value(rows, fn
      %{"key" => ^key, "value" => value} -> value
      _row -> nil
    end)
  end

  defp trait(_row, _key), do: nil

  defp listed_count(%Listing{raw: %{"amount" => total}}) when is_integer(total), do: total
  defp listed_count(_listing), do: nil

  defp get(opts, path, params) do
    req =
      [
        url: base_url(opts) <> path,
        params: params,
        # CORS on this API is browser-only; a browser-like UA keeps us
        # off Cloudflare's generic-client heuristics.
        headers: [
          {"user-agent", "Mozilla/5.0 (X11; Linux x86_64) LemonTcg/1.0"},
          {"origin", "https://phygitals.com"}
        ],
        receive_timeout: 20_000,
        retry: :transient,
        max_retries: 2
      ]
      |> Keyword.merge(Keyword.get(opts, :req_options, []))
      |> Req.new()

    case Req.request(req) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: 429}} -> {:error, :rate_limited}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http, status, summarize(body)}}
      {:error, exception} -> {:error, {:transport, exception}}
    end
  end

  defp base_url(opts), do: Keyword.get(opts, :phygitals_base_url, @base_url)

  defp summarize(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp summarize(body) when is_map(body), do: body |> Map.keys() |> Enum.take(10)
  defp summarize(body) when is_list(body), do: {:list, length(body)}
  defp summarize(body), do: body
end
