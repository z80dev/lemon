defmodule LemonTcg.Solana.Tx do
  @moduledoc """
  Minimal Solana transaction envelope handling: enough to take an
  unsigned (or partially-signed) serialized transaction from a
  marketplace API, add our ed25519 signature in the right slot, and
  hand back the wire bytes.

  Envelope: `shortvec(num_signatures) ++ signatures(64B each) ++ message`.
  The message header's first byte (after an optional version prefix
  `0x80 | v` for versioned transactions) is `num_required_signatures`;
  the first `num_required_signatures` account keys are the signers, in
  signature-slot order. We sign the raw message bytes and place the
  signature at our key's slot, preserving any co-signatures the venue
  already applied (e.g. an auction-house authority).
  """

  import Bitwise

  alias LemonTcg.Solana.Base58

  @sig_len 64
  @key_len 32

  @doc """
  Sign the serialized transaction with a 64-byte Solana secret key
  (`seed(32) ++ pubkey(32)`, the `solana-keygen` format). Returns the
  re-serialized transaction bytes.
  """
  @spec sign(binary(), binary()) :: {:ok, binary()} | {:error, term()}
  def sign(tx_bytes, <<seed::binary-size(32), pubkey::binary-size(32)>>)
      when is_binary(tx_bytes) do
    with {:ok, sig_count, sigs, message} <- split(tx_bytes),
         {:ok, signer_index} <- signer_index(message, pubkey),
         :ok <- ensure_slot(signer_index, sig_count) do
      signature = :crypto.sign(:eddsa, :none, message, [seed, :ed25519])
      updated = List.replace_at(sigs, signer_index, signature)
      {:ok, encode_shortvec(sig_count) <> IO.iodata_to_binary(updated) <> message}
    end
  end

  def sign(_tx_bytes, _secret), do: {:error, :invalid_secret_key}

  @doc "Split an envelope into `{:ok, sig_count, [signature], message}`."
  @spec split(binary()) :: {:ok, non_neg_integer(), [binary()], binary()} | {:error, term()}
  def split(tx_bytes) do
    with {:ok, sig_count, rest} <- decode_shortvec(tx_bytes),
         sigs_size = sig_count * @sig_len,
         true <- byte_size(rest) > sigs_size || {:error, :truncated_transaction} do
      <<sigs_blob::binary-size(sigs_size), message::binary>> = rest

      sigs = for <<sig::binary-size(@sig_len) <- sigs_blob>>, do: sig
      {:ok, sig_count, sigs, message}
    end
  end

  @doc "Index of `pubkey` among the message's required signers."
  @spec signer_index(binary(), binary()) :: {:ok, non_neg_integer()} | {:error, term()}
  def signer_index(message, pubkey) when byte_size(pubkey) == @key_len do
    with {:ok, header_rest} <- strip_version(message),
         <<num_required, _ro_signed, _ro_unsigned, accounts::binary>> <- header_rest,
         {:ok, account_count, keys_blob} <- decode_shortvec(accounts),
         true <-
           (account_count >= num_required and byte_size(keys_blob) >= account_count * @key_len) ||
             {:error, :malformed_message} do
      signers =
        for <<key::binary-size(@key_len) <- binary_part(keys_blob, 0, num_required * @key_len)>>,
            do: key

      case Enum.find_index(signers, &(&1 == pubkey)) do
        nil -> {:error, {:not_a_required_signer, Base58.encode(pubkey)}}
        index -> {:ok, index}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :malformed_message}
    end
  end

  defp strip_version(<<first, rest::binary>>) when first >= 0x80, do: {:ok, rest}
  defp strip_version(message) when byte_size(message) >= 3, do: {:ok, message}
  defp strip_version(_message), do: {:error, :malformed_message}

  defp ensure_slot(index, sig_count) when index < sig_count, do: :ok
  defp ensure_slot(index, sig_count), do: {:error, {:signature_slot_missing, index, sig_count}}

  @doc "Decode a compact-u16 (shortvec) length prefix."
  @spec decode_shortvec(binary()) :: {:ok, non_neg_integer(), binary()} | {:error, term()}
  def decode_shortvec(binary), do: decode_shortvec(binary, 0, 0)

  defp decode_shortvec(<<byte, rest::binary>>, shift, acc) when shift <= 14 do
    acc = acc ||| (byte &&& 0x7F) <<< shift

    if (byte &&& 0x80) == 0 do
      {:ok, acc, rest}
    else
      decode_shortvec(rest, shift + 7, acc)
    end
  end

  defp decode_shortvec(_binary, _shift, _acc), do: {:error, :invalid_shortvec}

  @doc "Encode a compact-u16 (shortvec) length prefix."
  @spec encode_shortvec(non_neg_integer()) :: binary()
  def encode_shortvec(value) when value >= 0 and value < 0x80, do: <<value>>

  def encode_shortvec(value) when value <= 0xFFFF do
    <<(value &&& 0x7F) ||| 0x80>> <> encode_shortvec(value >>> 7)
  end
end
