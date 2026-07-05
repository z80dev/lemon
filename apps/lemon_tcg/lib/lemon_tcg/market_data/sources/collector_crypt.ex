defmodule LemonTcg.MarketData.Sources.CollectorCrypt do
  @moduledoc """
  Collector Crypt native marketplace API source (Solana, no API key).

  `GET https://api.collectorcrypt.com/marketplace` pages through ~90k+
  vaulted graded cards. The `collection` argument is a category filter
  ("Pokemon", "One Piece", ...) or `"all"` for the whole marketplace;
  anything else is sent as `categories`. Listings are mostly USDC with
  some SOL; each carries the vault card's grading metadata in `raw`
  (including the CC card `id` needed to list it for sale later).

  Reads are server-cached ~60s; keep the local cache TTL at or above
  that. Floors are derived from the cheapest live listing
  (`orderBy=listedPriceAsc`) rather than a stats endpoint.
  """

  @behaviour LemonTcg.MarketData.Source

  alias LemonTcg.MarketData.{Floor, Listing}
  alias LemonTcg.MarketData.Sources.MagicEden

  @base_url "https://api.collectorcrypt.com"
  @max_step 100

  @impl true
  def venue, do: "collector_crypt"

  @impl true
  def floor(collection, opts \\ []) do
    case listings(collection, Keyword.put(opts, :limit, 25)) do
      {:ok, [cheapest | _] = page} ->
        {:ok,
         %Floor{
           collection: collection,
           venue: venue(),
           chain: :solana,
           floor: cheapest.price,
           currency: cheapest.currency,
           floor_usd: cheapest.price_usd,
           floor_lamports: cheapest.price_lamports,
           floor_sol: cheapest.price_sol,
           listed_count: listed_count(page),
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
    limit = opts |> Keyword.get(:limit, 20) |> min(@max_step)

    params =
      [page: 1, step: limit, orderBy: "listedPriceAsc"] ++ category_params(collection)

    case get(opts, "/marketplace", params) do
      {:ok, %{"filterNFtCard" => cards} = body} when is_list(cards) ->
        # findTotal is only correct for the unfiltered marketplace; CC does
        # not recompute it per category filter, so drop it when filtering.
        total = if category_params(collection) == [], do: body["findTotal"]

        listings =
          cards
          |> Enum.map(&parse_card(collection, &1, total))
          |> Enum.reject(&is_nil/1)
          |> Enum.sort_by(&(&1.price_usd || &1.price || 0.0))

        {:ok, listings}

      {:ok, body} ->
        {:error, {:unexpected_response, {:marketplace, summarize(body)}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def sol_price_usd(opts \\ []), do: MagicEden.sol_price_usd(opts)

  defp category_params(collection) do
    case String.downcase(collection) do
      "all" -> []
      "" -> []
      _ -> [categories: collection]
    end
  end

  defp parse_card(collection, %{"nftAddress" => mint, "listing" => %{} = listing} = card, total)
       when is_binary(mint) do
    price = listing["price"]
    currency = listing["currency"]

    if is_number(price) and is_binary(currency) do
      %Listing{
        venue: venue(),
        chain: :solana,
        collection: collection,
        mint: mint,
        name: card_name(card),
        price: price * 1.0,
        currency: currency,
        price_usd: if(currency in ["USDC", "USDT", "USD"], do: Float.round(price * 1.0, 2)),
        price_lamports: if(currency == "SOL", do: Listing.sol_to_lamports(price)),
        price_sol: if(currency == "SOL", do: price * 1.0),
        seller: get_in(card, ["owner", "wallet"]),
        raw: Map.put(card, "findTotal", total)
      }
    end
  end

  defp parse_card(_collection, _card, _total), do: nil

  defp card_name(card) do
    base = card["itemName"]
    grade = grade_label(card)

    cond do
      is_nil(base) -> nil
      grade == nil -> base
      String.contains?(base, grade) -> base
      true -> "#{base} #{grade}"
    end
  end

  defp grade_label(%{"gradingCompany" => company, "grade" => grade})
       when is_binary(company) and not is_nil(grade),
       do: "#{company} #{grade}"

  defp grade_label(_card), do: nil

  defp listed_count([%Listing{raw: %{"findTotal" => total}} | _]) when is_integer(total),
    do: total

  defp listed_count(_page), do: nil

  defp get(opts, path, params) do
    req =
      [
        url: base_url(opts) <> path,
        params: params,
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

  defp base_url(opts) do
    Keyword.get(opts, :collector_crypt_base_url, @base_url)
  end

  defp summarize(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp summarize(body) when is_map(body), do: body |> Map.keys() |> Enum.take(10)
  defp summarize(body) when is_list(body), do: {:list, length(body)}
  defp summarize(body), do: body
end
