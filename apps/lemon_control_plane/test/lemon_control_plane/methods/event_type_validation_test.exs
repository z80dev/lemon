defmodule LemonControlPlane.Methods.EventTypeValidationTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.Methods.{SystemEvent, NodeEvent, ConfigGet}

  @admin_ctx %{conn_id: "test-conn", auth: %{role: :operator}}
  @node_ctx %{conn_id: "test-conn", auth: %{role: :node, client_id: "node-123"}}

  describe "SystemEvent event type validation" do
    test "rejects invalid event types to prevent atom leaks" do
      params = %{"eventType" => "malicious_arbitrary_type_#{:rand.uniform(1_000_000)}"}

      {:error, error} = SystemEvent.handle(params, @admin_ctx)

      assert {:invalid_request, message, nil} = error
      assert String.contains?(message, "Invalid event type")
    end

    # Types with a typed payload in LemonCore.Events must be given a payload that coerces
    # into their struct; the rest still accept anything. Keyed by event type so this stays
    # driven by the allowlist rather than by a hand-maintained parallel list.
    @valid_payloads %{
      "talk_mode_changed" => %{session_key: "sess-1", mode: "voice"},
      "heartbeat_alert" => %{agent_id: "agent-1"},
      "run_started" => %{run_id: "run-1"},
      "run_completed" => %{completed: %{ok: true, answer: "done"}},
      "delta" => %{run_id: "run-1", seq: 1, text: "hello"},
      "approval_requested" => %{
        approval_id: "appr-1",
        pending: %{id: "appr-1", tool: "bash"}
      },
      "approval_resolved" => %{approval_id: "appr-1", decision: "deny"},
      "cron_run_started" => %{cron_run_id: "cr-1", job_id: "job-1"},
      "cron_run_completed" => %{cron_run_id: "cr-1", job_id: "job-1"},
      "cron_tick" => %{timestamp_ms: 1_754_800_000_000}
    }

    test "accepts allowed event types given a valid payload" do
      for event_type <- SystemEvent.allowed_event_types() do
        payload = Map.get(@valid_payloads, event_type, %{})
        params = %{"eventType" => event_type, "payload" => payload}
        result = SystemEvent.handle(params, @admin_ctx)

        assert {:ok, response} = result, "#{event_type} was rejected: #{inspect(result)}"
        assert response["success"] == true
        assert response["eventType"] == event_type
      end
    end

    test "every registered event type has a valid-payload example here" do
      # Guards the test above from quietly degrading: if a typed event is added to the
      # allowlist without an example, it would be exercised with `%{}` and silently start
      # asserting the rejection path instead of the acceptance path.
      missing =
        SystemEvent.allowed_event_types()
        |> Enum.filter(fn type ->
          atom = Map.fetch!(SystemEvent.event_type_atoms(), type)
          LemonCore.Events.registered?(atom) and not Map.has_key?(@valid_payloads, type)
        end)

      assert missing == [],
             "these typed event types need a valid payload example: #{inspect(missing)}"
    end

    test "accepts custom_ prefixed events" do
      params = %{"eventType" => "custom_my_special_event", "payload" => %{"data" => 123}}

      {:ok, response} = SystemEvent.handle(params, @admin_ctx)

      assert response["success"] == true
      assert response["eventType"] == "custom_my_special_event"
    end

    test "rejects a malformed run_completed rather than broadcasting it" do
      # The forgery this guards: system-event can target any run:<id> topic, so a
      # malformed completion would reach the chat plugins, the web UI, the ACP server and
      # cron's completion waiters, all of which would treat it as the engine's own output.
      params = %{
        "eventType" => "run_completed",
        "target" => "run:some-live-run",
        "payload" => %{"answer" => "I decide this run succeeded"}
      }

      assert {:error, {:invalid_request, message, nil}} =
               SystemEvent.handle(params, @admin_ctx)

      assert message =~ "not a valid 'run_completed' event"
      assert message =~ "RunCompleted"
    end

    test "accepts a well-formed run_completed and broadcasts it typed" do
      topic = "run:typed-injection-#{System.unique_integer([:positive])}"
      :ok = LemonCore.Bus.subscribe(topic)

      params = %{
        "eventType" => "run_completed",
        "target" => topic,
        "payload" => %{"completed" => %{"ok" => true, "answer" => "real answer"}}
      }

      assert {:ok, response} = SystemEvent.handle(params, @admin_ctx)
      assert response["success"] == true

      assert_receive %LemonCore.Event{
                       type: :run_completed,
                       payload: %LemonCore.Events.RunCompleted{
                         completed: %LemonCore.Events.Completion{ok: true, answer: "real answer"}
                       }
                     },
                     1_000

      LemonCore.Bus.unsubscribe(topic)
    end

    test "rejects a non-map payload for a typed event" do
      params = %{"eventType" => "delta", "payload" => "just a string"}

      assert {:error, {:invalid_request, message, nil}} = SystemEvent.handle(params, @admin_ctx)
      assert message =~ "payload"
    end

    test "leaves unregistered types free-form" do
      params = %{"eventType" => "shutdown", "payload" => %{"anything" => "at all"}}

      assert {:ok, response} = SystemEvent.handle(params, @admin_ctx)
      assert response["success"] == true
    end

    test "allowed_event_types returns a list of strings" do
      types = SystemEvent.allowed_event_types()

      assert is_list(types)
      assert types != []
      assert Enum.all?(types, &is_binary/1)
    end

    test "includes critical system events" do
      types = SystemEvent.allowed_event_types()

      assert "shutdown" in types
      assert "health_changed" in types
      assert "tick" in types
      assert "heartbeat" in types
    end
  end

  describe "NodeEvent event type validation" do
    test "rejects invalid event types to prevent atom leaks" do
      params = %{"eventType" => "evil_type_#{:rand.uniform(1_000_000)}"}

      {:error, error} = NodeEvent.handle(params, @node_ctx)

      assert {:invalid_request, message} = error
      assert String.contains?(message, "Invalid event type")
    end

    test "accepts allowed node event types" do
      for event_type <- NodeEvent.allowed_event_types() do
        params = %{"eventType" => event_type, "payload" => %{}}
        result = NodeEvent.handle(params, @node_ctx)

        assert {:ok, response} = result
        assert response["broadcast"] == true
        assert response["summary"]["eventType"] == event_type
        assert response["summary"]["cleanup"]["includesPayload"] == false
      end
    end

    test "accepts custom_ prefixed node events" do
      params = %{"eventType" => "custom_node_metric", "payload" => %{"value" => 42}}

      {:ok, response} = NodeEvent.handle(params, @node_ctx)

      assert response["broadcast"] == true
      assert response["eventType"] == "custom_node_metric"
      assert response["summary"]["custom"] == true
      assert response["summary"]["payloadKeyCount"] == 1
    end

    test "requires node role" do
      operator_ctx = %{conn_id: "test", auth: %{role: :operator}}
      params = %{"eventType" => "status", "payload" => %{}}

      {:error, error} = NodeEvent.handle(params, operator_ctx)

      assert {:forbidden, _} = error
    end

    test "allowed_event_types returns expected node events" do
      types = NodeEvent.allowed_event_types()

      assert "status" in types
      assert "heartbeat" in types
      assert "error" in types
      assert "connected" in types
      assert "disconnected" in types
    end
  end

  describe "ConfigGet key validation" do
    test "allowed_config_keys returns a list" do
      keys = ConfigGet.allowed_config_keys()

      assert is_list(keys)
      assert keys != []
    end

    test "returns nil for arbitrary keys not in allowed list" do
      # This tests that arbitrary strings don't create atoms
      params = %{"key" => "arbitrary_config_key_#{:rand.uniform(1_000_000)}"}

      {:ok, response} = ConfigGet.handle(params, @admin_ctx)

      # Should return nil for unknown keys, not crash or create atoms
      assert response["key"] == params["key"]
      assert response["value"] == nil
    end

    test "returns values for allowed config keys" do
      params = %{"key" => "logLevel"}

      {:ok, response} = ConfigGet.handle(params, @admin_ctx)

      assert response["key"] == "logLevel"
      # Value may be nil if not configured, but should not error
    end

    test "returns all config without key parameter" do
      params = %{}

      {:ok, response} = ConfigGet.handle(params, @admin_ctx)

      assert is_map(response)
      # Response may be empty if no config is set, but should always be a map
    end

    test "includes standard config keys" do
      keys = ConfigGet.allowed_config_keys()

      assert "logLevel" in keys
      assert "env" in keys
    end
  end
end
