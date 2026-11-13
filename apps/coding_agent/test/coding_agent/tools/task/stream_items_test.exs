defmodule CodingAgent.Tools.Task.StreamItemsTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Task.StreamItems

  # Escapes, structural characters inside strings, unicode, nested values in
  # items, and members on both sides of `tasks`.
  @document ~S"""
  {
    "context": "shared } ] \" \\ {[ ,: \u00e9 🍋",
    "async" : false,
    "meta": {"tags": ["a", {"b": [1, 2.5e3, null, true]}], "note": "}]"},
    "tasks": [
      {"description": "one", "prompt": "say \"hi\" \\ then {stop}"},
      {"prompt": "nested", "tool_policy": {"deny": ["bash", "write"], "approvals": {"read": "never"}},
       "output_schema": {"type": "object", "properties": {"a": {"type": ["string", "null"]}}}},
      {"prompt": "unicode \ud83c\udf4b \u0041\/\b\f\n\r\t", "request_budget": 12}
    ],
    "thinking_level": "high"
  }
  """

  test "emits every item when its object closes, whatever the chunking" do
    decoded = Jason.decode!(@document)
    before_tasks = Map.take(decoded, ["context", "async", "meta"])

    expected =
      for {item, index} <- Enum.with_index(decoded["tasks"]), do: {index, item, before_tasks}

    for chunking <- [1, 2, 3, 5, 8, 13, :random, :random, :random] do
      {reader, items} = feed_all(@document, chunking)
      assert items == expected, "chunking #{inspect(chunking)}"
      refute StreamItems.invalid?(reader)
      assert reader.top == :done
    end
  end

  test "an item is returned by the feed that closes it, not before" do
    json = ~s({"context":"c","tasks":[{"prompt":"a"},{"prompt":"b"}]})
    close = byte_size(~s({"context":"c","tasks":[{"prompt":"a"}))

    {reader, []} = StreamItems.feed(StreamItems.new(), binary_part(json, 0, close - 1))

    {reader, [{0, %{"prompt" => "a"}, %{"context" => "c"}}]} =
      StreamItems.feed(reader, binary_part(json, 0, close))

    {reader, []} = StreamItems.feed(reader, binary_part(json, 0, close))
    assert reader.pos == close
    assert {_reader, [{1, %{"prompt" => "b"}, _}]} = StreamItems.feed(reader, json)
  end

  test "members written after tasks are not part of an item's snapshot" do
    json = ~s({"tasks":[{"prompt":"a"}],"worktree":true,"context":"late"})
    assert {reader, [{0, %{"prompt" => "a"}, fields}]} = feed_all(json, 1)
    assert fields == %{}
    assert reader.fields == %{"worktree" => true, "context" => "late"}
  end

  test "keys are decoded before matching tasks" do
    json = ~S({"ta\u0073ks":[{"prompt":"x"}]})
    assert {_reader, [{0, %{"prompt" => "x"}, %{}}]} = feed_all(json, 1)
  end

  test "an escape split across feeds does not end the string" do
    json = ~S({"tasks":[{"prompt":"a\"}]"}]})
    {backslash, 1} = :binary.match(json, "\\")
    split = backslash + 1

    {reader, []} = StreamItems.feed(StreamItems.new(), binary_part(json, 0, split))
    assert reader.escape
    assert {_reader, [{0, %{"prompt" => ~S(a"}])}, %{}}]} = StreamItems.feed(reader, json)
  end

  test "a tasks value that is not an array yields no items" do
    json = ~S({"tasks":"[{\"prompt\":\"a\"}]","context":"c"})
    assert {reader, []} = feed_all(json, 3)
    refute StreamItems.invalid?(reader)
    assert reader.fields == %{"context" => "c"}
  end

  test "text the finished call could not validate as a batch is invalid" do
    for json <- [
          ~s({"tasks":["prompt"]}),
          ~s({"tasks":[1]}),
          ~s({"tasks":[[{"prompt":"a"}]]}),
          ~s({"tasks":[{"prompt":"a"}],"tasks":[]}),
          ~s({"tasks":[{"prompt":"a"]}),
          ~s({"a":1 "b":2}),
          ~s({"a" 1}),
          ~s({a:1}),
          ~s({"a":tru e}),
          ~s(x{"tasks":[]}),
          ~s([{"prompt":"a"}])
        ] do
      {reader, _items} = feed_all(json, 1)
      assert StreamItems.invalid?(reader), json
      assert {^reader, []} = StreamItems.feed(reader, json <> ~s({"prompt":"b"}))
    end
  end

  test "items before an invalidating byte are still reported" do
    json = ~s({"tasks":[{"prompt":"a"},"b"]})
    assert {reader, [{0, %{"prompt" => "a"}, %{}}]} = feed_all(json, 1)
    assert StreamItems.invalid?(reader)
  end

  test "text that stops extending the previous feed is invalid" do
    {reader, []} = StreamItems.feed(StreamItems.new(), ~s({"tasks":[))
    assert {reader, []} = StreamItems.feed(reader, "{")
    assert StreamItems.invalid?(reader)
  end

  test "trailing text after the closed object is ignored" do
    json = ~s({"tasks":[{"prompt":"a"}]}{"tasks":[{"prompt":"b"}]})
    assert {reader, [{0, %{"prompt" => "a"}, %{}}]} = feed_all(json, 4)
    assert reader.top == :done
  end

  defp feed_all(json, chunking) do
    json
    |> prefixes(chunking)
    |> Enum.reduce({StreamItems.new(), []}, fn prefix, {reader, items} ->
      {reader, new} = StreamItems.feed(reader, prefix)
      {reader, items ++ new}
    end)
  end

  defp prefixes(json, :random) do
    size = byte_size(json)

    Stream.unfold(0, fn
      ^size ->
        nil

      at ->
        next = min(size, at + :rand.uniform(9))
        {binary_part(json, 0, next), next}
    end)
    |> Enum.to_list()
  end

  defp prefixes(json, step) do
    size = byte_size(json)
    for at <- Enum.uniq(Enum.to_list(step..size//step) ++ [size]), do: binary_part(json, 0, at)
  end
end
