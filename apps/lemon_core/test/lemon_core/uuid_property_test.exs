defmodule LemonCore.UUIDPropertyTest do
  @moduledoc """
  Property-based structural invariants for `LemonCore.UUID`.

  The example test pins a handful of cases; these assert the RFC 9562 bit
  layout holds for *every* generated id, not just the ones we thought to write
  down.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias LemonCore.UUID

  @canonical ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  property "uuid4 is always canonical with version 4 and the RFC 9562 variant" do
    check all(_ <- constant(nil), max_runs: 500) do
      uuid = UUID.uuid4()

      assert uuid =~ @canonical
      assert {:ok, <<_::48, version::4, _::12, variant::2, _::62>>} = UUID.decode(uuid)
      assert version == 4
      assert variant == 0b10
      assert UUID.version(uuid) == 4
    end
  end

  property "uuid7 embeds its timestamp and carries version 7 + variant, for any ms" do
    # 48 bits of unsigned millisecond space (the field width uuid7 stamps into).
    check all(ms <- integer(0..0xFFFFFFFFFFFF)) do
      uuid = UUID.uuid7(ms)

      assert uuid =~ @canonical
      assert {:ok, <<stamped::48, version::4, _::12, variant::2, _::62>>} = UUID.decode(uuid)
      assert stamped == ms
      assert version == 7
      assert variant == 0b10
    end
  end

  property "uuid7 sorts by time: a later millisecond is lexicographically greater" do
    check all(
            a <- integer(0..0xFFFFFFFFFFFE),
            delta <- integer(1..1_000_000)
          ) do
      earlier = UUID.uuid7(a)
      later = UUID.uuid7(min(a + delta, 0xFFFFFFFFFFFF))

      # Random low bits mean equal-ms ids have no defined order, so only assert
      # the strict case where the timestamps actually differ.
      if min(a + delta, 0xFFFFFFFFFFFF) > a do
        assert earlier < later
      end
    end
  end

  property "decode round-trips every generated id to 16 bytes and back" do
    check all(kind <- member_of([:v4, :v7])) do
      uuid = if kind == :v4, do: UUID.uuid4(), else: UUID.uuid7()

      assert {:ok, raw} = UUID.decode(uuid)
      assert byte_size(raw) == 16
      assert Base.encode16(raw, case: :lower) == String.replace(uuid, "-", "")
    end
  end
end
