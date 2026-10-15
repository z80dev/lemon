defmodule LemonCore.Id do
  @moduledoc """
  ID generation utilities for Lemon.

  Provides consistent ID generation for runs, sessions, and other entities.
  UUIDs are minimal RFC 9562, vendored so the umbrella does not depend on the
  unmaintained `:uuid` package. Output is the canonical 8-4-4-12 lowercase hex
  string.

  Two UUID versions are available:

    * `uuid4/0` (also `uuid/0`) — 122 random bits. The default for identifiers
      that must not leak creation time.
    * `uuid7/0` — 48-bit millisecond timestamp followed by 74 random bits.
      Lexicographically sortable by creation time, which makes it the better
      choice for database keys. Sortable *to the millisecond*: the bits after
      the timestamp are entirely random, so UUIDs minted within the same
      millisecond have no defined order relative to each other. Do not read
      sort order as insertion order.

  ## Examples

      iex> uuid = LemonCore.Id.uuid4()
      iex> String.length(uuid)
      36
      iex> LemonCore.Id.version(uuid)
      4

      iex> LemonCore.Id.version(LemonCore.Id.uuid7())
      7
  """

  @variant 0b10

  @doc "Generates a random (version 4) UUID."
  @spec uuid4() :: String.t()
  def uuid4 do
    <<random_a::48, _::4, random_b::12, _::2, random_c::62>> = :crypto.strong_rand_bytes(16)

    encode(<<random_a::48, 4::4, random_b::12, @variant::2, random_c::62>>)
  end

  @doc """
  Generate a random UUID v4. Same as `uuid4/0`.
  """
  @spec uuid() :: binary()
  def uuid do
    uuid4()
  end

  @doc """
  Generate a time-ordered UUID v7.

  Sorts lexicographically by creation time, unlike `uuid/0`.
  """
  @spec uuid7() :: binary()
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

      iex> LemonCore.Id.version("00000000-0000-4000-8000-000000000000")
      4

      iex> LemonCore.Id.version("not-a-uuid")
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

      iex> LemonCore.Id.decode("00000000-0000-4000-8000-000000000000")
      {:ok, <<0, 0, 0, 0, 0, 0, 64, 0, 128, 0, 0, 0, 0, 0, 0, 0>>}

      iex> LemonCore.Id.decode("nope")
      :error
  """
  @spec decode(String.t()) :: {:ok, <<_::128>>} | :error
  def decode(<<a::binary-8, ?-, b::binary-4, ?-, c::binary-4, ?-, d::binary-4, ?-, e::binary-12>>) do
    Base.decode16(a <> b <> c <> d <> e, case: :mixed)
  end

  def decode(_uuid), do: :error

  @doc """
  Generate a run ID.

  Run IDs are UUID v4 with a "run_" prefix for easy identification.

  ## Examples

      iex> id = LemonCore.Id.run_id()
      iex> String.starts_with?(id, "run_")
      true

  """
  @spec run_id() :: binary()
  def run_id do
    "run_#{uuid()}"
  end

  @doc """
  Generate a session ID.

  Session IDs are UUID v4 with a "sess_" prefix for easy identification.

  ## Examples

      iex> id = LemonCore.Id.session_id()
      iex> String.starts_with?(id, "sess_")
      true

  """
  @spec session_id() :: binary()
  def session_id do
    "sess_#{uuid()}"
  end

  @doc """
  Generate an approval ID.
  """
  @spec approval_id() :: binary()
  def approval_id do
    "appr_#{uuid()}"
  end

  @doc """
  Generate a cron job ID.
  """
  @spec cron_id() :: binary()
  def cron_id do
    "cron_#{uuid()}"
  end

  @doc """
  Generate a skill ID.
  """
  @spec skill_id() :: binary()
  def skill_id do
    "skill_#{uuid()}"
  end

  @doc """
  Generate an idempotency key for a scope and operation.

  ## Examples

      iex> key = LemonCore.Id.idempotency_key("messages", "send")
      iex> String.starts_with?(key, "messages:send:")
      true

  """
  @spec idempotency_key(scope :: binary(), operation :: binary()) :: binary()
  def idempotency_key(scope, operation) do
    "#{scope}:#{operation}:#{uuid()}"
  end

  defp encode(<<raw::binary-16>>) do
    <<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>> =
      Base.encode16(raw, case: :lower)

    a <> "-" <> b <> "-" <> c <> "-" <> d <> "-" <> e
  end
end
