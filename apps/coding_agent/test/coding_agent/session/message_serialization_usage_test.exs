defmodule CodingAgent.Session.MessageSerializationUsageTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Session.MessageSerialization
  alias LemonAi.Types.{Cost, Usage}

  test "missing counters and partial costs survive the persisted JSON boundary" do
    usage = %Usage{
      input: nil,
      output: 30,
      cache_read: 20,
      cache_write: nil,
      cache_write_long: nil,
      total_tokens: 130,
      cost: %Cost{input: nil, output: 0.1, cache_read: 0.01, cache_write: nil, total: nil}
    }

    restored =
      usage
      |> MessageSerialization.serialize_usage()
      |> Jason.encode!()
      |> Jason.decode!()
      |> MessageSerialization.deserialize_usage()

    assert restored == usage
    assert MessageSerialization.deserialize_usage(nil) == nil
  end

  test "absent legacy fields stay absent rather than becoming measured zero" do
    usage = MessageSerialization.deserialize_usage(%{"output" => 30})
    assert usage.input == nil
    assert usage.output == 30
    assert usage.cache_read == nil
    assert usage.cache_write == nil
    assert usage.total_tokens == nil
    assert usage.cost == nil

    usage = MessageSerialization.deserialize_usage(%{"input" => 0, "cost" => %{"total" => 0.0}})
    assert usage.input == 0
    assert usage.cost.input == nil
    assert usage.cost.total == 0.0
  end
end
