defmodule LemonControlPlane.Methods.SystemMethodsTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.Methods.{SystemPresence, SystemEvent}

  describe "SystemPresence.handle/2" do
    test "returns presence information" do
      ctx = %{conn_id: "test-conn-123", auth: %{role: :operator}}

      {:ok, result} = SystemPresence.handle(%{}, ctx)

      assert result["connId"] == "test-conn-123"
      assert is_integer(result["connections"])
      assert is_integer(result["activeRuns"])
      assert is_integer(result["timestamp"])
      assert is_map(result["health"])
      assert result["health"]["status"] == "healthy"
      assert is_map(result["resources"])
      assert is_integer(result["resources"]["memoryTotal"])
      assert is_integer(result["resources"]["processCount"])
    end

    test "name returns correct method name" do
      assert SystemPresence.name() == "system-presence"
    end

    test "scopes returns read scope" do
      assert SystemPresence.scopes() == [:read]
    end
  end

  describe "SystemEvent.handle/2" do
    test "emits event to system topic by default" do
      ctx = %{conn_id: "test-conn-123", auth: %{role: :operator}}
      # Using "tick" which is a valid allowed event type
      params = %{"eventType" => "tick", "payload" => %{"key" => "value"}}

      {:ok, result} = SystemEvent.handle(params, ctx)

      assert result["success"] == true
      assert result["eventType"] == "tick"
      assert result["topic"] == "system"
      assert is_integer(result["timestamp"])
    end

    test "emits event to specified target topic" do
      ctx = %{conn_id: "test-conn-123", auth: %{role: :operator}}
      params = %{"eventType" => "custom", "payload" => %{}, "target" => "channels"}

      {:ok, result} = SystemEvent.handle(params, ctx)

      assert result["topic"] == "channels"
    end

    test "emits event to run topic" do
      ctx = %{conn_id: "test-conn-123", auth: %{role: :operator}}
      params = %{"eventType" => "custom", "payload" => %{}, "target" => "run:abc123"}

      {:ok, result} = SystemEvent.handle(params, ctx)

      assert result["topic"] == "run:abc123"
    end

    test "returns error when eventType is missing" do
      ctx = %{conn_id: "test-conn-123", auth: %{role: :operator}}
      params = %{}

      {:error, error} = SystemEvent.handle(params, ctx)

      assert error == {:invalid_request, "eventType is required", nil}
    end

    test "returns error when eventType is empty" do
      ctx = %{conn_id: "test-conn-123", auth: %{role: :operator}}
      params = %{"eventType" => ""}

      {:error, error} = SystemEvent.handle(params, ctx)

      assert error == {:invalid_request, "eventType is required", nil}
    end

    test "name returns correct method name" do
      assert SystemEvent.name() == "system-event"
    end

    test "scopes returns admin scope" do
      assert SystemEvent.scopes() == [:admin]
    end
  end
end
