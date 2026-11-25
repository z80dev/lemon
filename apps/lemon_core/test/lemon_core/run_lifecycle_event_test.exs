defmodule LemonCore.RunLifecycleEventTest do
  use ExUnit.Case, async: true

  alias LemonCore.{Event, Events}

  test "unversioned published package payloads decode without creating a new run identity" do
    legacy = Event.new_with_ts(:run_started, 42, %Events.RunStarted{run_id: "r"})
    assert {:ok, started} = Event.decode_run_lifecycle(legacy)

    assert started.meta == %{
             run_id: "r",
             session_key: nil,
             schema_version: 1,
             event_id: "run:1:r:r:attempt:1:1",
             attempt_id: "r:attempt:1",
             seq: 1
           }

    assert {:ok, ^started} = Event.decode_run_lifecycle(started)
  end

  test "remote JSON preserves supplied identity and explicitly rejects unsupported versions" do
    remote =
      JSON.decode!(
        ~S({"type":"run_completed","ts_ms":43,"payload":{"completed":{"ok":false}},"meta":{"schema_version":1,"event_id":"run:1:r:attempt-3:2","run_id":"r","attempt_id":"attempt-3","seq":2}})
      )

    assert {:ok, %Event{type: :run_completed, meta: meta, payload: payload}} =
             Event.decode_run_lifecycle(remote)

    assert %Events.RunCompleted{completed: %Events.Completion{ok: false}} = payload
    assert %{event_id: "run:1:r:attempt-3:2", attempt_id: "attempt-3", run_id: "r", seq: 2} = meta

    assert {:error, {:unsupported_schema_version, 2}} =
             Event.decode_run_lifecycle(put_in(remote, ["meta", "schema_version"], 2))

    assert {:error, :invalid_run_identity} =
             Event.decode_run_lifecycle(put_in(remote, ["meta", "event_id"], "forged"))
  end

  test "the same custom attempt identifier on two runs cannot collide" do
    event = Event.new(:run_started, %{})
    first = Event.identify_run(event, "run-a", "custom")
    second = Event.identify_run(event, "run-b", "custom")
    assert first.meta.event_id != second.meta.event_id
    assert first == Event.identify_run(event, "run-a", "custom")
  end
end
