defmodule LemonCore.JSONPayloadTest do
  use ExUnit.Case, async: true

  alias LemonCore.JSONPayload

  test "accepts bounded JSON and reports content-free statistics" do
    payload = %{answer: "done", nested: [%{"ok" => true}]}

    assert {:ok, decoded} = JSONPayload.round_trip(payload)
    assert decoded == %{"answer" => "done", "nested" => [%{"ok" => true}]}

    assert %{present: true, kind: :object, bytes: bytes, depth: 3, item_count: 5} =
             JSONPayload.summary(payload)

    assert bytes > 0
  end

  test "rejects byte, depth, item, and JSON-shape overflows" do
    assert {:error, {:max_bytes, 8}} =
             JSONPayload.validate(%{"value" => "too large"}, max_bytes: 8)

    assert {:error, {:max_depth, 2}} =
             JSONPayload.validate(%{"a" => [%{"b" => true}]}, max_depth: 2)

    assert {:error, {:max_items, 3}} =
             JSONPayload.validate([1, 2, 3], max_items: 3)

    assert {:error, {:not_json_safe, {:invalid_object_key, :integer}}} =
             JSONPayload.validate(%{1 => "invalid key"})
  end
end
