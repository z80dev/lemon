defmodule LemonControlPlane.Methods.SystemMethodsTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.Methods.{EventsIngest, LogsTail, SystemPresence, SystemEvent}

  defmodule LogRingStub do
    def get_logs(limit, level) do
      [
        %{
          "level" => "info",
          "message" => "ready api_key=test123 authorization Bearer abc.def",
          "metadata" => %{"token" => "nested-secret", "safe" => "ok"}
        },
        %{"level" => "error", "message" => "failed"},
        %{"level" => "info", "message" => "done"}
      ]
      |> Enum.filter(fn log -> is_nil(level) or log["level"] == level end)
      |> Enum.take(limit)
    end
  end

  describe "LogsTail.handle/2" do
    setup do
      old_log_ring = Application.get_env(:lemon_control_plane, :log_ring_module)

      Application.put_env(:lemon_control_plane, :log_ring_module, LogRingStub)

      on_exit(fn ->
        if old_log_ring do
          Application.put_env(:lemon_control_plane, :log_ring_module, old_log_ring)
        else
          Application.delete_env(:lemon_control_plane, :log_ring_module)
        end
      end)

      :ok
    end

    test "returns filtered logs with summary and cleanup flags" do
      {:ok, result} = LogsTail.handle(%{"lines" => "10", "filter" => "INFO"}, %{})

      assert result["total"] == 2
      assert result["filters"]["limit"] == 10
      assert result["filters"]["level"] == "info"
      assert result["summary"]["count"] == 2
      assert result["summary"]["levelCounts"]["info"] == 2

      assert result["logs"] |> hd() |> get_in(["metadata", "token"]) == %{
               "redacted" => true,
               "kind" => "secret"
             }

      assert result["logs"] |> hd() |> get_in(["metadata", "safe"]) == "ok"
      assert result["logs"] |> hd() |> Map.fetch!("message") =~ "api_key=[REDACTED]"
      assert result["logs"] |> hd() |> Map.fetch!("message") =~ "Bearer [REDACTED]"
      refute inspect(result) =~ "test123"
      refute inspect(result) =~ "nested-secret"
      refute inspect(result) =~ "abc.def"
      assert result["summary"]["cleanup"]["includesLogMessages"] == true
      assert result["summary"]["cleanup"]["redactsSensitiveLogValues"] == true
      assert result["summary"]["cleanup"]["includesRawProcessState"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
    end

    test "returns empty summarized response when log ring is unavailable" do
      Application.put_env(
        :lemon_control_plane,
        :log_ring_module,
        :"Elixir.LemonControlPlane.MissingLogRingForTest"
      )

      {:ok, result} = LogsTail.handle(%{"limit" => -1}, %{})

      assert result["logs"] == []
      assert result["total"] == 0
      assert result["filters"]["limit"] == 100
      assert result["summary"]["count"] == 0
      assert result["summary"]["cleanup"]["includesLogMessages"] == true
    end
  end

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
      assert result["summary"]["connectionCount"] == result["connections"]
      assert result["summary"]["activeRunCount"] == result["activeRuns"]
      assert result["summary"]["healthStatus"] == "healthy"
      assert result["summary"]["timestampMs"] == result["timestamp"]
      assert result["summary"]["memoryTotal"] == result["resources"]["memoryTotal"]
      assert result["summary"]["processCount"] == result["resources"]["processCount"]
      assert result["summary"]["schedulerCount"] == result["resources"]["schedulers"]
      assert result["summary"]["cleanup"]["includesCurrentConnectionId"] == true
      assert result["summary"]["cleanup"]["includesOtherConnectionIds"] == false
      assert result["summary"]["cleanup"]["includesRawProcessState"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
    end

    test "name returns correct method name" do
      assert SystemPresence.name() == "system-presence"
    end

    test "scopes returns read scope" do
      assert SystemPresence.scopes() == [:read]
    end
  end

  describe "EventsIngest.handle/2" do
    test "ingests custom events with summary and cleanup flags" do
      {:ok, result} =
        EventsIngest.handle(
          %{
            "eventType" => "custom_widget",
            "payload" => %{"message" => "not echoed"},
            "target" => "session:session-1"
          },
          %{}
        )

      assert result["ingested"] == true
      assert result["eventType"] == "custom_widget"
      assert result["target"] == "session:session-1"
      assert is_integer(result["timestampMs"])
      assert result["summary"]["targetKind"] == "session"
      assert result["summary"]["payloadKeyCount"] == 2
      assert result["summary"]["custom"] == true
      assert result["summary"]["cleanup"]["includesPayload"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
      refute Map.has_key?(result, "payload")
    end

    test "rejects invalid ingest payloads and targets" do
      assert {:error, {:invalid_request, "payload must be an object"}} =
               EventsIngest.handle(%{"eventType" => "custom", "payload" => "raw"}, %{})

      assert {:error, {:invalid_request, message}} =
               EventsIngest.handle(%{"eventType" => "custom", "target" => "private"}, %{})

      assert message =~ "Invalid target"

      assert {:error, {:invalid_request, "eventType must be a string"}} =
               EventsIngest.handle(%{"eventType" => 123}, %{})
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
      assert result["summary"]["targetKind"] == "system"
      assert result["summary"]["payloadKeyCount"] == 1
      assert result["summary"]["cleanup"]["includesPayload"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
      refute Map.has_key?(result, "payload")
    end

    test "emits event to specified target topic" do
      ctx = %{conn_id: "test-conn-123", auth: %{role: :operator}}
      params = %{"eventType" => "custom", "payload" => %{}, "target" => "channels"}

      {:ok, result} = SystemEvent.handle(params, ctx)

      assert result["topic"] == "channels"
      assert result["summary"]["targetKind"] == "channels"
    end

    test "emits event to run topic" do
      ctx = %{conn_id: "test-conn-123", auth: %{role: :operator}}
      params = %{"eventType" => "custom", "payload" => %{}, "target" => "run:abc123"}

      {:ok, result} = SystemEvent.handle(params, ctx)

      assert result["topic"] == "run:abc123"
      assert result["summary"]["targetKind"] == "run"
    end

    test "accepts snake-case event_type and atom-keyed payload" do
      ctx = %{conn_id: "test-conn-123", auth: %{role: :operator}}

      params = %{
        event_type: "custom_widget",
        payload: %{"safe" => true},
        target: "session:abc123"
      }

      {:ok, result} = SystemEvent.handle(params, ctx)

      assert result["eventType"] == "custom_widget"
      assert result["topic"] == "session:abc123"
      assert result["summary"]["custom"] == true
      assert result["summary"]["targetKind"] == "session"
      assert result["summary"]["payloadKeyCount"] == 2
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

    test "rejects invalid payloads and targets" do
      ctx = %{conn_id: "test-conn-123", auth: %{role: :operator}}

      assert {:error, {:invalid_request, "payload must be an object", nil}} =
               SystemEvent.handle(%{"eventType" => "tick", "payload" => "raw"}, ctx)

      assert {:error, {:invalid_request, message, nil}} =
               SystemEvent.handle(%{"eventType" => "custom", "target" => "private"}, ctx)

      assert message =~ "Invalid target"

      assert {:error, {:invalid_request, "eventType must be a string", nil}} =
               SystemEvent.handle(%{"eventType" => 123}, ctx)
    end

    test "name returns correct method name" do
      assert SystemEvent.name() == "system-event"
    end

    test "scopes returns admin scope" do
      assert SystemEvent.scopes() == [:admin]
    end
  end
end
