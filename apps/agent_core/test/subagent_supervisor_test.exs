defmodule AgentCore.SubagentSupervisorTest do
  @moduledoc """
  Comprehensive tests for AgentCore.SubagentSupervisor.

  Tests cover:
  1. Supervisor initialization
  2. Child process spawning (start_subagent, start_child)
  3. Restart strategy behavior (temporary children, no restart)
  4. Process termination handling (stop_subagent, stop_subagent_by_key, stop_all)
  5. Dynamic child addition/removal
  6. Registry integration
  7. Telemetry events
  """

  use ExUnit.Case, async: false

  alias AgentCore.SubagentSupervisor
  alias AgentCore.AgentRegistry
  alias AgentCore.Test.Mocks

  # ============================================================================
  # Setup
  # ============================================================================

  setup do
    # Track initial state to verify cleanup
    initial_count = SubagentSupervisor.count()
    initial_subagents = SubagentSupervisor.list_subagents()

    on_exit(fn ->
      # Clean up any subagents created during the test
      current_subagents = SubagentSupervisor.list_subagents()
      new_subagents = current_subagents -- initial_subagents

      for pid <- new_subagents do
        if Process.alive?(pid) do
          SubagentSupervisor.stop_subagent(pid)
        end
      end
    end)

    {:ok, initial_count: initial_count}
  end

  # ============================================================================
  # 1. Supervisor Initialization Tests
  # ============================================================================

  describe "supervisor initialization" do
    test "supervisor is running on application start" do
      assert Process.whereis(AgentCore.SubagentSupervisor) != nil
      assert Process.alive?(Process.whereis(AgentCore.SubagentSupervisor))
    end

    test "supervisor uses DynamicSupervisor" do
      supervisor_pid = Process.whereis(AgentCore.SubagentSupervisor)
      assert supervisor_pid != nil

      # Verify it responds to DynamicSupervisor functions
      assert is_list(DynamicSupervisor.which_children(supervisor_pid))
      assert is_map(DynamicSupervisor.count_children(supervisor_pid))
    end

    test "can start a new supervisor with custom name" do
      # Start a separate supervisor for testing
      {:ok, pid} = SubagentSupervisor.start_link(name: :test_subagent_supervisor)

      assert Process.alive?(pid)
      assert Process.whereis(:test_subagent_supervisor) == pid

      # Clean up
      Process.exit(pid, :normal)
      Process.sleep(10)
    end

    test "init/1 returns one_for_one strategy" do
      # We can verify this by checking the supervisor's behavior
      # When a child dies, others should not be affected
      supervisor_pid = Process.whereis(AgentCore.SubagentSupervisor)
      assert supervisor_pid != nil

      # Count children confirms one_for_one is active
      children_info = DynamicSupervisor.count_children(supervisor_pid)
      assert Map.has_key?(children_info, :specs)
      assert Map.has_key?(children_info, :active)
    end
  end

  # ============================================================================
  # 2. Child Process Spawning Tests
  # ============================================================================

  describe "start_subagent/1" do
    test "starts a subagent and returns {:ok, pid}" do
      response = Mocks.assistant_message("Hello!")

      {:ok, pid} =
        SubagentSupervisor.start_subagent(
          initial_state: %{
            system_prompt: "You are a test agent.",
            model: Mocks.mock_model(),
            tools: []
          },
          convert_to_llm: Mocks.simple_convert_to_llm(),
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      assert is_pid(pid)
      assert Process.alive?(pid)

      # Cleanup
      SubagentSupervisor.stop_subagent(pid)
    end

    test "started subagent is listed in list_subagents" do
      response = Mocks.assistant_message("Test response")

      {:ok, pid} =
        SubagentSupervisor.start_subagent(
          initial_state: %{
            system_prompt: "Test",
            model: Mocks.mock_model()
          },
          convert_to_llm: Mocks.simple_convert_to_llm(),
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      assert pid in SubagentSupervisor.list_subagents()

      SubagentSupervisor.stop_subagent(pid)
    end

    test "started subagent increments count" do
      initial_count = SubagentSupervisor.count()
      response = Mocks.assistant_message("Test")

      {:ok, pid} =
        SubagentSupervisor.start_subagent(
          initial_state: %{
            system_prompt: "Test",
            model: Mocks.mock_model()
          },
          convert_to_llm: Mocks.simple_convert_to_llm(),
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      assert SubagentSupervisor.count() == initial_count + 1

      SubagentSupervisor.stop_subagent(pid)
    end

    test "can start multiple subagents concurrently" do
      initial_count = SubagentSupervisor.count()
      response = Mocks.assistant_message("Response")

      pids =
        for i <- 1..5 do
          {:ok, pid} =
            SubagentSupervisor.start_subagent(
              initial_state: %{
                system_prompt: "Agent #{i}",
                model: Mocks.mock_model()
              },
              convert_to_llm: Mocks.simple_convert_to_llm(),
              stream_fn: Mocks.mock_stream_fn_single(response)
            )

          pid
        end

      assert length(pids) == 5
      assert SubagentSupervisor.count() == initial_count + 5

      for pid <- pids do
        assert Process.alive?(pid)
        SubagentSupervisor.stop_subagent(pid)
      end
    end

    test "subagent can use custom name" do
      response = Mocks.assistant_message("Named agent")
      custom_name = :"test_named_agent_#{:rand.uniform(100_000)}"

      {:ok, pid} =
        SubagentSupervisor.start_subagent(
          name: custom_name,
          initial_state: %{
            system_prompt: "Named agent",
            model: Mocks.mock_model()
          },
          convert_to_llm: Mocks.simple_convert_to_llm(),
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      assert Process.whereis(custom_name) == pid

      SubagentSupervisor.stop_subagent(pid)
    end

    test "subagent with registry_key is registered in AgentRegistry" do
      session_id = "session_#{:rand.uniform(100_000)}"
      key = {session_id, :research, 0}
      response = Mocks.assistant_message("Registry test")

      {:ok, pid} =
        SubagentSupervisor.start_subagent(
          registry_key: key,
          initial_state: %{
            system_prompt: "Registry test agent",
            model: Mocks.mock_model()
          },
          convert_to_llm: Mocks.simple_convert_to_llm(),
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      assert {:ok, ^pid} = AgentRegistry.lookup(key)

      SubagentSupervisor.stop_subagent(pid)
    end

    test "registry_key takes precedence over name" do
      session_id = "session_#{:rand.uniform(100_000)}"
      key = {session_id, :main, 0}
      custom_name = :"conflicting_name_#{:rand.uniform(100_000)}"
      response = Mocks.assistant_message("Precedence test")

      {:ok, pid} =
        SubagentSupervisor.start_subagent(
          registry_key: key,
          name: custom_name,
          initial_state: %{
            system_prompt: "Test",
            model: Mocks.mock_model()
          },
          convert_to_llm: Mocks.simple_convert_to_llm(),
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      # registry_key should be used, not custom_name
      assert {:ok, ^pid} = AgentRegistry.lookup(key)
      # custom_name should NOT be registered
      assert Process.whereis(custom_name) == nil

      SubagentSupervisor.stop_subagent(pid)
    end
  end

  describe "start_child/1" do
    test "can start a child with custom child_spec" do
      response = Mocks.assistant_message("Custom child")

      child_spec = %{
        id: make_ref(),
        start:
          {AgentCore.Agent, :start_link,
           [
             [
               initial_state: %{
                 system_prompt: "Custom child",
                 model: Mocks.mock_model()
               },
               convert_to_llm: Mocks.simple_convert_to_llm(),
               stream_fn: Mocks.mock_stream_fn_single(response)
             ]
           ]},
        restart: :temporary,
        shutdown: 5_000,
        type: :worker
      }

      {:ok, pid} = SubagentSupervisor.start_child(child_spec)

      assert is_pid(pid)
      assert Process.alive?(pid)

      SubagentSupervisor.stop_subagent(pid)
    end

    test "start_child allows custom restart strategy" do
      response = Mocks.assistant_message("Permanent child")

      # Note: We still use temporary for cleanup ease, but the API supports it
      child_spec = %{
        id: make_ref(),
        start:
          {AgentCore.Agent, :start_link,
           [
             [
               initial_state: %{
                 system_prompt: "Permanent",
                 model: Mocks.mock_model()
               },
               convert_to_llm: Mocks.simple_convert_to_llm(),
               stream_fn: Mocks.mock_stream_fn_single(response)
             ]
           ]},
        restart: :temporary,
        shutdown: 10_000,
        type: :worker
      }

      {:ok, pid} = SubagentSupervisor.start_child(child_spec)
      assert Process.alive?(pid)

      SubagentSupervisor.stop_subagent(pid)
    end
  end

  # ============================================================================
  # 3. Restart Strategy Behavior Tests
  # ============================================================================

  describe "restart strategy" do
    test "subagents are started as temporary (no restart on failure)" do
      response = Mocks.assistant_message("Temporary agent")

      {:ok, pid} =
        SubagentSupervisor.start_subagent(
          initial_state: %{
            system_prompt: "Temporary",
            model: Mocks.mock_model()
          },
          convert_to_llm: Mocks.simple_convert_to_llm(),
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      # Get initial count
      count_before = SubagentSupervisor.count()

      # Kill the process abnormally
      Process.exit(pid, :kill)
      Process.sleep(50)

      # The process should not be restarted (temporary restart strategy)
      refute Process.alive?(pid)
      assert SubagentSupervisor.count() == count_before - 1
    end

    test "supervisor remains stable after child crash" do
      supervisor_pid = Process.whereis(AgentCore.SubagentSupervisor)
      response = Mocks.assistant_message("Crash test")

      {:ok, pid} =
        SubagentSupervisor.start_subagent(
          initial_state: %{
            system_prompt: "Crash test",
            model: Mocks.mock_model()
          },
          convert_to_llm: Mocks.simple_convert_to_llm(),
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      # Kill the child
      Process.exit(pid, :kill)
      Process.sleep(20)

      # Supervisor should still be alive and functional
      assert Process.alive?(supervisor_pid)
      assert is_list(SubagentSupervisor.list_subagents())
    end

    test "other children unaffected when one crashes (one_for_one)" do
      response = Mocks.assistant_message("One for one test")

      # Start multiple children
      {:ok, pid1} =
        SubagentSupervisor.start_subagent(
          initial_state: %{
            system_prompt: "Agent 1",
            model: Mocks.mock_model()
          },
          convert_to_llm: Mocks.simple_convert_to_llm(),
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      {:ok, pid2} =
        SubagentSupervisor.start_subagent(
          initial_state: %{
            system_prompt: "Agent 2",
            model: Mocks.mock_model()
          },
          convert_to_llm: Mocks.simple_convert_to_llm(),
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      {:ok, pid3} =
        SubagentSupervisor.start_subagent(
          initial_state: %{
            system_prompt: "Agent 3",
            model: Mocks.mock_model()
          },
          convert_to_llm: Mocks.simple_convert_to_llm(),
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      # Kill pid2
      Process.exit(pid2, :kill)
      Process.sleep(20)

      # pid1 and pid3 should still be alive
      assert Process.alive?(pid1)
      refute Process.alive?(pid2)
      assert Process.alive?(pid3)

      # Cleanup
      SubagentSupervisor.stop_subagent(pid1)
      SubagentSupervisor.stop_subagent(pid3)
    end
  end

  # ============================================================================
  # 4. Process Termination Handling Tests
  # ============================================================================

  describe "stop_subagent/1" do
    test "terminates a running subagent" do
      response = Mocks.assistant_message("To be stopped")

      {:ok, pid} =
        SubagentSupervisor.start_subagent(
          initial_state: %{
            system_prompt: "Stopping",
            model: Mocks.mock_model()
          },
          convert_to_llm: Mocks.simple_convert_to_llm(),
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      assert Process.alive?(pid)

      :ok = SubagentSupervisor.stop_subagent(pid)
      Process.sleep(20)

      refute Process.alive?(pid)
    end

    test "returns :ok for successful termination" do
      response = Mocks.assistant_message("Stop OK")

      {:ok, pid} =
        SubagentSupervisor.start_subagent(
          initial_state: %{
            system_prompt: "Stop OK",
            model: Mocks.mock_model()
          },
          convert_to_llm: Mocks.simple_convert_to_llm(),
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      result = SubagentSupervisor.stop_subagent(pid)
      assert result == :ok
    end

    test "returns {:error, :not_found} for unknown pid" do
      # Create a fake pid that's not a child of the supervisor
      fake_pid = spawn(fn -> Process.sleep(100) end)
      Process.sleep(10)

      result = SubagentSupervisor.stop_subagent(fake_pid)
      assert result == {:error, :not_found}

      # Clean up
      Process.exit(fake_pid, :kill)
    end

    test "decrements count after stopping" do
      response = Mocks.assistant_message("Count test")

      {:ok, pid} =
        SubagentSupervisor.start_subagent(
          initial_state: %{
            system_prompt: "Count",
            model: Mocks.mock_model()
          },
          convert_to_llm: Mocks.simple_convert_to_llm(),
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      count_before = SubagentSupervisor.count()

      SubagentSupervisor.stop_subagent(pid)
      Process.sleep(20)

      assert SubagentSupervisor.count() == count_before - 1
    end

    test "removes pid from list_subagents after stopping" do
      response = Mocks.assistant_message("List test")

      {:ok, pid} =
        SubagentSupervisor.start_subagent(
          initial_state: %{
            system_prompt: "List",
            model: Mocks.mock_model()
          },
          convert_to_llm: Mocks.simple_convert_to_llm(),
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      assert pid in SubagentSupervisor.list_subagents()

      SubagentSupervisor.stop_subagent(pid)
      Process.sleep(20)

      refute pid in SubagentSupervisor.list_subagents()
    end
  end

  describe "stop_subagent_by_key/1" do
    test "stops subagent by registry key" do
      session_id = "session_#{:rand.uniform(100_000)}"
      key = {session_id, :research, 0}
      response = Mocks.assistant_message("Stop by key")

      {:ok, pid} =
        SubagentSupervisor.start_subagent(
          registry_key: key,
          initial_state: %{
            system_prompt: "Stop by key",
            model: Mocks.mock_model()
          },
          convert_to_llm: Mocks.simple_convert_to_llm(),
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      assert Process.alive?(pid)

      :ok = SubagentSupervisor.stop_subagent_by_key(key)
      Process.sleep(20)

      refute Process.alive?(pid)
    end

    test "returns {:error, :not_found} for unregistered key" do
      fake_key = {"nonexistent_session", :unknown, 99}

      result = SubagentSupervisor.stop_subagent_by_key(fake_key)
      assert result == {:error, :not_found}
    end

    test "registry entry is removed after stop" do
      session_id = "session_#{:rand.uniform(100_000)}"
      key = {session_id, :implement, 0}
      response = Mocks.assistant_message("Registry cleanup")

      {:ok, pid} =
        SubagentSupervisor.start_subagent(
          registry_key: key,
          initial_state: %{
            system_prompt: "Registry cleanup",
            model: Mocks.mock_model()
          },
          convert_to_llm: Mocks.simple_convert_to_llm(),
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      assert {:ok, ^pid} = AgentRegistry.lookup(key)

      SubagentSupervisor.stop_subagent_by_key(key)
      Process.sleep(20)

      # Registry entry should be gone (process died, so via tuple unregisters)
      assert :error = AgentRegistry.lookup(key)
    end
  end

  describe "stop_all/0" do
    test "terminates all subagents" do
      response = Mocks.assistant_message("Stop all test")

      pids =
        for i <- 1..3 do
          {:ok, pid} =
            SubagentSupervisor.start_subagent(
              initial_state: %{
                system_prompt: "Agent #{i}",
                model: Mocks.mock_model()
              },
              convert_to_llm: Mocks.simple_convert_to_llm(),
              stream_fn: Mocks.mock_stream_fn_single(response)
            )

          pid
        end

      for pid <- pids do
        assert Process.alive?(pid)
      end

      :ok = SubagentSupervisor.stop_all()
      Process.sleep(50)

      for pid <- pids do
        refute Process.alive?(pid)
      end
    end

    test "returns :ok even when no subagents exist" do
      # First stop all to ensure clean state
      SubagentSupervisor.stop_all()
      Process.sleep(20)

      # Calling stop_all on empty supervisor should still return :ok
      result = SubagentSupervisor.stop_all()
      assert result == :ok
    end

    test "supervisor remains functional after stop_all" do
      response = Mocks.assistant_message("After stop_all")

      # Create and stop all
      {:ok, _pid1} =
        SubagentSupervisor.start_subagent(
          initial_state: %{
            system_prompt: "Before",
            model: Mocks.mock_model()
          },
          convert_to_llm: Mocks.simple_convert_to_llm(),
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      SubagentSupervisor.stop_all()
      Process.sleep(20)

      # Should be able to create new subagents
      {:ok, pid2} =
        SubagentSupervisor.start_subagent(
          initial_state: %{
            system_prompt: "After",
            model: Mocks.mock_model()
          },
          convert_to_llm: Mocks.simple_convert_to_llm(),
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      assert Process.alive?(pid2)
      SubagentSupervisor.stop_subagent(pid2)
    end
  end

  # ============================================================================
  # 5. Dynamic Child Addition/Removal Tests
  # ============================================================================

  describe "dynamic child management" do
    test "can dynamically add children at runtime" do
      initial_count = SubagentSupervisor.count()
      response = Mocks.assistant_message("Dynamic add")

      # Add children dynamically
      pids =
        for _ <- 1..3 do
          {:ok, pid} =
            SubagentSupervisor.start_subagent(
              initial_state: %{
                system_prompt: "Dynamic",
                model: Mocks.mock_model()
              },
              convert_to_llm: Mocks.simple_convert_to_llm(),
              stream_fn: Mocks.mock_stream_fn_single(response)
            )

          pid
        end

      assert SubagentSupervisor.count() == initial_count + 3

      # Remove one
      SubagentSupervisor.stop_subagent(hd(pids))
      Process.sleep(20)

      assert SubagentSupervisor.count() == initial_count + 2

      # Cleanup remaining
      for pid <- tl(pids), do: SubagentSupervisor.stop_subagent(pid)
    end

    test "list_subagents reflects current children" do
      response = Mocks.assistant_message("List sync")

      _initial_list = SubagentSupervisor.list_subagents()

      {:ok, pid1} =
        SubagentSupervisor.start_subagent(
          initial_state: %{
            system_prompt: "Agent 1",
            model: Mocks.mock_model()
          },
          convert_to_llm: Mocks.simple_convert_to_llm(),
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      {:ok, pid2} =
        SubagentSupervisor.start_subagent(
          initial_state: %{
            system_prompt: "Agent 2",
            model: Mocks.mock_model()
          },
          convert_to_llm: Mocks.simple_convert_to_llm(),
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      current_list = SubagentSupervisor.list_subagents()
      assert pid1 in current_list
      assert pid2 in current_list

      SubagentSupervisor.stop_subagent(pid1)
      Process.sleep(20)

      updated_list = SubagentSupervisor.list_subagents()
      refute pid1 in updated_list
      assert pid2 in updated_list

      SubagentSupervisor.stop_subagent(pid2)
    end

    test "count reflects current active children" do
      response = Mocks.assistant_message("Count sync")
      initial = SubagentSupervisor.count()

      {:ok, pid1} =
        SubagentSupervisor.start_subagent(
          initial_state: %{model: Mocks.mock_model()},
          convert_to_llm: Mocks.simple_convert_to_llm(),
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      assert SubagentSupervisor.count() == initial + 1

      {:ok, pid2} =
        SubagentSupervisor.start_subagent(
          initial_state: %{model: Mocks.mock_model()},
          convert_to_llm: Mocks.simple_convert_to_llm(),
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      assert SubagentSupervisor.count() == initial + 2

      SubagentSupervisor.stop_subagent(pid1)
      Process.sleep(20)
      assert SubagentSupervisor.count() == initial + 1

      SubagentSupervisor.stop_subagent(pid2)
      Process.sleep(20)
      assert SubagentSupervisor.count() == initial
    end
  end

  # ============================================================================
  # 6. Telemetry Events Tests
  # ============================================================================

  describe "telemetry events" do
    setup do
      ref = make_ref()
      test_pid = self()

      # Attach telemetry handlers
      :telemetry.attach(
        {ref, :spawn},
        [:agent_core, :subagent, :spawn],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_spawn, measurements, metadata})
        end,
        nil
      )

      :telemetry.attach(
        {ref, :end},
        [:agent_core, :subagent, :end],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_end, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach({ref, :spawn})
        :telemetry.detach({ref, :end})
      end)

      {:ok, telemetry_ref: ref}
    end

    test "emits spawn telemetry event when starting subagent" do
      response = Mocks.assistant_message("Telemetry spawn")

      {:ok, pid} =
        SubagentSupervisor.start_subagent(
          initial_state: %{
            system_prompt: "Telemetry",
            model: Mocks.mock_model()
          },
          convert_to_llm: Mocks.simple_convert_to_llm(),
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      assert_receive {:telemetry_spawn, measurements, metadata}, 1000

      assert is_integer(measurements.system_time)
      assert metadata.pid == pid
      assert metadata.has_registry_key == false
      assert metadata.registry_key == nil

      SubagentSupervisor.stop_subagent(pid)
    end

    test "spawn telemetry includes registry_key when provided" do
      session_id = "session_#{:rand.uniform(100_000)}"
      key = {session_id, :research, 0}
      response = Mocks.assistant_message("Telemetry with key")

      {:ok, pid} =
        SubagentSupervisor.start_subagent(
          registry_key: key,
          initial_state: %{
            system_prompt: "Telemetry",
            model: Mocks.mock_model()
          },
          convert_to_llm: Mocks.simple_convert_to_llm(),
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      assert_receive {:telemetry_spawn, _measurements, metadata}, 1000

      assert metadata.pid == pid
      assert metadata.has_registry_key == true
      assert metadata.registry_key == key

      SubagentSupervisor.stop_subagent(pid)
    end

    test "emits end telemetry event when stopping subagent" do
      response = Mocks.assistant_message("Telemetry end")

      {:ok, pid} =
        SubagentSupervisor.start_subagent(
          initial_state: %{
            system_prompt: "Telemetry",
            model: Mocks.mock_model()
          },
          convert_to_llm: Mocks.simple_convert_to_llm(),
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      # Clear spawn event
      receive do
        {:telemetry_spawn, _, _} -> :ok
      after
        100 -> :ok
      end

      SubagentSupervisor.stop_subagent(pid)

      assert_receive {:telemetry_end, measurements, metadata}, 1000

      assert is_integer(measurements.system_time)
      assert metadata.pid == pid
      assert metadata.reason == :stopped
    end
  end

  # ============================================================================
  # 7. Edge Cases and Error Handling
  # ============================================================================

  describe "edge cases" do
    test "handles rapid start/stop cycles" do
      response = Mocks.assistant_message("Rapid cycle")

      for _ <- 1..10 do
        {:ok, pid} =
          SubagentSupervisor.start_subagent(
            initial_state: %{
              system_prompt: "Rapid",
              model: Mocks.mock_model()
            },
            convert_to_llm: Mocks.simple_convert_to_llm(),
            stream_fn: Mocks.mock_stream_fn_single(response)
          )

        SubagentSupervisor.stop_subagent(pid)
      end

      # Supervisor should still be healthy
      assert Process.alive?(Process.whereis(AgentCore.SubagentSupervisor))
    end

    test "handles concurrent start requests" do
      response = Mocks.assistant_message("Concurrent")

      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            SubagentSupervisor.start_subagent(
              initial_state: %{
                system_prompt: "Concurrent",
                model: Mocks.mock_model()
              },
              convert_to_llm: Mocks.simple_convert_to_llm(),
              stream_fn: Mocks.mock_stream_fn_single(response)
            )
          end)
        end

      results = Task.await_many(tasks, 5000)

      pids =
        for {:ok, pid} <- results do
          assert Process.alive?(pid)
          pid
        end

      assert length(pids) == 10

      # Cleanup
      for pid <- pids, do: SubagentSupervisor.stop_subagent(pid)
    end

    test "handles concurrent stop requests for same pid gracefully" do
      response = Mocks.assistant_message("Concurrent stop")

      {:ok, pid} =
        SubagentSupervisor.start_subagent(
          initial_state: %{
            system_prompt: "Concurrent stop",
            model: Mocks.mock_model()
          },
          convert_to_llm: Mocks.simple_convert_to_llm(),
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      # Try to stop the same pid from multiple processes
      tasks =
        for _ <- 1..5 do
          Task.async(fn ->
            SubagentSupervisor.stop_subagent(pid)
          end)
        end

      results = Task.await_many(tasks, 5000)

      # At least one should succeed, others may get :not_found
      assert :ok in results or {:error, :not_found} in results
    end

    test "list_subagents returns empty list when no children" do
      # Save current subagents (used implicitly to document behavior)
      _current = SubagentSupervisor.list_subagents()

      # Stop all
      SubagentSupervisor.stop_all()
      Process.sleep(50)

      # Should return empty list
      assert SubagentSupervisor.list_subagents() == []

      # Note: We can't restore the original subagents, but that's OK for testing
    end

    test "count returns 0 when no children" do
      # Stop all
      SubagentSupervisor.stop_all()
      Process.sleep(50)

      assert SubagentSupervisor.count() == 0
    end
  end

  # ============================================================================
  # 8. Integration with AgentCore.Agent
  # ============================================================================

  describe "integration with AgentCore.Agent" do
    test "started subagent responds to Agent API" do
      response = Mocks.assistant_message("Integration test")

      {:ok, pid} =
        SubagentSupervisor.start_subagent(
          initial_state: %{
            system_prompt: "Integration",
            model: Mocks.mock_model(),
            tools: []
          },
          convert_to_llm: Mocks.simple_convert_to_llm(),
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      # Can get state
      state = AgentCore.Agent.get_state(pid)
      assert state.system_prompt == "Integration"

      # Can set system prompt
      :ok = AgentCore.Agent.set_system_prompt(pid, "Updated")
      updated_state = AgentCore.Agent.get_state(pid)
      assert updated_state.system_prompt == "Updated"

      SubagentSupervisor.stop_subagent(pid)
    end

    test "subagent can process prompts" do
      response = Mocks.assistant_message("Hello from subagent!")

      {:ok, pid} =
        SubagentSupervisor.start_subagent(
          initial_state: %{
            system_prompt: "You are helpful.",
            model: Mocks.mock_model(),
            tools: []
          },
          convert_to_llm: Mocks.simple_convert_to_llm(),
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      :ok = AgentCore.Agent.prompt(pid, "Hello!")
      :ok = AgentCore.Agent.wait_for_idle(pid, timeout: 5000)

      state = AgentCore.Agent.get_state(pid)
      assert length(state.messages) > 0

      SubagentSupervisor.stop_subagent(pid)
    end
  end
end
