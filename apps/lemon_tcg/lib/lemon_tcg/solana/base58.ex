defmodule LemonTcg.Solana.Base58 do
  @moduledoc """
  Bitcoin-alphabet Base58 for Solana pubkeys, signatures, and secrets.
  """

  @alphabet ~c"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
  @index @alphabet |> Enum.with_index() |> Map.new()

  @spec encode(binary()) :: String.t()
  def encode(binary) when is_binary(binary) do
    zeros = count_leading_zeros(binary, 0)

    digits =
      binary
      |> :binary.decode_unsigned()
      |> to_digits([])

    String.duplicate("1", zeros) <> List.to_string(digits)
  end

  @spec decode(String.t()) :: {:ok, binary()} | {:error, :invalid_base58}
  def decode(string) when is_binary(string) do
    chars = String.to_charlist(string)

    if Enum.all?(chars, &Map.has_key?(@index, &1)) do
      ones = Enum.take_while(chars, &(&1 == ?1)) |> length()

      value =
        Enum.reduce(chars, 0, fn char, acc -> acc * 58 + Map.fetch!(@index, char) end)

      body = if value == 0, do: <<>>, else: :binary.encode_unsigned(value)
      {:ok, :binary.copy(<<0>>, ones) <> body}
    else
      {:error, :invalid_base58}
    end
  end

  defp to_digits(0, []), do: []
  defp to_digits(0, acc), do: acc

  defp to_digits(value, acc) do
    to_digits(div(value, 58), [Enum.at(@alphabet, rem(value, 58)) | acc])
  end

  defp count_leading_zeros(<<0, rest::binary>>, count), do: count_leading_zeros(rest, count + 1)
  defp count_leading_zeros(_binary, count), do: count
end
