defmodule CodingAgent.Search.SingleFlightTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Search.SingleFlight

  test "coalesces concurrent work and returns one result to every caller" do
    counter = :counters.new(1, [:atomics])

    operation = fn ->
      :counters.add(counter, 1, 1)
      Process.sleep(75)
      {:ok, :shared}
    end

    results =
      1..12
      |> Task.async_stream(
        fn _ -> SingleFlight.run(:same_query, operation, 1_000) end,
        max_concurrency: 12,
        timeout: 2_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.uniq(results) == [{:ok, :shared}]
    assert :counters.get(counter, 1) == 1
  end

  test "contains task exceptions" do
    assert {:error, {:single_flight_exception, "boom"}} =
             SingleFlight.run(make_ref(), fn -> raise "boom" end, 1_000)
  end
end
