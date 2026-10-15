defmodule LemonCore.IntrospectionStoreTest do
  use ExUnit.Case, async: false

  alias LemonCore.IntrospectionStore

  test "appends and lists introspection events through the typed wrapper" do
    run_id = "run_#{System.unique_integer([:positive])}"

    event = %{
      event_id: "evt_#{System.unique_integer([:positive])}",
      ts_ms: System.system_time(:millisecond),
      event_type: :run_started,
      provenance: :direct,
      run_id: run_id,
      payload: %{engine: "codex"}
    }

    assert :ok = IntrospectionStore.append(event)

    assert Enum.any?(IntrospectionStore.list(run_id: run_id, limit: 10), fn stored ->
             stored.run_id == run_id and stored.event_id == event.event_id
           end)

    assert IntrospectionStore.count(run_id: run_id) >= 1
  end

  test "terminal seed includes all events beyond the listing cap and respects its boundary" do
    ts = System.system_time(:millisecond)
    prefix = "daily-seed-#{System.unique_integer([:positive])}"

    for i <- 1..1001 do
      assert :ok =
               IntrospectionStore.append(%{
                 event_id: "#{prefix}-#{i}",
                 ts_ms: ts,
                 event_type: if(rem(i, 2) == 0, do: :run_failed, else: :run_completed),
                 provenance: :direct,
                 run_id: "#{prefix}-#{i}",
                 payload: %{ok: rem(i, 2) != 0}
               })
    end

    assert {:ok, events} = IntrospectionStore.terminal_events_since(ts)
    assert Enum.count(events, &String.starts_with?(&1.run_id || "", prefix)) == 1001
    assert {:ok, later} = IntrospectionStore.terminal_events_since(ts + 1)
    refute Enum.any?(later, &String.starts_with?(&1.run_id || "", prefix))
  end
end
