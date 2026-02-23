defmodule LemonCore.IntrospectionTest do
  use ExUnit.Case, async: false

  alias LemonCore.Introspection

  defp unique_token do
    System.unique_integer([:positive, :monotonic])
  end

  setup do
    original = Application.get_env(:lemon_core, :introspection, [])
    Application.put_env(:lemon_core, :introspection, Keyword.put(original, :enabled, true))
    on_exit(fn -> Application.put_env(:lemon_core, :introspection, original) end)
    :ok
  end

  test "build_event applies canonical envelope and redaction defaults" do
    token = unique_token()
    ts_ms = System.system_time(:millisecond)

    payload = %{
      prompt: "sensitive",
      input: %{command: "echo test"},
      result_preview: String.duplicate("x", 400),
      nested: %{secret: "hide-me", kept: "ok"}
    }

    {:ok, event} =
      Introspection.build_event(:tool_completed, payload,
        ts_ms: ts_ms,
        run_id: "run_#{token}",
        session_key: "agent:test:#{token}",
        engine: :codex,
        agent_id: "agent_#{token}"
      )

    assert event.event_type == :tool_completed
    assert event.ts_ms == ts_ms
    assert event.run_id == "run_#{token}"
    assert event.session_key == "agent:test:#{token}"
    assert event.engine == "codex"
    assert event.provenance == :direct
    assert is_binary(event.event_id)

    refute Map.has_key?(event.payload, :prompt)
    assert event.payload.input == "[redacted]"
    assert String.contains?(event.payload.result_preview, "[truncated")
    refute Map.has_key?(event.payload.nested, :secret)
    assert event.payload.nested.kept == "ok"
  end

  test "record persists and list returns queryable introspection events" do
    token = unique_token()
    run_id = "run_introspection_#{token}"
    session_key = "agent:introspection:#{token}"

    assert :ok =
             Introspection.record(
               :run_started,
               %{phase: :start},
               run_id: run_id,
               session_key: session_key,
               engine: "claude",
               agent_id: "agent_#{token}",
               ts_ms: System.system_time(:millisecond)
             )

    events = Introspection.list(run_id: run_id, session_key: session_key, limit: 5)

    assert [%{event_type: :run_started, run_id: ^run_id, session_key: ^session_key} | _] = events
  end

  test "record rejects invalid events" do
    assert {:error, :invalid_introspection_event} =
             Introspection.build_event(nil, %{phase: :start}, [])

    assert {:error, :invalid_payload} =
             Introspection.build_event(:run_started, "bad-payload", [])
  end
end
