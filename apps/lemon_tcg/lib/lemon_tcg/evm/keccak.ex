defmodule LemonTcg.Evm.Keccak do
  @moduledoc """
  Keccak-256 (Ethereum's hash — the original Keccak padding `0x01`, not
  NIST SHA3-256's `0x06`), pure Elixir.

  Only 256-bit output is implemented (rate 1088 bits / 136 bytes), which
  is all Ethereum uses.
  """

  import Bitwise

  @mask64 0xFFFFFFFFFFFFFFFF
  @rate 136

  @rot {
    0, 1, 62, 28, 27,
    36, 44, 6, 55, 20,
    3, 10, 43, 25, 39,
    41, 45, 15, 21, 8,
    18, 2, 61, 56, 14
  }

  @round_constants {
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008
  }

  @doc "Keccak-256 digest of `data` as 32 raw bytes."
  @spec hash256(binary()) :: binary()
  def hash256(data) when is_binary(data) do
    state = List.duplicate(0, 25)

    padded_data(data)
    |> absorb(state)
    |> squeeze()
  end

  @doc "Keccak-256 digest as a lowercase hex string (no 0x prefix)."
  @spec hex256(binary()) :: String.t()
  def hex256(data), do: data |> hash256() |> Base.encode16(case: :lower)

  defp padded_data(data) do
    q = @rate - rem(byte_size(data), @rate)

    pad =
      case q do
        1 -> <<0x81>>
        _ -> <<0x01>> <> :binary.copy(<<0>>, q - 2) <> <<0x80>>
      end

    data <> pad
  end

  defp absorb(<<>>, state), do: state

  defp absorb(<<block::binary-size(@rate), rest::binary>>, state) do
    lanes = for <<lane::little-unsigned-64 <- block>>, do: lane

    state =
      lanes
      |> Enum.with_index()
      |> Enum.reduce(state, fn {lane, i}, acc ->
        List.update_at(acc, i, &bxor(&1, lane))
      end)
      |> permute()

    absorb(rest, state)
  end

  defp squeeze(state) do
    state
    |> Enum.take(4)
    |> Enum.map(&<<&1::little-unsigned-64>>)
    |> IO.iodata_to_binary()
  end

  defp permute(state) do
    Enum.reduce(0..23, List.to_tuple(state), fn round, s ->
      s |> theta() |> rho_pi() |> chi() |> iota(round)
    end)
    |> Tuple.to_list()
  end

  defp at(s, x, y), do: elem(s, x + 5 * y)

  defp theta(s) do
    c = for x <- 0..4, do: bxor_all(for(y <- 0..4, do: at(s, x, y)))

    d =
      for x <- 0..4 do
        bxor(elem_list(c, rem(x + 4, 5)), rotl(elem_list(c, rem(x + 1, 5)), 1))
      end

    for_lanes(s, fn x, _y, lane -> bxor(lane, elem_list(d, x)) end)
  end

  defp rho_pi(s) do
    Enum.reduce(0..4, empty_tuple(), fn x, acc ->
      Enum.reduce(0..4, acc, fn y, acc2 ->
        idx = x + 5 * y
        target = y + 5 * rem(2 * x + 3 * y, 5)
        put_elem(acc2, target, rotl(elem(s, idx), elem(@rot, idx)))
      end)
    end)
  end

  defp chi(s) do
    for_lanes(s, fn x, y, _lane ->
      bxor(
        at(s, x, y),
        band(bxor(at(s, rem(x + 1, 5), y), @mask64), at(s, rem(x + 2, 5), y))
      )
    end)
  end

  defp iota(s, round) do
    put_elem(s, 0, bxor(elem(s, 0), elem(@round_constants, round)))
  end

  defp for_lanes(s, fun) do
    Enum.reduce(0..4, s, fn x, acc ->
      Enum.reduce(0..4, acc, fn y, acc2 ->
        idx = x + 5 * y
        put_elem(acc2, idx, fun.(x, y, elem(acc2, idx)))
      end)
    end)
  end

  defp empty_tuple, do: List.to_tuple(List.duplicate(0, 25))

  defp bxor_all(list), do: Enum.reduce(list, 0, &bxor/2)

  defp elem_list(list, i), do: Enum.at(list, i)

  defp rotl(v, 0), do: v

  defp rotl(v, n) do
    band(bor(v <<< n, v >>> (64 - n)), @mask64)
  end
end
