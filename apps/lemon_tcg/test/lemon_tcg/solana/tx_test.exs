defmodule LemonTcg.Solana.TxTest do
  use ExUnit.Case, async: true

  alias LemonTcg.Solana.{Base58, Tx}

  defp keypair do
    {pub, seed} = :crypto.generate_key(:eddsa, :ed25519)
    {pub, seed <> pub}
  end

  # Builds a minimal message our parser understands: header, account
  # keys, then arbitrary trailing bytes standing in for blockhash and
  # instructions.
  defp message(signer_keys, extra_keys, version \\ :legacy) do
    keys = signer_keys ++ extra_keys

    body =
      <<length(signer_keys), 0, length(extra_keys)>> <>
        Tx.encode_shortvec(length(keys)) <>
        IO.iodata_to_binary(keys) <>
        :crypto.strong_rand_bytes(40)

    case version do
      :legacy -> body
      :v0 -> <<0x80>> <> body
    end
  end

  defp envelope(sig_count, message) do
    Tx.encode_shortvec(sig_count) <>
      :binary.copy(<<0>>, sig_count * 64) <>
      message
  end

  test "signs a legacy transaction into the correct slot" do
    {pub, secret} = keypair()
    other = :crypto.strong_rand_bytes(32)
    msg = message([other, pub], [:crypto.strong_rand_bytes(32)])
    tx = envelope(2, msg)

    assert {:ok, signed} = Tx.sign(tx, secret)
    assert {:ok, 2, [first_sig, our_sig], ^msg} = Tx.split(signed)

    # Slot 0 (the other signer) is untouched; slot 1 carries a valid
    # ed25519 signature over the message bytes.
    assert first_sig == :binary.copy(<<0>>, 64)
    assert :crypto.verify(:eddsa, :none, msg, our_sig, [pub, :ed25519])
  end

  test "signs a v0 (versioned) transaction" do
    {pub, secret} = keypair()
    msg = message([pub], [:crypto.strong_rand_bytes(32)], :v0)
    tx = envelope(1, msg)

    assert {:ok, signed} = Tx.sign(tx, secret)
    assert {:ok, 1, [sig], ^msg} = Tx.split(signed)
    assert :crypto.verify(:eddsa, :none, msg, sig, [pub, :ed25519])
  end

  test "preserves existing co-signatures" do
    {pub, secret} = keypair()
    cosig = :crypto.strong_rand_bytes(64)
    msg = message([:crypto.strong_rand_bytes(32), pub], [])
    tx = Tx.encode_shortvec(2) <> cosig <> :binary.copy(<<0>>, 64) <> msg

    assert {:ok, signed} = Tx.sign(tx, secret)
    assert {:ok, 2, [^cosig, our_sig], ^msg} = Tx.split(signed)
    refute our_sig == :binary.copy(<<0>>, 64)
  end

  test "rejects a wallet that is not a required signer" do
    {_pub, secret} = keypair()
    msg = message([:crypto.strong_rand_bytes(32)], [])
    tx = envelope(1, msg)

    assert {:error, {:not_a_required_signer, _}} = Tx.sign(tx, secret)
  end

  test "rejects malformed envelopes and secrets" do
    {_pub, secret} = keypair()
    assert {:error, _} = Tx.sign(<<1>>, secret)
    assert {:error, :invalid_secret_key} = Tx.sign(<<1, 0::512>>, <<1, 2, 3>>)
  end

  test "shortvec round trip covers multi-byte lengths" do
    for value <- [0, 1, 127, 128, 300, 16_383, 16_384] do
      encoded = Tx.encode_shortvec(value)
      assert {:ok, ^value, <<>>} = Tx.decode_shortvec(encoded)
    end
  end

  test "base58 round trips solana-shaped keys" do
    key = :crypto.strong_rand_bytes(32)
    assert {:ok, ^key} = key |> Base58.encode() |> Base58.decode()

    # Leading zeros are preserved as '1's.
    padded = <<0, 0>> <> :crypto.strong_rand_bytes(5)
    encoded = Base58.encode(padded)
    assert String.starts_with?(encoded, "11")
    assert {:ok, ^padded} = Base58.decode(encoded)

    assert {:error, :invalid_base58} = Base58.decode("0OIl")
  end
end
