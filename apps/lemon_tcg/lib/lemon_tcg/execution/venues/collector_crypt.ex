defmodule LemonTcg.Execution.Venues.CollectorCrypt do
  @moduledoc """
  Live Collector Crypt venue: real buys and listings on Solana.

  Flow per order: `POST /marketplace/buy` (or `/list`) returns an
  unsigned base64 transaction; the configured `LemonTcg.Wallet` signs it
  locally; `POST /marketplace/broadcast` submits and returns the
  signature. CC's buy endpoint aggregates listings across its own
  marketplace, Magic Eden, and Tensor, so one venue covers all three.

  Requires `opts[:wallet]` (`{module, config}`); with the default
  `Unconfigured` wallet every order fails closed before any HTTP call.
  Fees: CC takes 2% from the seller — buyer pays the ask, so buy fills
  report `fee_usd: 0.0`; sell proceeds are reported net of the platform
  fee.
  """

  @behaviour LemonTcg.Execution.Venue

  alias LemonTcg.Execution.Fill
  alias LemonTcg.{Fx, Wallet}
  alias LemonTcg.MarketData.Listing

  @base_url "https://api.collectorcrypt.com"
  @seller_fee_bps 200

  @impl true
  def name, do: "collector_crypt"

  @impl true
  def buy(%Listing{} = listing, opts \\ []) do
    {wallet_mod, wallet_config} = Wallet.resolve(Keyword.get(opts, :wallet))

    with {:ok, buyer} <- wallet_mod.pubkey(wallet_config),
         {:ok, price_usd} <- Fx.listing_usd(listing, opts),
         {:ok, unsigned_tx} <- build_buy(listing, buyer, opts),
         {:ok, signed_tx} <- wallet_mod.sign_transaction(unsigned_tx, wallet_config),
         {:ok, signature} <- broadcast(buyer, signed_tx, listing.mint, opts) do
      {:ok,
       %Fill{
         side: :buy,
         venue: name(),
         collection: listing.collection,
         mint: listing.mint,
         name: listing.name,
         price_lamports: listing.price_lamports,
         price_usd: price_usd,
         fee_usd: 0.0,
         executed_at_ms: System.system_time(:millisecond),
         txid: signature,
         meta: %{
           card_id: get_in(listing.raw, ["id"]),
           currency: listing.currency,
           price_native: Listing.native_price(listing)
         }
       }}
    end
  end

  @impl true
  def sell(position, opts \\ []) do
    {wallet_mod, wallet_config} = Wallet.resolve(Keyword.get(opts, :wallet))
    price = Keyword.get(opts, :list_price_usd)
    card_id = position_meta(position, :card_id)

    cond do
      not is_number(price) ->
        {:error, :list_price_usd_required}

      is_nil(card_id) ->
        {:error, {:missing_cc_card_id, position.mint}}

      true ->
        with {:ok, seller} <- wallet_mod.pubkey(wallet_config),
             {:ok, unsigned_tx} <- build_list(position, card_id, seller, price, opts),
             {:ok, signed_tx} <- wallet_mod.sign_transaction(unsigned_tx, wallet_config),
             {:ok, signature} <- broadcast(seller, signed_tx, position.mint, opts) do
          fee_usd = Float.round(price * @seller_fee_bps / 10_000, 2)

          {:ok,
           %Fill{
             side: :sell,
             venue: name(),
             collection: position.collection,
             mint: position.mint,
             name: position.name,
             price_usd: Float.round(price * 1.0, 2),
             fee_usd: fee_usd,
             executed_at_ms: System.system_time(:millisecond),
             txid: signature,
             meta: %{card_id: card_id, kind: "listing_created"}
           }}
        end
    end
  end

  defp build_buy(listing, buyer, opts) do
    body =
      %{
        wallet: buyer,
        nftAddress: listing.mint,
        price: Listing.native_price(listing),
        currency: listing.currency
      }
      |> maybe_put(:tokenStandard, token_standard(listing.raw))
      |> maybe_put(:sellerWallet, listing.seller)

    post(opts, "/marketplace/buy", body, &extract_transaction/1)
  end

  defp build_list(position, card_id, seller, price, opts) do
    body = %{
      wallet: seller,
      cardId: card_id,
      nftAddress: position.mint,
      currency: Keyword.get(opts, :list_currency, "USDC"),
      price: price
    }

    post(opts, "/marketplace/list", body, &extract_transaction/1)
  end

  defp broadcast(wallet, signed_tx, mint, opts) do
    body = %{wallet: wallet, signedTransaction: signed_tx, nftAddress: mint}

    post(opts, "/marketplace/broadcast", body, fn
      %{"signature" => signature} when is_binary(signature) -> {:ok, signature}
      %{"success" => true} = response -> {:ok, Map.get(response, "message", "broadcast_ok")}
      other -> {:error, {:broadcast_failed, summarize(other)}}
    end)
  end

  # CC returns the unsigned transaction as a base64 string; be liberal
  # about the wrapping field since it is not pinned by public docs.
  defp extract_transaction(body) when is_binary(body) do
    if base64ish?(body), do: {:ok, body}, else: {:error, {:no_transaction_in_response, :binary}}
  end

  defp extract_transaction(%{} = body) do
    ~w(transaction tx serializedTransaction signedTransaction txn)
    |> Enum.find_value(fn key ->
      case Map.get(body, key) do
        value when is_binary(value) -> if base64ish?(value), do: {:ok, value}
        _ -> nil
      end
    end)
    |> case do
      nil -> {:error, {:no_transaction_in_response, Map.keys(body)}}
      ok -> ok
    end
  end

  defp extract_transaction(other), do: {:error, {:no_transaction_in_response, summarize(other)}}

  defp base64ish?(value) do
    byte_size(value) > 80 and match?({:ok, _}, Base.decode64(value))
  end

  defp token_standard(%{"nftStandard" => standard}) when is_binary(standard) do
    case String.downcase(standard) do
      "core" -> "CoreNft"
      "pnft" -> "Pnft"
      "cnft" -> "Cnft"
      _ -> "StandardNft"
    end
  end

  defp token_standard(_raw), do: nil

  defp position_meta(position, key) do
    position |> Map.get(:meta, %{}) |> Map.get(key)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp post(opts, path, body, parse) do
    req =
      [
        url: base_url(opts) <> path,
        method: :post,
        json: body,
        receive_timeout: 30_000
      ]
      |> Keyword.merge(Keyword.get(opts, :req_options, []))
      |> Req.new()

    case Req.request(req) do
      {:ok, %Req.Response{status: status, body: response}} when status in 200..299 ->
        parse.(response)

      {:ok, %Req.Response{status: status, body: response}} ->
        {:error, {:http, status, summarize(response)}}

      {:error, exception} ->
        {:error, {:transport, exception}}
    end
  end

  defp base_url(opts), do: Keyword.get(opts, :collector_crypt_base_url, @base_url)

  defp summarize(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp summarize(body) when is_map(body), do: body |> Map.keys() |> Enum.take(10)
  defp summarize(body), do: body
end
