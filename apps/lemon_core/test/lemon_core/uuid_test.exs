defmodule LemonCore.UUIDTest do
  use ExUnit.Case, async: true

  alias LemonCore.UUID

  doctest LemonCore.UUID

  @canonical ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  describe "uuid4/0" do
    test "is canonical lowercase 8-4-4-12" do
      assert UUID.uuid4() =~ @canonical
    end

    test "sets the version and RFC 9562 variant bits" do
      assert {:ok, <<_::48, version::4, _::12, variant::2, _::62>>} = UUID.decode(UUID.uuid4())
      assert version == 4
      assert variant == 0b10
    end

    test "does not repeat" do
      generated = Enum.map(1..1_000, fn _ -> UUID.uuid4() end)
      assert generated |> Enum.uniq() |> length() == 1_000
    end
  end

  describe "uuid7/0" do
    test "sets the version and variant bits" do
      assert {:ok, <<_::48, version::4, _::12, variant::2, _::62>>} = UUID.decode(UUID.uuid7())
      assert version == 7
      assert variant == 0b10
    end

    test "embeds the millisecond timestamp" do
      before_ms = System.system_time(:millisecond)
      {:ok, <<stamped::48, _::80>>} = UUID.decode(UUID.uuid7())
      after_ms = System.system_time(:millisecond)

      assert stamped >= before_ms
      assert stamped <= after_ms
    end

    test "sorts lexicographically by time" do
      earlier = UUID.uuid7(1_700_000_000_000)
      later = UUID.uuid7(1_700_000_000_001)

      assert earlier < later
    end

    test "does not repeat within a millisecond" do
      generated = Enum.map(1..1_000, fn _ -> UUID.uuid7(1_700_000_000_000) end)
      assert generated |> Enum.uniq() |> length() == 1_000
    end
  end

  describe "decode/1" do
    test "round-trips the generated string" do
      uuid = UUID.uuid4()
      {:ok, raw} = UUID.decode(uuid)

      assert byte_size(raw) == 16
      assert raw |> Base.encode16(case: :lower) |> String.length() == 32
    end

    test "rejects malformed input" do
      assert UUID.decode("") == :error
      assert UUID.decode("xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx") == :error
      assert UUID.decode(String.replace(UUID.uuid4(), "-", "")) == :error
    end
  end

  describe "version/1" do
    test "returns nil for non-UUIDs" do
      assert UUID.version("nope") == nil
      assert UUID.version(nil) == nil
    end
  end

  describe "LemonCore.Id integration" do
    test "uuid/0 stays version 4 and prefixed ids embed it" do
      assert UUID.version(LemonCore.Id.uuid()) == 4
      assert UUID.version(LemonCore.Id.uuid7()) == 7

      "run_" <> uuid = LemonCore.Id.run_id()
      assert UUID.version(uuid) == 4
    end
  end
end
