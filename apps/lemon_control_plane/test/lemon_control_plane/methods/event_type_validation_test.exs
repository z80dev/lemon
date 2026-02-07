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

    test "accepts allowed event types" do
      for event_type <- SystemEvent.allowed_event_types() do
        params = %{"eventType" => event_type, "payload" => %{}}
        result = SystemEvent.handle(params, @admin_ctx)

        assert {:ok, response} = result
        assert response["success"] == true
        assert response["eventType"] == event_type
      end
    end

    test "accepts custom_ prefixed events" do
      params = %{"eventType" => "custom_my_special_event", "payload" => %{"data" => 123}}

      {:ok, response} = SystemEvent.handle(params, @admin_ctx)

      assert response["success"] == true
      assert response["eventType"] == "custom_my_special_event"
    end

    test "allowed_event_types returns a list of strings" do
      types = SystemEvent.allowed_event_types()

      assert is_list(types)
      assert length(types) > 0
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
      end
    end

    test "accepts custom_ prefixed node events" do
      params = %{"eventType" => "custom_node_metric", "payload" => %{"value" => 42}}

      {:ok, response} = NodeEvent.handle(params, @node_ctx)

      assert response["broadcast"] == true
      assert response["eventType"] == "custom_node_metric"
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
      assert length(keys) > 0
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
