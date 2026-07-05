defmodule LemonTcg.Evm.Secp256k1 do
  @moduledoc """
  secp256k1 for Ethereum: deterministic ECDSA (RFC 6979) with recovery id,
  public-key derivation, and address derivation. Pure Elixir — we compute
  the nonce `k` ourselves so the recovery id falls out directly.

  Signatures are low-s normalized (EIP-2). `sign/2` takes the 32-byte
  message digest (Ethereum signs the keccak256 hash directly).
  """

  import Bitwise

  alias LemonTcg.Evm.Keccak

  # Field prime, curve order, generator.
  @p 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
  @n 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
  @gx 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
  @gy 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8
  @half_n div(@n, 2)

  @type signature :: %{r: non_neg_integer(), s: non_neg_integer(), recovery_id: 0 | 1}

  @doc "Public key point `{x, y}` for a 32-byte private key."
  @spec public_key(binary()) :: {non_neg_integer(), non_neg_integer()}
  def public_key(<<d::256>>) when d > 0 and d < @n, do: mul({@gx, @gy}, d)

  @doc "65-byte uncompressed public key (`0x04 || X || Y`)."
  @spec public_key_bytes(binary()) :: binary()
  def public_key_bytes(private_key) do
    {x, y} = public_key(private_key)
    <<0x04, x::256, y::256>>
  end

  @doc "20-byte Ethereum address for a private key."
  @spec address(binary()) :: binary()
  def address(private_key) do
    {x, y} = public_key(private_key)
    <<_::binary-size(12), addr::binary-size(20)>> = Keccak.hash256(<<x::256, y::256>>)
    addr
  end

  @doc "EIP-55 checksummed hex address (with `0x` prefix)."
  @spec address_hex(binary()) :: String.t()
  def address_hex(private_key) do
    private_key |> address() |> checksum_address()
  end

  @doc "Deterministic ECDSA signature over a 32-byte digest."
  @spec sign(binary(), binary()) :: signature()
  def sign(<<z::256>>, <<d::256>>) when d > 0 and d < @n do
    do_sign(z, d, rfc6979_k(z, d))
  end

  @doc "EIP-55 checksum encoding of a 20-byte address."
  @spec checksum_address(binary()) :: String.t()
  def checksum_address(<<_::binary-size(20)>> = addr) do
    hex = Base.encode16(addr, case: :lower)
    hash = Keccak.hex256(hex)

    checksummed =
      hex
      |> String.to_charlist()
      |> Enum.zip(String.to_charlist(hash))
      |> Enum.map(fn {c, h} ->
        cond do
          c in ?0..?9 -> c
          h in ?8..?9 or h in ?a..?f -> c - 32
          true -> c
        end
      end)
      |> List.to_string()

    "0x" <> checksummed
  end

  defp do_sign(z, d, k) do
    {rx, ry} = mul({@gx, @gy}, k)
    r = rem(rx, @n)

    if r == 0 do
      do_sign(z, d, k + 1)
    else
      s = mod_mul(inverse(k, @n), z + r * d, @n)

      if s == 0 do
        do_sign(z, d, k + 1)
      else
        parity = band(ry, 1)
        overflow = if rx >= @n, do: 2, else: 0
        recovery_id = bxor(parity, 0) ||| overflow

        if s > @half_n do
          %{r: r, s: @n - s, recovery_id: bxor(recovery_id, 1)}
        else
          %{r: r, s: s, recovery_id: recovery_id}
        end
      end
    end
  end

  # RFC 6979 deterministic nonce with HMAC-SHA256.
  defp rfc6979_k(z, d) do
    x = <<d::256>>
    h1 = <<z::256>>
    v = :binary.copy(<<0x01>>, 32)
    kk = :binary.copy(<<0x00>>, 32)

    kk = hmac(kk, v <> <<0x00>> <> x <> h1)
    v = hmac(kk, v)
    kk = hmac(kk, v <> <<0x01>> <> x <> h1)
    v = hmac(kk, v)

    generate_k(kk, v)
  end

  defp generate_k(kk, v) do
    v = hmac(kk, v)
    <<candidate::256>> = v

    if candidate >= 1 and candidate < @n do
      candidate
    else
      kk2 = hmac(kk, v <> <<0x00>>)
      v2 = hmac(kk2, v)
      generate_k(kk2, v2)
    end
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)

  # -- Curve arithmetic (affine, Jacobian would be faster but this is
  #    called a handful of times per signature) --

  defp mul(_point, 0), do: :infinity
  defp mul(point, 1), do: point

  defp mul(point, k) do
    mul(point, k, :infinity)
  end

  defp mul(_point, 0, acc), do: acc

  defp mul(point, k, acc) do
    acc = if band(k, 1) == 1, do: add(acc, point), else: acc
    mul(double(point), k >>> 1, acc)
  end

  defp add(:infinity, point), do: point
  defp add(point, :infinity), do: point

  defp add({x1, y1}, {x2, y2}) do
    cond do
      x1 == x2 and rem(y1 + y2, @p) == 0 -> :infinity
      x1 == x2 and y1 == y2 -> double({x1, y1})
      true -> add_distinct({x1, y1}, {x2, y2})
    end
  end

  defp add_distinct({x1, y1}, {x2, y2}) do
    slope = mod_mul(y2 - y1, inverse(mod(x2 - x1, @p), @p), @p)
    x3 = mod(slope * slope - x1 - x2, @p)
    y3 = mod(slope * (x1 - x3) - y1, @p)
    {x3, y3}
  end

  defp double(:infinity), do: :infinity

  defp double({x, y}) do
    slope = mod_mul(3 * x * x, inverse(mod(2 * y, @p), @p), @p)
    x3 = mod(slope * slope - 2 * x, @p)
    y3 = mod(slope * (x - x3) - y, @p)
    {x3, y3}
  end

  defp mod(a, m), do: Integer.mod(a, m)

  defp mod_mul(a, b, m), do: Integer.mod(a * b, m)

  # Modular inverse via Fermat's little theorem (p, n are prime).
  defp inverse(a, m), do: pow_mod(Integer.mod(a, m), m - 2, m)

  defp pow_mod(_base, 0, _m), do: 1

  defp pow_mod(base, exp, m) do
    half = pow_mod(base, div(exp, 2), m)
    half2 = mod_mul(half, half, m)
    if band(exp, 1) == 1, do: mod_mul(half2, base, m), else: half2
  end
end
