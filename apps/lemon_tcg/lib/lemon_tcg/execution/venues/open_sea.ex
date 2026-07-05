defmodule LemonTcg.Execution.Venues.OpenSea do
  @moduledoc """
  Live OpenSea venue for EVM chains (Courtyard on Polygon, Base
  collections). Buys fetch Seaport fulfillment data, build an EIP-1559
  transaction (nonce/fees/gas from `LemonTcg.Evm.Rpc`), sign it with the
  configured EVM wallet, and broadcast via `eth_sendRawTransaction`.

  Two hard requirements, both fail closed:

    * an EVM wallet (`{Wallet.EvmKeypair, private_key: ...}`)
    * a **trading-enabled** OpenSea API key — self-provisioned keys are
      read-only and return "Account can not perform trading operations",
      so buys need a registered developer key in `OPENSEA_API_KEY`.

  Buy only proceeds when OpenSea returns a directly broadcastable
  transaction (`to` + hex `data`); if it returns structured ABI arguments
  instead, the venue fails closed (`:opensea_fulfillment_shape_unsupported`)
  rather than sign an unverified encoding. Selling requires a
  caller-supplied, pre-hashed Seaport order (`:seaport_order`) which we
  sign via EIP-712 — the venue never constructs an order blind, since a
  malformed one could list a card far below value.
  """

  @behaviour LemonTcg.Execution.Venue

  alias LemonTcg.Execution.Fill
  alias LemonTcg.Evm.Rpc
  alias LemonTcg.MarketData.Sources.OpenSea, as: Source
  alias LemonTcg.{Fx, Wallet}
  alias LemonTcg.MarketData.Listing

  @base_url "https://api.opensea.io/api/v2"

  @impl true
  def name, do: "opensea"

  @impl true
  def buy(%Listing{} = listing, opts \\ []) do
    {wallet_mod, wallet_config} = Wallet.resolve(Keyword.get(opts, :wallet))
    chain = evm_chain(listing.chain)

    with {:ok, address} <- evm_address(wallet_mod, wallet_config),
         {:ok, price_usd} <- Fx.listing_usd(listing, opts),
         {:ok, tx_data} <- fulfillment_transaction(listing, address, opts),
         {:ok, base_tx} <- broadcastable_tx(tx_data),
         {:ok, prepared} <- Rpc.prepare_eip1559(chain, address, base_tx, opts),
         {:ok, raw} <- wallet_mod.sign_evm_transaction(prepared, wallet_config),
         {:ok, tx_hash} <- Rpc.send_raw_transaction(chain, raw, opts) do
      {:ok,
       %Fill{
         side: :buy,
         venue: name(),
         collection: listing.collection,
         mint: listing.mint,
         name: listing.name,
         price_usd: price_usd,
         fee_usd: 0.0,
         executed_at_ms: System.system_time(:millisecond),
         txid: tx_hash,
         meta: %{chain: chain, currency: listing.currency}
       }}
    end
  end

  @impl true
  def sell(position, opts \\ []) do
    {wallet_mod, wallet_config} = Wallet.resolve(Keyword.get(opts, :wallet))
    order = Keyword.get(opts, :seaport_order)
    price = Keyword.get(opts, :list_price_usd)

    cond do
      not is_map(order) or not match?(<<_::binary-size(32)>>, order[:hash]) ->
        {:error, :seaport_order_required}

      not is_number(price) ->
        {:error, :list_price_usd_required}

      true ->
        with {:ok, signature} <- wallet_mod.sign_hash(order.hash, wallet_config),
             {:ok, _body} <- post_listing(position, order, signature, opts) do
          {:ok,
           %Fill{
             side: :sell,
             venue: name(),
             collection: position.collection,
             mint: position.mint,
             name: position.name,
             price_usd: Float.round(price * 1.0, 2),
             fee_usd: 0.0,
             executed_at_ms: System.system_time(:millisecond),
             txid: signature,
             meta: %{kind: "listing_created", chain: position_chain(position)}
           }}
        end
    end
  end

  defp fulfillment_transaction(listing, fulfiller, opts) do
    body = %{
      listing: %{
        hash: get_in(listing.raw, ["order_hash"]),
        chain: to_string(listing.raw["chain"] || "polygon"),
        protocol_address: get_in(listing.raw, ["protocol_address"])
      },
      fulfiller: %{address: fulfiller}
    }

    with {:ok, key} <- Source.api_key(opts),
         {:ok, response} <- post(opts, key, "/listings/fulfillment_data", body) do
      case get_in(response, ["fulfillment_data", "transaction"]) do
        %{} = tx -> {:ok, tx}
        _ -> {:error, {:no_fulfillment_transaction, Map.keys(response)}}
      end
    end
  end

  # Only proceed when OpenSea handed us ready calldata. Structured
  # input_data (ABI args) is refused rather than encoded speculatively.
  defp broadcastable_tx(%{"to" => to} = tx) when is_binary(to) do
    case raw_calldata(tx) do
      {:ok, data} ->
        {:ok, %{to: decode_address(to), data: data, value: tx_value(tx["value"])}}

      :error ->
        {:error, {:opensea_fulfillment_shape_unsupported, Map.keys(tx)}}
    end
  end

  defp broadcastable_tx(tx), do: {:error, {:no_fulfillment_transaction, safe_keys(tx)}}

  defp raw_calldata(%{"data" => "0x" <> _ = data}), do: decode_hex(data)
  defp raw_calldata(%{"input_data" => data}) when is_binary(data), do: decode_hex(data)
  defp raw_calldata(_tx), do: :error

  defp decode_hex("0x" <> hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> :error
    end
  end

  defp decode_address("0x" <> hex), do: Base.decode16!(hex, case: :mixed)
  defp decode_address(bin) when is_binary(bin), do: bin

  defp tx_value(nil), do: 0
  defp tx_value(value) when is_integer(value), do: value
  defp tx_value("0x" <> hex), do: String.to_integer(hex, 16)
  defp tx_value(value) when is_binary(value), do: String.to_integer(value)

  defp post_listing(_position, order, signature, opts) do
    chain = to_string(order[:chain] || "polygon")
    body = %{parameters: order.parameters, signature: signature, protocol_address: order[:protocol_address]}

    with {:ok, key} <- Source.api_key(opts) do
      post(opts, key, "/orders/#{chain}/seaport/listings", body)
    end
  end

  defp evm_address(wallet_mod, wallet_config) do
    if Code.ensure_loaded?(wallet_mod) and function_exported?(wallet_mod, :address, 1) do
      wallet_mod.address(wallet_config)
    else
      {:error, :evm_wallet_required}
    end
  end

  defp evm_chain(:polygon), do: :polygon
  defp evm_chain(:base), do: :base
  defp evm_chain(:ethereum), do: :ethereum
  defp evm_chain(_other), do: :polygon

  defp position_chain(position), do: position |> Map.get(:meta, %{}) |> Map.get(:chain, :polygon)

  defp post(opts, key, path, body) do
    req =
      [
        url: base_url(opts) <> path,
        method: :post,
        json: body,
        headers: [{"x-api-key", key}],
        receive_timeout: 20_000
      ]
      |> Keyword.merge(Keyword.get(opts, :req_options, []))
      |> Req.new()

    case Req.request(req) do
      {:ok, %Req.Response{status: status, body: response}} when status in 200..299 ->
        {:ok, response}

      {:ok, %Req.Response{status: status, body: response}} ->
        {:error, {:http, status, safe_keys(response)}}

      {:error, exception} ->
        {:error, {:transport, exception}}
    end
  end

  defp base_url(opts), do: Keyword.get(opts, :opensea_base_url, @base_url)

  defp safe_keys(map) when is_map(map), do: Map.keys(map)
  defp safe_keys(other), do: other
end
