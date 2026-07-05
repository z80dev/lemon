defmodule LemonTcg.Execution.Venues.CollectorCryptTest do
  use ExUnit.Case, async: true

  alias LemonTcg.Execution.Fill
  alias LemonTcg.Execution.Venues.CollectorCrypt, as: Venue
  alias LemonTcg.MarketData.Listing
  alias LemonTcg.Solana.Tx
  alias LemonTcg.Wallet.SolanaKeypair

  defp keypair do
    {pub, seed} = :crypto.generate_key(:eddsa, :ed25519)
    {pub, seed <> pub}
  end

  # An unsigned CC-style transaction whose only required signer is the
  # buyer wallet.
  defp unsigned_tx(buyer_pub) do
    message =
      <<1, 0, 1>> <>
        Tx.encode_shortvec(2) <>
        buyer_pub <>
        :crypto.strong_rand_bytes(32) <>
        :crypto.strong_rand_bytes(48)

    Base.encode64(Tx.encode_shortvec(1) <> :binary.copy(<<0>>, 64) <> message)
  end

  defp listing do
    %Listing{
      venue: "collector_crypt",
      chain: :solana,
      collection: "collector_crypt:Pokemon",
      mint: "MintBuy111",
      name: "Charizard PSA 9",
      price: 410.0,
      currency: "USDC",
      price_usd: 410.0,
      seller: "SellerWallet",
      raw: %{"id" => "cc-card-2", "nftStandard" => "core"}
    }
  end

  test "buy builds, signs, and broadcasts through the CC API" do
    {pub, secret} = keypair()
    unsigned = unsigned_tx(pub)
    test_pid = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)

      case conn.request_path do
        "/marketplace/buy" ->
          assert payload["nftAddress"] == "MintBuy111"
          assert payload["price"] == 410.0
          assert payload["currency"] == "USDC"
          assert payload["tokenStandard"] == "CoreNft"
          Req.Test.json(conn, %{"transaction" => unsigned})

        "/marketplace/broadcast" ->
          send(test_pid, {:broadcast, payload})
          Req.Test.json(conn, %{"success" => true, "signature" => "5ig nature123"})
      end
    end

    opts = [
      req_options: [plug: plug, retry: false],
      wallet: {SolanaKeypair, [secret_key: secret]}
    ]

    assert {:ok, %Fill{} = fill} = Venue.buy(listing(), opts)
    assert fill.side == :buy
    assert fill.venue == "collector_crypt"
    assert fill.price_usd == 410.0
    assert fill.txid == "5ig nature123"
    assert fill.meta.card_id == "cc-card-2"

    # The broadcast payload carried a genuinely signed transaction.
    assert_received {:broadcast, payload}
    signed = payload["signedTransaction"]
    refute signed == unsigned
    {:ok, tx_bytes} = Base.decode64(signed)
    {:ok, 1, [sig], message} = Tx.split(tx_bytes)
    assert :crypto.verify(:eddsa, :none, message, sig, [pub, :ed25519])
  end

  test "buy fails closed without a wallet and makes no HTTP calls" do
    plug = fn _conn -> flunk("no HTTP call expected") end
    opts = [req_options: [plug: plug, retry: false]]

    assert {:error, :wallet_not_configured} = Venue.buy(listing(), opts)
  end

  test "sell lists a held position at an explicit price" do
    {pub, secret} = keypair()
    unsigned = unsigned_tx(pub)

    position = %{
      mint: "MintBuy111",
      collection: "collector_crypt:Pokemon",
      name: "Charizard PSA 9",
      cost_basis_usd: 410.0,
      acquired_at_ms: 0,
      venue: "collector_crypt",
      meta: %{card_id: "cc-card-2", currency: "USDC"}
    }

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)

      case conn.request_path do
        "/marketplace/list" ->
          assert payload["cardId"] == "cc-card-2"
          assert payload["price"] == 450.0
          assert payload["currency"] == "USDC"
          Req.Test.json(conn, %{"tx" => unsigned})

        "/marketplace/broadcast" ->
          Req.Test.json(conn, %{"success" => true, "signature" => "listsig"})
      end
    end

    opts = [
      req_options: [plug: plug, retry: false],
      wallet: {SolanaKeypair, [secret_key: secret]},
      list_price_usd: 450.0
    ]

    assert {:ok, %Fill{side: :sell} = fill} = Venue.sell(position, opts)
    assert fill.price_usd == 450.0
    assert fill.fee_usd == 9.0
    assert fill.txid == "listsig"
  end

  test "sell requires a price and the CC card id" do
    position = %{
      mint: "M",
      collection: "c",
      name: nil,
      cost_basis_usd: 1.0,
      acquired_at_ms: 0,
      venue: "collector_crypt",
      meta: %{}
    }

    assert {:error, :list_price_usd_required} = Venue.sell(position, [])

    assert {:error, {:missing_cc_card_id, "M"}} =
             Venue.sell(position, list_price_usd: 10.0)
  end
end
