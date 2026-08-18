defmodule CodingAgent.PythonRepl.TelemetryTest do
  use ExUnit.Case, async: false

  alias CodingAgent.PythonRepl.Telemetry

  @events [
    [:coding_agent, :python_repl, :session, :start],
    [:coding_agent, :python_repl, :session, :stop],
    [:coding_agent, :python_repl, :session, :crash],
    [:coding_agent, :python_repl, :session, :reap],
    [:coding_agent, :python_repl, :cell, :start],
    [:coding_agent, :python_repl, :cell, :stop],
    [:coding_agent, :python_repl, :cell, :cancel],
    [:coding_agent, :python_repl, :fallback],
    [:coding_agent, :python_repl, :bridge, :deny]
  ]

  setup do
    handler_id = {__MODULE__, self()}
    :ok = :telemetry.attach_many(handler_id, @events, &__MODULE__.handle_event/4, self())
    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "lifecycle telemetry is complete, bounded, and excludes sensitive values" do
    sentinel_code = "SENTINEL_REPL_CODE"
    sentinel_token = "SENTINEL_REPL_TOKEN"
    sentinel_path = "/SENTINEL_REPL_PATH"
    sentinel_error = "SENTINEL_REPL_ERROR"

    Telemetry.session_started(-1, -1)
    Telemetry.session_stopped(-1, -1, -1, sentinel_error)
    Telemetry.session_crashed(-1, -1, -1, sentinel_error)
    Telemetry.session_reaped(-1, -1, -1, sentinel_path)
    Telemetry.cell_started(-1, -1)
    Telemetry.cell_stopped(-1, sentinel_code)
    Telemetry.cell_cancelled(-1, sentinel_error)
    Telemetry.fallback(sentinel_path)
    Telemetry.bridge_denied(sentinel_token)

    emitted =
      Enum.map(@events, fn event ->
        assert_receive {:python_repl_telemetry, ^event, measurements, metadata}
        {event, measurements, metadata}
      end)

    refute_receive {:python_repl_telemetry, _, _, _}

    rendered = inspect(emitted)

    for sentinel <- [sentinel_code, sentinel_token, sentinel_path, sentinel_error] do
      refute rendered =~ sentinel
    end

    assert Enum.all?(emitted, fn {_event, measurements, metadata} ->
             Enum.all?(measurements, fn {_key, value} -> is_integer(value) and value >= 0 end) and
               Enum.all?(metadata, fn {_key, value} -> is_atom(value) end)
           end)

    assert metadata_for(emitted, [:coding_agent, :python_repl, :session, :stop]) == %{
             reason: :shutdown
           }

    assert metadata_for(emitted, [:coding_agent, :python_repl, :session, :crash]) == %{
             reason: :unknown
           }

    assert metadata_for(emitted, [:coding_agent, :python_repl, :session, :reap]) == %{
             reason: :unreachable
           }

    assert metadata_for(emitted, [:coding_agent, :python_repl, :cell, :stop]) == %{
             outcome: :unknown
           }

    assert metadata_for(emitted, [:coding_agent, :python_repl, :cell, :cancel]) == %{
             cause: :unknown
           }

    assert metadata_for(emitted, [:coding_agent, :python_repl, :fallback]) == %{reason: :unknown}

    assert metadata_for(emitted, [:coding_agent, :python_repl, :bridge, :deny]) == %{
             reason: :authentication
           }
  end

  def handle_event(event, measurements, metadata, pid) do
    send(pid, {:python_repl_telemetry, event, measurements, metadata})
  end

  defp metadata_for(emitted, event) do
    {^event, _measurements, metadata} =
      Enum.find(emitted, fn {candidate, _, _} -> candidate == event end)

    metadata
  end
end
