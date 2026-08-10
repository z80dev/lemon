defmodule LemonCore.UUID do
  @moduledoc """
  Minimal RFC 9562 UUID generation.

  Vendored so the umbrella does not depend on the unmaintained `:uuid` package.
  Output is the canonical 8-4-4-12 lowercase hex string, byte-compatible with
  what `UUID.uuid4/0` produced.

  Two versions are available:

    * `uuid4/0` — 122 random bits. The default for identifiers that must not
      leak creation time.
    * `uuid7/0` — 48-bit millisecond timestamp followed by 74 random bits.
      Lexicographically sortable by creation time, which makes it the better
      choice for database keys.

  ## Examples

      iex> uuid = LemonCore.UUID.uuid4()
      iex> String.length(uuid)
      36
      iex> LemonCore.UUID.version(uuid)
      4

      iex> LemonCore.UUID.version(LemonCore.UUID.uuid7())
      7
  """

  @variant 0b10

  @doc "Generates a random (version 4) UUID."
  @spec uuid4() :: String.t()
  def uuid4 do
    <<random_a::48, _::4, random_b::12, _::2, random_c::62>> = :crypto.strong_rand_bytes(16)

    encode(<<random_a::48, 4::4, random_b::12, @variant::2, random_c::62>>)
  end

  @doc "Generates a time-ordered (version 7) UUID from the current time."
  @spec uuid7() :: String.t()
  def uuid7, do: uuid7(System.system_time(:millisecond))

  @doc "Generates a version 7 UUID stamped with `unix_ms`."
  @spec uuid7(integer()) :: String.t()
  def uuid7(unix_ms) when is_integer(unix_ms) and unix_ms >= 0 do
    <<_::48, _::4, random_a::12, _::2, random_b::62>> = :crypto.strong_rand_bytes(16)

    encode(<<unix_ms::48, 7::4, random_a::12, @variant::2, random_b::62>>)
  end

  @doc """
  Returns the version digit of a canonical UUID string, or `nil` if it is not one.

  ## Examples

      iex> LemonCore.UUID.version("00000000-0000-4000-8000-000000000000")
      4

      iex> LemonCore.UUID.version("not-a-uuid")
      nil
  """
  @spec version(String.t()) :: pos_integer() | nil
  def version(uuid) when is_binary(uuid) do
    case decode(uuid) do
      {:ok, <<_::48, version::4, _::76>>} -> version
      :error -> nil
    end
  end

  def version(_uuid), do: nil

  @doc """
  Returns the 16 raw bytes of a canonical UUID string.

  ## Examples

      iex> LemonCore.UUID.decode("00000000-0000-4000-8000-000000000000")
      {:ok, <<0, 0, 0, 0, 0, 0, 64, 0, 128, 0, 0, 0, 0, 0, 0, 0>>}

      iex> LemonCore.UUID.decode("nope")
      :error
  """
  @spec decode(String.t()) :: {:ok, <<_::128>>} | :error
  def decode(<<a::binary-8, ?-, b::binary-4, ?-, c::binary-4, ?-, d::binary-4, ?-, e::binary-12>>) do
    Base.decode16(a <> b <> c <> d <> e, case: :mixed)
  end

  def decode(_uuid), do: :error

  defp encode(<<raw::binary-16>>) do
    <<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>> =
      Base.encode16(raw, case: :lower)

    a <> "-" <> b <> "-" <> c <> "-" <> d <> "-" <> e
  end
end
