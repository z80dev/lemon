defmodule LemonTcg.Evm.Rlp do
  @moduledoc """
  Recursive Length Prefix encoding (Ethereum), the subset needed to
  serialize transactions.

  Inputs are binaries (encoded as byte strings) or lists (encoded as
  RLP lists). Integers should be pre-encoded to big-endian minimal
  binaries with `encode_int/1` before being placed in the item tree.
  """

  @doc "RLP-encode a binary or a (possibly nested) list of items."
  @spec encode(binary() | list()) :: binary()
  def encode(item) when is_binary(item), do: encode_string(item)

  def encode(items) when is_list(items) do
    payload = items |> Enum.map(&encode/1) |> IO.iodata_to_binary()
    encode_length(byte_size(payload), 0xC0) <> payload
  end

  @doc "Minimal big-endian encoding of a non-negative integer (0 → empty)."
  @spec encode_int(non_neg_integer()) :: binary()
  def encode_int(0), do: <<>>

  def encode_int(n) when is_integer(n) and n > 0 do
    :binary.encode_unsigned(n)
  end

  defp encode_string(<<byte>> = bin) when byte < 0x80, do: bin

  defp encode_string(bin) do
    encode_length(byte_size(bin), 0x80) <> bin
  end

  defp encode_length(len, offset) when len < 56, do: <<offset + len>>

  defp encode_length(len, offset) do
    len_bytes = :binary.encode_unsigned(len)
    <<offset + 55 + byte_size(len_bytes)>> <> len_bytes
  end
end
