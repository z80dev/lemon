defmodule LemonTcg.Evm.Transaction do
  @moduledoc """
  Build and sign Ethereum transactions — legacy (EIP-155) and EIP-1559
  typed (`0x02`). OpenSea fulfillment transactions are sent as EIP-1559;
  the legacy path exists to validate the signing pipeline against
  published golden vectors.

  A transaction is a plain map; unset numeric fields default to 0.
  `to`/`data` are raw binaries (20-byte address, calldata). `sign/2`
  returns `{raw_tx_hex, tx_hash_hex}` ready for `eth_sendRawTransaction`.
  """

  alias LemonTcg.Evm.{Keccak, Rlp, Secp256k1}

  @type tx :: %{optional(atom()) => term()}

  @doc "Sign an EIP-1559 transaction. Requires `:chain_id`, `:nonce`, fee fields, `:gas`."
  @spec sign_eip1559(tx(), binary()) :: {String.t(), String.t()}
  def sign_eip1559(tx, private_key) do
    fields = [
      Rlp.encode_int(fetch(tx, :chain_id)),
      Rlp.encode_int(fetch(tx, :nonce)),
      Rlp.encode_int(fetch(tx, :max_priority_fee_per_gas)),
      Rlp.encode_int(fetch(tx, :max_fee_per_gas)),
      Rlp.encode_int(fetch(tx, :gas)),
      to_bytes(tx[:to]),
      Rlp.encode_int(fetch(tx, :value)),
      to_bytes(tx[:data]),
      access_list(tx)
    ]

    sighash = Keccak.hash256(<<0x02>> <> Rlp.encode(fields))
    %{r: r, s: s, recovery_id: v} = Secp256k1.sign(sighash, private_key)

    signed = fields ++ [Rlp.encode_int(v), Rlp.encode_int(r), Rlp.encode_int(s)]
    raw = <<0x02>> <> Rlp.encode(signed)
    {"0x" <> Base.encode16(raw, case: :lower), "0x" <> Keccak.hex256(raw)}
  end

  @doc "Sign a legacy EIP-155 transaction (used for golden-vector tests)."
  @spec sign_legacy(tx(), binary()) :: {String.t(), String.t()}
  def sign_legacy(tx, private_key) do
    chain_id = fetch(tx, :chain_id)

    base = [
      Rlp.encode_int(fetch(tx, :nonce)),
      Rlp.encode_int(fetch(tx, :gas_price)),
      Rlp.encode_int(fetch(tx, :gas)),
      to_bytes(tx[:to]),
      Rlp.encode_int(fetch(tx, :value)),
      to_bytes(tx[:data])
    ]

    sighash =
      Keccak.hash256(
        Rlp.encode(base ++ [Rlp.encode_int(chain_id), Rlp.encode_int(0), Rlp.encode_int(0)])
      )

    %{r: r, s: s, recovery_id: rec} = Secp256k1.sign(sighash, private_key)
    v = rec + 35 + chain_id * 2

    signed = base ++ [Rlp.encode_int(v), Rlp.encode_int(r), Rlp.encode_int(s)]
    raw = Rlp.encode(signed)
    {"0x" <> Base.encode16(raw, case: :lower), "0x" <> Keccak.hex256(raw)}
  end

  defp access_list(tx), do: Map.get(tx, :access_list, [])

  defp fetch(tx, key), do: Map.get(tx, key, 0)

  defp to_bytes(nil), do: <<>>
  defp to_bytes(bin) when is_binary(bin), do: bin
end
