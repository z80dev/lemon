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
end
