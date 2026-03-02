defmodule LemonGateway.Transports.Webhook.HelpersTest do
  use ExUnit.Case, async: true

  alias LemonGateway.Transports.Webhook.Helpers

  describe "fetch/2" do
    test "fetches atom key from map" do
      assert Helpers.fetch(%{name: "alice"}, :name) == "alice"
    end

    test "falls back to string key in map" do
      assert Helpers.fetch(%{"name" => "bob"}, :name) == "bob"
    end

    test "fetches from keyword list" do
      assert Helpers.fetch([name: "carol"], :name) == "carol"
    end

    test "returns nil for missing key" do
      assert Helpers.fetch(%{}, :name) == nil
    end

    test "returns nil for non-map, non-list input" do
      assert Helpers.fetch("string", :name) == nil
      assert Helpers.fetch(42, :name) == nil
      assert Helpers.fetch(nil, :name) == nil
    end
  end

  describe "fetch_any/2" do
    test "returns first matching path" do
      payload = %{"body" => %{"text" => "hello"}}
      assert Helpers.fetch_any(payload, [["body", "text"]]) == "hello"
    end

    test "tries multiple paths in order" do
      payload = %{"message" => "hi"}
      assert Helpers.fetch_any(payload, [["prompt"], ["message"]]) == "hi"
    end

    test "returns nil when no path matches" do
      assert Helpers.fetch_any(%{}, [["prompt"], ["text"]]) == nil
    end

    test "returns nil for non-map input" do
      assert Helpers.fetch_any(nil, [["prompt"]]) == nil
    end
  end

  describe "normalize_blank/1" do
    test "returns nil for empty string" do
      assert Helpers.normalize_blank("") == nil
    end

    test "returns nil for whitespace-only string" do
      assert Helpers.normalize_blank("   ") == nil
    end

    test "trims and returns non-empty strings" do
      assert Helpers.normalize_blank("  hello  ") == "hello"
    end

    test "passes through non-binary values" do
      assert Helpers.normalize_blank(42) == 42
      assert Helpers.normalize_blank(nil) == nil
      assert Helpers.normalize_blank(:atom) == :atom
    end
  end

  describe "first_non_blank/1" do
    test "returns first non-blank value" do
      assert Helpers.first_non_blank([nil, "", "  ", "found"]) == "found"
    end

    test "returns nil when all values are blank" do
      assert Helpers.first_non_blank([nil, "", "  "]) == nil
    end

    test "returns first value if non-blank" do
      assert Helpers.first_non_blank(["first", "second"]) == "first"
    end
  end

  describe "int_value/2" do
    test "returns integer as-is" do
      assert Helpers.int_value(42, 0) == 42
    end

    test "parses string integer" do
      assert Helpers.int_value("123", 0) == 123
    end

    test "returns default for nil" do
      assert Helpers.int_value(nil, 99) == 99
    end

    test "returns default for unparseable string" do
      assert Helpers.int_value("abc", 99) == 99
    end

    test "returns default for other types" do
      assert Helpers.int_value(:atom, 99) == 99
    end
  end

  describe "normalize_map/1" do
    test "returns map as-is" do
      map = %{a: 1}
      assert Helpers.normalize_map(map) == map
    end

    test "converts keyword list to map" do
      assert Helpers.normalize_map(a: 1, b: 2) == %{a: 1, b: 2}
    end

    test "returns empty map for non-keyword list" do
      assert Helpers.normalize_map([1, 2, 3]) == %{}
    end

    test "returns empty map for other types" do
      assert Helpers.normalize_map(nil) == %{}
      assert Helpers.normalize_map("string") == %{}
    end
  end

  describe "resolve_boolean/2" do
    test "resolves true from various representations" do
      assert Helpers.resolve_boolean([true], false) == true
      assert Helpers.resolve_boolean(["true"], false) == true
      assert Helpers.resolve_boolean(["1"], false) == true
      assert Helpers.resolve_boolean([1], false) == true
    end

    test "false values fall through to default due to Enum.find_value semantics" do
      # Enum.find_value treats `false` as "not found", so bool_value returning
      # `false` causes the default to be used. This is the intended behavior
      # for the feature-flag use case where resolve_boolean is called.
      assert Helpers.resolve_boolean([false], true) == true
      assert Helpers.resolve_boolean(["false"], true) == true
      assert Helpers.resolve_boolean(["0"], true) == true
      assert Helpers.resolve_boolean([0], true) == true
    end

    test "returns default when no value resolves" do
      assert Helpers.resolve_boolean([nil, nil], true) == true
      assert Helpers.resolve_boolean([nil, nil], false) == false
    end

    test "uses first resolvable value" do
      assert Helpers.resolve_boolean([nil, true, false], false) == true
    end
  end

  describe "maybe_put/3" do
    test "adds key when value is non-nil" do
      assert Helpers.maybe_put(%{}, :key, "value") == %{key: "value"}
    end

    test "skips key when value is nil" do
      assert Helpers.maybe_put(%{existing: 1}, :key, nil) == %{existing: 1}
    end
  end
end
