defmodule LemonCore.RedactProjectTest do
  use ExUnit.Case, async: true

  alias LemonCore.Redact

  @secret "sk-" <> String.duplicate("z", 40)

  test "deep nested maps are capped at max depth with one marker" do
    deep = Enum.reduce(1..30, "token=#{@secret}", fn i, acc -> %{"k#{i}" => acc} end)
    projected = Redact.project(deep)

    path = Stream.iterate(projected, &(&1 |> Map.values() |> hd())) |> Enum.take(7)
    assert List.last(path) == "[max_depth]"
    assert Enum.all?(Enum.take(path, 6), &is_map/1)
    assert Redact.project(deep, max_depth: 2) == %{"k30" => %{"k29" => "[max_depth]"}}
    refute Jason.encode!(projected) =~ @secret
  end

  test "lists and maps are capped at max items" do
    assert length(Redact.project(Enum.to_list(1..1_000))) == 100
    assert map_size(Redact.project(Map.new(1..500, &{&1, &1}))) == 100
    assert length(Redact.operator(Enum.to_list(1..5_000))) == 1_000
    assert Redact.project([1, 2 | :tail]) == [1, 2]
  end

  test "strings are scrubbed before clipping on a UTF-8 boundary" do
    text = String.duplicate("é", 3_000)
    clipped = Redact.project(text)
    assert byte_size(clipped) <= 4_096 and String.valid?(clipped)
    assert Redact.project("x api_key=#{@secret}") == "x api_key=[REDACTED]"
    assert Redact.project(<<255, 0, 1>>) == "[binary 3 bytes]"
  end

  test "sensitive keys, keyword pairs and tuples are masked and JSON-safe" do
    term = %{
      :password => "short",
      "options" => [token: "kwvalue", mode: :fast],
      {:weird, 1} => {"tuple", self()},
      at: ~U[2026-01-01 00:00:00Z],
      s: %URI{host: "example.test"}
    }

    projected = Redact.project(term)
    assert projected["password"] == "[REDACTED]"
    assert projected["options"] == [["token", "[REDACTED]"], ["mode", "fast"]]
    assert projected["at"] == "2026-01-01T00:00:00Z"
    assert projected["s"]["host"] == "example.test"
    refute Map.has_key?(projected["s"], "__struct__")
    encoded = Jason.encode!(projected)
    refute encoded =~ "kwvalue"
    refute encoded =~ "short"
    assert Redact.project(%{"path" => "/x", "a" => 1}, drop_keys: ["path"]) == %{"a" => 1}
  end

  test "sensitive tagged pairs are masked at every nesting position" do
    assert Redact.project({:token, "plain-short"}) == ["token", "[REDACTED]"]
    assert Redact.project({"api_key", "plain-short"}) == ["api_key", "[REDACTED]"]

    assert Redact.project(%{result: {:token, "plain-short"}}) ==
             %{"result" => ["token", "[REDACTED]"]}

    assert Redact.project([{:password, "plain-short"}]) == [["password", "[REDACTED]"]]
    assert Redact.project({:ok, {:secret, "plain-short"}}) == ["ok", ["secret", "[REDACTED]"]]

    assert Redact.project(%{a: [%{b: {:auth_token, "plain-short"}}]}) ==
             %{"a" => [%{"b" => ["auth_token", "[REDACTED]"]}]}

    assert Redact.operator(%{result: {:token, "plain-short"}}) ==
             %{"result" => ["token", "[REDACTED]"]}

    # Non-sensitive pairs and wider tuples keep their values.
    assert Redact.project({:ok, "fine"}) == ["ok", "fine"]
    assert Redact.project({:error, :timeout, 3}) == ["error", "timeout", 3]
    assert Redact.project({:token, nil}) == ["token", nil]
  end
end
