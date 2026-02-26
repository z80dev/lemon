defmodule LemonServicesTest do
  use ExUnit.Case

  alias LemonServices.Service.Definition

  setup do
    # Ensure the application is started
    Application.ensure_all_started(:lemon_services)

    # Clean up any test services
    on_exit(fn ->
      # Stop any running test services
      for service <- LemonServices.list_services() do
        if service.definition.id in [:test_service, :test_shell_service, :test_module_service] do
          LemonServices.stop_service(service.definition.id)
        end
      end

      # Clean up definitions
      for id <- [:test_service, :test_shell_service, :test_module_service, :test_query_service,
                 :test_get_service, :pubsub_test_service, :tool_test_service, :status_test_service,
                 :defined_test_service, :log_test] do
        try do
          LemonServices.unregister_definition(id)
        catch
          _, _ -> :ok
        end
      end
    end)

    :ok
  end

  describe "service lifecycle" do
    test "define and start a shell service" do
      # Define a simple echo service
      {:ok, definition} = Definition.new(
        id: :test_shell_service,
        name: "Test Shell Service",
        command: {:shell, "echo 'hello' && sleep 10"},
        restart_policy: :temporary
      )

      :ok = LemonServices.register_definition(definition)

      # Start the service
      {:ok, _pid} = LemonServices.start_service(:test_shell_service)

      # Check it's running
      assert LemonServices.running?(:test_shell_service)

      # Get status
      {:ok, state} = LemonServices.get_service(:test_shell_service)
      assert state.definition.id == :test_shell_service
      assert state.status == :running

      # Stop it
      :ok = LemonServices.stop_service(:test_shell_service)
      refute LemonServices.running?(:test_shell_service)
    end

    test "restart service" do
      {:ok, definition} = Definition.new(
        id: :test_service,
        name: "Test Service",
        command: {:shell, "sleep 30"},
        restart_policy: :temporary
      )

      :ok = LemonServices.register_definition(definition)
      {:ok, pid1} = LemonServices.start_service(:test_service)

      # Restart
      {:ok, pid2} = LemonServices.restart_service(:test_service)

      # Should be different PIDs
      refute pid1 == pid2

      # Clean up
      LemonServices.stop_service(:test_service)
    end

    test "service not found error" do
      assert {:error, :definition_not_found} = LemonServices.start_service(:nonexistent)
    end
  end

  describe "service queries" do
    test "list definitions" do
      {:ok, definition} = Definition.new(
        id: :test_query_service,
        name: "Test Query Service",
        command: {:shell, "sleep 1"},
        tags: [:test, :query]
      )

      :ok = LemonServices.register_definition(definition)

      definitions = LemonServices.list_definitions()
      assert Enum.any?(definitions, &(&1.id == :test_query_service))

      # Clean up
      LemonServices.unregister_definition(:test_query_service)
    end

    test "get definition" do
      {:ok, definition} = Definition.new(
        id: :test_get_service,
        name: "Test Get Service",
        command: {:shell, "sleep 1"}
      )

      :ok = LemonServices.register_definition(definition)

      {:ok, retrieved} = LemonServices.get_definition(:test_get_service)
      assert retrieved.id == :test_get_service
      assert retrieved.name == "Test Get Service"

      # Clean up
      LemonServices.unregister_definition(:test_get_service)
    end
  end

  describe "service definition validation" do
    test "validates required fields" do
      assert {:error, _} = Definition.new(name: "Test")
      assert {:error, _} = Definition.new(id: :test)
      assert {:error, _} = Definition.new(id: :test, name: "Test")
    end

    test "accepts valid definition" do
      assert {:ok, _} = Definition.new(
        id: :valid_test,
        name: "Valid Test",
        command: {:shell, "echo hello"}
      )
    end

    test "validates restart policy" do
      assert {:error, _} = Definition.new(
        id: :invalid_policy,
        name: "Invalid Policy",
        command: {:shell, "echo hello"},
        restart_policy: :invalid
      )
    end

    test "validates health check" do
      assert {:ok, _} = Definition.new(
        id: :health_test,
        name: "Health Test",
        command: {:shell, "echo hello"},
        health_check: {:http, "http://localhost:3000", 5000}
      )

      assert {:error, _} = Definition.new(
        id: :bad_health_test,
        name: "Bad Health Test",
        command: {:shell, "echo hello"},
        health_check: {:invalid, "test"}
      )
    end
  end

  describe "log buffer" do
    test "stores and retrieves logs" do
      # Create a log buffer directly
      {:ok, _pid} = LemonServices.Runtime.LogBuffer.start_link(service_id: :log_buffer_test)

      # Append some logs
      :ok = LemonServices.Runtime.LogBuffer.append(:log_buffer_test, %{
        timestamp: DateTime.utc_now(),
        stream: :stdout,
        data: "line 1"
      })

      :ok = LemonServices.Runtime.LogBuffer.append(:log_buffer_test, %{
        timestamp: DateTime.utc_now(),
        stream: :stdout,
        data: "line 2"
      })

      # Small delay for async operations
      Process.sleep(10)

      # Get logs
      logs = LemonServices.Runtime.LogBuffer.get_logs(:log_buffer_test, 10)
      assert length(logs) == 2
    end
  end

  describe "pubsub events" do
    test "subscribe to service events" do
      {:ok, definition} = Definition.new(
        id: :pubsub_test_service,
        name: "PubSub Test Service",
        command: {:shell, "sleep 5"},
        restart_policy: :temporary
      )

      :ok = LemonServices.register_definition(definition)

      # Subscribe to events
      :ok = LemonServices.subscribe_to_events(:pubsub_test_service)

      # Start service (should generate events)
      {:ok, _pid} = LemonServices.start_service(:pubsub_test_service)

      # Should receive starting event
      assert_receive {:service_event, :pubsub_test_service, :service_starting}, 1000
      assert_receive {:service_event, :pubsub_test_service, :service_started}, 1000

      # Stop service
      LemonServices.stop_service(:pubsub_test_service)

      # Should receive stopping/stopped events
      assert_receive {:service_event, :pubsub_test_service, :service_stopping}, 1000
      assert_receive {:service_event, :pubsub_test_service, :service_stopped}, 1000

      # Unsubscribe
      LemonServices.unsubscribe_from_events(:pubsub_test_service)
    end
  end

  describe "agent tools" do
    test "service_list tool" do
      # Register a test service
      {:ok, definition} = Definition.new(
        id: :tool_test_service,
        name: "Tool Test Service",
        command: {:shell, "sleep 1"},
        tags: [:test]
      )

      :ok = LemonServices.register_definition(definition)

      # Call the tool
      {:ok, result} = LemonServices.Agent.Tools.service_list_execute(%{}, %{})

      assert result.count >= 1
      assert Enum.any?(result.services, &(&1.id == :tool_test_service))

      # Clean up
      LemonServices.unregister_definition(:tool_test_service)
    end

    test "service_status tool" do
      {:ok, definition} = Definition.new(
        id: :status_test_service,
        name: "Status Test Service",
        command: {:shell, "sleep 1"}
      )

      :ok = LemonServices.register_definition(definition)

      # Check status (not running)
      {:ok, result} = LemonServices.Agent.Tools.service_status_execute(
        %{"service_id" => "status_test_service"},
        %{}
      )

      assert result.service_id == :status_test_service
      assert result.status == :stopped

      # Clean up
      LemonServices.unregister_definition(:status_test_service)
    end

    test "service_define tool" do
      params = %{
        "id" => "defined_test_service",
        "name" => "Defined Test Service",
        "command" => "echo hello",
        "tags" => ["test"],
        "persistent" => false
      }

      {:ok, result} = LemonServices.Agent.Tools.service_define_execute(params, %{})

      assert result.status == "defined"
      assert result.service_id == :defined_test_service

      # Verify it was registered
      assert {:ok, _} = LemonServices.get_definition(:defined_test_service)

      # Clean up
      LemonServices.unregister_definition(:defined_test_service)
    end
  end
end
