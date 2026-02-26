defmodule LemonCore.TelemetryTest do
  # Telemetry handlers are global.
  use ExUnit.Case, async: false

  alias LemonCore.Telemetry

  def handle_telemetry(event_name, measurements, metadata, pid) do
    send(pid, {:telemetry_event, event_name, measurements, metadata})
  end

  defp attach_handler(event_names) do
    handler_id = "lemon-core-telemetry-#{System.unique_integer([:positive, :monotonic])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        event_names,
        &__MODULE__.handle_telemetry/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  test "emit/3 emits event with measurements and metadata" do
    attach_handler([[:lemon, :test, :emit]])

    marker = System.unique_integer([:positive, :monotonic])
    :ok = Telemetry.emit([:lemon, :test, :emit], %{count: 2}, %{marker: marker, source: :unit})

    assert_receive {:telemetry_event, [:lemon, :test, :emit], %{count: 2},
                    %{marker: ^marker, source: :unit}}
  end

  test "run_submit/3 emits run submit event" do
    attach_handler([[:lemon, :run, :submit]])

    session_key = "agent:test:#{System.unique_integer([:positive, :monotonic])}"
    :ok = Telemetry.run_submit(session_key, :channel, "openai:gpt-4.1")

    assert_receive {:telemetry_event, [:lemon, :run, :submit], %{count: 1},
                    %{session_key: ^session_key, origin: :channel, engine: "openai:gpt-4.1"}}
  end

  test "run_start/2 emits run_id metadata and ts_ms measurement" do
    attach_handler([[:lemon, :run, :start]])

    run_id = "run_#{System.unique_integer([:positive, :monotonic])}"
    before_ms = System.system_time(:millisecond)

    :ok = Telemetry.run_start(run_id, %{origin: :channel})

    assert_receive {:telemetry_event, [:lemon, :run, :start], measurements, metadata}
    assert metadata.run_id == run_id
    assert metadata.origin == :channel
    assert is_integer(measurements.ts_ms)
    assert measurements.ts_ms >= before_ms
  end

  test "approval_requested/3 and approval_resolved/3 emit approval events" do
    attach_handler([[:lemon, :approvals, :requested], [:lemon, :approvals, :resolved]])

    approval_id = "approval_#{System.unique_integer([:positive, :monotonic])}"

    :ok = Telemetry.approval_requested(approval_id, "shell", %{run_id: "run_1"})
    :ok = Telemetry.approval_resolved(approval_id, :approved, %{run_id: "run_1"})

    assert_receive {:telemetry_event, [:lemon, :approvals, :requested], %{count: 1},
                    %{
                      approval_id: ^approval_id,
                      tool: "shell",
                      run_id: "run_1"
                    }}

    assert_receive {:telemetry_event, [:lemon, :approvals, :resolved], %{count: 1},
                    %{
                      approval_id: ^approval_id,
                      decision: :approved,
                      run_id: "run_1"
                    }}
  end

  test "span/3 emits start and stop events via :telemetry.span" do
    attach_handler([
      [:lemon, :channels, :deliver, :start],
      [:lemon, :channels, :deliver, :stop]
    ])

    trace_id = "trace_#{System.unique_integer([:positive, :monotonic])}"

    result =
      Telemetry.span([:lemon, :channels, :deliver], %{trace_id: trace_id}, fn ->
        :ok
      end)

    assert result == :ok

    assert_receive {:telemetry_event, [:lemon, :channels, :deliver, :start], start_measurements,
                    %{trace_id: ^trace_id}}

    assert is_integer(start_measurements.system_time)

    assert_receive {:telemetry_event, [:lemon, :channels, :deliver, :stop], stop_measurements,
                    %{trace_id: ^trace_id}}

    assert is_integer(stop_measurements.duration)
  end
end
