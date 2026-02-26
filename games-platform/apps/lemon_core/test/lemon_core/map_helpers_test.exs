defmodule LemonCore.MapHelpersTest do
  use ExUnit.Case, async: true

  alias LemonCore.MapHelpers

  describe "get_key/2 with atom keys" do
    test "returns value when map has atom key" do
      assert MapHelpers.get_key(%{name: "Alice"}, :name) == "Alice"
    end

    test "returns value when map has string key and atom is given" do
      assert MapHelpers.get_key(%{"name" => "Alice"}, :name) == "Alice"
    end

    test "prefers atom key over string key" do
      assert MapHelpers.get_key(%{"name" => "string", name: "atom"}, :name) == "atom"
    end

    test "falls back to string key when atom key is nil" do
      assert MapHelpers.get_key(%{"name" => "string", name: nil}, :name) == "string"
    end

    test "returns nil when neither atom nor string key exists" do
      assert MapHelpers.get_key(%{other: "value"}, :name) == nil
    end

    test "returns nil for empty map" do
      assert MapHelpers.get_key(%{}, :name) == nil
    end

    test "returns integer values" do
      assert MapHelpers.get_key(%{"count" => 42}, :count) == 42
    end

    test "returns boolean values" do
      assert MapHelpers.get_key(%{"active" => true}, :active) == true
    end

    test "returns list values" do
      assert MapHelpers.get_key(%{"tags" => ["a", "b"]}, :tags) == ["a", "b"]
    end

    test "returns map values" do
      nested = %{inner: 1}
      assert MapHelpers.get_key(%{"data" => nested}, :data) == nested
    end

    test "returns false correctly (not treated as missing)" do
      assert MapHelpers.get_key(%{"enabled" => "fallback", enabled: false}, :enabled) == "fallback"
    end

    test "handles multi-word atom keys" do
      assert MapHelpers.get_key(%{"first_name" => "Bob"}, :first_name) == "Bob"
    end
  end

  describe "get_key/2 with string keys" do
    test "returns value when map has string key" do
      assert MapHelpers.get_key(%{"name" => "Alice"}, "name") == "Alice"
    end

    test "returns value when map has atom key and string is given" do
      # :name atom already exists from other tests
      assert MapHelpers.get_key(%{name: "Alice"}, "name") == "Alice"
    end

    test "prefers string key over atom key" do
      assert MapHelpers.get_key(%{"name" => "string", name: "atom"}, "name") == "string"
    end

    test "falls back to atom key when string key is nil" do
      map = Map.put(%{name: "atom"}, "name", nil)
      assert MapHelpers.get_key(map, "name") == "atom"
    end

    test "returns nil when neither string nor atom key exists" do
      assert MapHelpers.get_key(%{"other" => "value"}, "name") == nil
    end

    test "returns nil for empty map with string key" do
      assert MapHelpers.get_key(%{}, "name") == nil
    end

    test "handles string key with no existing atom safely" do
      # This key should not exist as an atom in the atom table
      assert MapHelpers.get_key(%{}, "zzz_nonexistent_key_12345") == nil
    end

    test "returns integer values with string key" do
      assert MapHelpers.get_key(%{age: 25}, "age") == 25
    end
  end

  describe "get_key/2 with nil and non-map inputs" do
    test "returns nil when map is nil" do
      assert MapHelpers.get_key(nil, :name) == nil
    end

    test "returns nil when map is a non-map value" do
      assert MapHelpers.get_key("not a map", :name) == nil
    end

    test "returns nil when map is a list" do
      assert MapHelpers.get_key([name: "Alice"], :name) == nil
    end

    test "returns nil when key is nil" do
      assert MapHelpers.get_key(%{name: "Alice"}, nil) == nil
    end

    test "returns nil when both are nil" do
      assert MapHelpers.get_key(nil, nil) == nil
    end
  end

  describe "get_key/2 with structs" do
    test "works with structs (which are maps)" do
      uri = URI.parse("https://example.com")
      assert MapHelpers.get_key(uri, :host) == "example.com"
    end

    test "falls back to string key on struct" do
      # Structs won't have string keys, so this returns nil
      uri = URI.parse("https://example.com")
      assert MapHelpers.get_key(uri, :nonexistent) == nil
    end
  end

  describe "get_key/2 edge cases" do
    test "handles empty string values" do
      assert MapHelpers.get_key(%{name: ""}, :name) == ""
    end

    test "handles 0 values (truthy in Elixir, not treated as missing)" do
      assert MapHelpers.get_key(%{"count" => 99, count: 0}, :count) == 0
    end

    test "atom key with special characters" do
      assert MapHelpers.get_key(%{"hello world" => "val"}, :"hello world") == "val"
    end

    test "works with large maps" do
      large = for i <- 1..100, into: %{}, do: {"key_#{i}", i}
      assert MapHelpers.get_key(large, :key_50) == 50
    end
  end
end
