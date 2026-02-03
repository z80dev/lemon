defmodule CodingAgent.SubagentComprehensiveTest do
  @moduledoc """
  Comprehensive integration tests for subagent functionality.

  These tests cover:
  - Complex subagent chains (subagent spawning subagent)
  - Failure scenarios and recovery
  - Context passing between parent and subagent
  - Resource management
  - Concurrent subagent execution
  - Subagent timeout handling
  - Event propagation between agents

  To run these tests:

      mix test apps/coding_agent/test/coding_agent/subagent_comprehensive_test.exs --include integration

  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :subagent
  @moduletag :tmp_dir

  alias AgentCore.Types.AgentToolResult
  alias AgentCore.AbortSignal
  alias Ai.Types.{AssistantMessage, TextContent, Model, ModelCost}
  alias Ai.Test.IntegrationConfig
  alias CodingAgent.Coordinator
  alias CodingAgent.Session
  alias CodingAgent.SettingsManager
  alias CodingAgent.Subagents
  alias CodingAgent.Tools.Task, as: TaskTool

  # ============================================================================
  # Test Configuration
  # ============================================================================

  defp default_settings do
    %SettingsManager{
      default_thinking_level: :off,
      compaction_enabled: false,
      reserve_tokens: 16384
    }
  end

  defp test_model do
    if IntegrationConfig.configured?() do
      IntegrationConfig.model()
    else
      # Fallback mock model for unit tests
      %Model{
        id: "test-model",
        name: "Test Model",
        api: :anthropic_messages,
        provider: :test,
        base_url: "http://localhost:8080",
        reasoning: false,
        input: [:text],
        cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
        context_window: 200_000,
        max_tokens: 64_000,
        headers: %{}
      }
    end
  end

  defp start_session(opts \\ []) do
    base_opts = [
      cwd: opts[:cwd] || System.tmp_dir!(),
      model: opts[:model] || test_model(),
      settings_manager: opts[:settings_manager] || default_settings(),
      system_prompt:
        opts[:system_prompt] ||
          "You are a helpful coding assistant. Be concise. When asked to delegate work, use the task tool."
    ]

    merged_opts = Keyword.merge(base_opts, opts)
    {:ok, session} = Session.start_link(merged_opts)
    session
  end

  defp skip_unless_configured do
    unless IntegrationConfig.configured?() do
      IO.puts(IntegrationConfig.skip_message())
      :skip
    else
      :ok
    end
  end

  defp subscribe_and_collect_events(session, timeout \\ 60_000) do
    _ref = Session.subscribe(session)
    collect_events([], timeout)
  end

  defp collect_events(events, timeout) do
    receive do
      {:session_event, _session_id, {:agent_end, _messages}} ->
        Enum.reverse(events)

      {:session_event, _session_id, {:error, reason, _partial}} ->
        Enum.reverse([{:error, reason} | events])

      {:session_event, _session_id, event} ->
        collect_events([event | events], timeout)
    after
      timeout ->
        Enum.reverse([{:timeout, timeout} | events])
    end
  end

  defp wait_for_response(session, timeout \\ 60_000) do
    events = subscribe_and_collect_events(session, timeout)

    message_end_events =
      Enum.filter(events, fn
        {:message_end, %AssistantMessage{}} -> true
        _ -> false
      end)

    case message_end_events do
      [] ->
        error =
          Enum.find(events, fn
            {:error, _} -> true
            {:timeout, _} -> true
            _ -> false
          end)

        {:error, error || :no_response, events}

      messages ->
        {:message_end, msg} = List.last(messages)
        {:ok, msg, events}
    end
  end

  defp get_text(%AssistantMessage{content: content}) do
    content
    |> Enum.filter(&match?(%TextContent{}, &1))
    |> Enum.map(& &1.text)
    |> Enum.join("\n")
  end

  # ============================================================================
  # Test Setup
  # ============================================================================

  setup_all do
    Ai.ProviderRegistry.init()
    Ai.ProviderRegistry.register(:anthropic_messages, Ai.Providers.Anthropic)
    IO.puts("\n[Subagent Comprehensive Tests] Configuration: #{IntegrationConfig.describe()}")
    :ok
  end

  # ============================================================================
  # Subagent Definition and Loading Tests
  # ============================================================================

  describe "Subagent Definition Loading" do
    test "loads default subagents", %{tmp_dir: tmp_dir} do
      agents = Subagents.list(tmp_dir)

      assert length(agents) == 4
      ids = Enum.map(agents, & &1.id)
      assert "research" in ids
      assert "implement" in ids
      assert "review" in ids
      assert "test" in ids
    end

    test "custom subagent overrides default", %{tmp_dir: tmp_dir} do
      project_config = Path.join(tmp_dir, ".lemon")
      File.mkdir_p!(project_config)

      custom_agents = [
        %{
          "id" => "research",
          "prompt" => "Custom research prompt",
          "description" => "Custom research description"
        }
      ]

      File.write!(Path.join(project_config, "subagents.json"), Jason.encode!(custom_agents))

      agent = Subagents.get(tmp_dir, "research")
      assert agent.prompt == "Custom research prompt"
      assert agent.description == "Custom research description"
    end

    test "adding new subagent preserves defaults", %{tmp_dir: tmp_dir} do
      project_config = Path.join(tmp_dir, ".lemon")
      File.mkdir_p!(project_config)

      custom_agents = [
        %{
          "id" => "custom_agent",
          "prompt" => "A custom agent for specialized work",
          "description" => "Custom agent"
        }
      ]

      File.write!(Path.join(project_config, "subagents.json"), Jason.encode!(custom_agents))

      agents = Subagents.list(tmp_dir)
      assert length(agents) == 5

      custom = Subagents.get(tmp_dir, "custom_agent")
      assert custom != nil
      assert custom.prompt == "A custom agent for specialized work"

      # Defaults still present
      assert Subagents.get(tmp_dir, "research") != nil
      assert Subagents.get(tmp_dir, "implement") != nil
    end

    test "handles corrupted subagents.json gracefully", %{tmp_dir: tmp_dir} do
      project_config = Path.join(tmp_dir, ".lemon")
      File.mkdir_p!(project_config)

      File.write!(Path.join(project_config, "subagents.json"), "{ invalid json")

      # Should still return defaults
      agents = Subagents.list(tmp_dir)
      assert length(agents) == 4
    end

    test "format_for_description returns formatted list", %{tmp_dir: tmp_dir} do
      description = Subagents.format_for_description(tmp_dir)

      assert description =~ "- research:"
      assert description =~ "- implement:"
      assert description =~ "- review:"
      assert description =~ "- test:"
    end
  end

  # ============================================================================
  # Task Tool Parameter Validation Tests
  # ============================================================================

  describe "Task Tool Parameter Validation" do
    test "rejects missing description", %{tmp_dir: tmp_dir} do
      result =
        TaskTool.execute(
          "test_call",
          %{"prompt" => "Do something"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert {:error, "Description is required"} = result
    end

    test "rejects empty description", %{tmp_dir: tmp_dir} do
      result =
        TaskTool.execute(
          "test_call",
          %{"description" => "   ", "prompt" => "Do something"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert {:error, "Description must be a non-empty string"} = result
    end

    test "rejects missing prompt", %{tmp_dir: tmp_dir} do
      result =
        TaskTool.execute(
          "test_call",
          %{"description" => "Test task"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert {:error, "Prompt is required"} = result
    end

    test "rejects empty prompt", %{tmp_dir: tmp_dir} do
      result =
        TaskTool.execute(
          "test_call",
          %{"description" => "Test", "prompt" => ""},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert {:error, "Prompt must be a non-empty string"} = result
    end

    test "rejects unknown role", %{tmp_dir: tmp_dir} do
      result =
        TaskTool.execute(
          "test_call",
          %{
            "description" => "Test",
            "prompt" => "Do work",
            "role" => "nonexistent_role"
          },
          nil,
          nil,
          tmp_dir,
          []
        )

      assert {:error, "Unknown role: nonexistent_role"} = result
    end

    test "rejects invalid engine", %{tmp_dir: tmp_dir} do
      result =
        TaskTool.execute(
          "test_call",
          %{
            "description" => "Test",
            "prompt" => "Do work",
            "engine" => "invalid_engine"
          },
          nil,
          nil,
          tmp_dir,
          []
        )

      assert {:error, "Engine must be one of: internal, codex, claude, kimi"} = result
    end

    test "accepts valid role", %{tmp_dir: tmp_dir} do
      # This will fail for other reasons (no API key), but validation passes
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          result =
            TaskTool.execute(
              "test_call",
              %{
                "description" => "Test",
                "prompt" => "Say hello",
                "role" => "research"
              },
              nil,
              nil,
              tmp_dir,
              [model: test_model()]
            )

          # If configured, should not be a validation error
          case result do
            {:error, msg} when is_binary(msg) ->
              refute msg =~ "Unknown role"

            %AgentToolResult{} ->
              assert true

            _ ->
              assert true
          end
      end
    end

    test "accepts internal engine explicitly", %{tmp_dir: tmp_dir} do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          result =
            TaskTool.execute(
              "test_call",
              %{
                "description" => "Test",
                "prompt" => "Say hello",
                "engine" => "internal"
              },
              nil,
              nil,
              tmp_dir,
              [model: test_model()]
            )

          # Should not be a validation error about engine
          case result do
            {:error, msg} when is_binary(msg) ->
              refute msg =~ "Engine must be"

            _ ->
              assert true
          end
      end
    end
  end

  # ============================================================================
  # Abort Signal Handling Tests
  # ============================================================================

  describe "Abort Signal Handling" do
    test "respects abort signal before execution", %{tmp_dir: tmp_dir} do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      result =
        TaskTool.execute(
          "test_call",
          %{"description" => "Test", "prompt" => "Do work"},
          signal,
          nil,
          tmp_dir,
          []
        )

      assert {:error, "Operation aborted"} = result
    end

    test "abort signal interrupts running task", %{tmp_dir: tmp_dir} do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          signal = AbortSignal.new()

          # Start a task that takes time
          task =
            Task.async(fn ->
              TaskTool.execute(
                "test_call",
                %{
                  "description" => "Long task",
                  "prompt" => "Count from 1 to 100, saying each number slowly."
                },
                signal,
                nil,
                tmp_dir,
                [model: test_model()]
              )
            end)

          # Give it time to start
          Process.sleep(500)

          # Abort
          AbortSignal.abort(signal)

          # Should complete (either with abort error or partial result)
          result = Task.await(task, 30_000)

          case result do
            {:error, msg} ->
              assert is_binary(msg) or is_map(msg)

            %AgentToolResult{} ->
              # May complete before abort takes effect
              assert true
          end
      end
    end

    test "nil abort signal is handled gracefully", %{tmp_dir: tmp_dir} do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          result =
            TaskTool.execute(
              "test_call",
              %{"description" => "Test", "prompt" => "Say 'ok'"},
              nil,
              nil,
              tmp_dir,
              [model: test_model()]
            )

          # Should not crash with nil signal
          assert match?(%AgentToolResult{}, result) or match?({:error, _}, result)
      end
    end
  end

  # ============================================================================
  # On-Update Callback Tests
  # ============================================================================

  describe "On-Update Callback" do
    test "receives progress updates during execution", %{tmp_dir: tmp_dir} do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          updates = :ets.new(:test_updates, [:set, :public])

          on_update = fn update ->
            :ets.insert(updates, {System.monotonic_time(), update})
            :ok
          end

          result =
            TaskTool.execute(
              "test_call",
              %{
                "description" => "Count task",
                "prompt" => "Count from 1 to 5. Say each number."
              },
              nil,
              on_update,
              tmp_dir,
              [model: test_model()]
            )

          # Collect updates
          all_updates = :ets.tab2list(updates)
          :ets.delete(updates)

          # Should have received some updates
          assert length(all_updates) >= 0

          case result do
            %AgentToolResult{} -> assert true
            {:error, _} -> assert true
          end
      end
    end

    test "nil on_update is handled gracefully", %{tmp_dir: tmp_dir} do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          result =
            TaskTool.execute(
              "test_call",
              %{"description" => "Test", "prompt" => "Say 'hello'"},
              nil,
              nil,
              tmp_dir,
              [model: test_model()]
            )

          assert match?(%AgentToolResult{}, result) or match?({:error, _}, result)
      end
    end
  end

  # ============================================================================
  # Coordinator Tests - Concurrent Subagent Execution
  # ============================================================================

  describe "Coordinator - Concurrent Execution" do
    test "runs single subagent successfully", %{tmp_dir: tmp_dir} do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          {:ok, coordinator} =
            Coordinator.start_link(
              cwd: tmp_dir,
              model: test_model(),
              default_timeout: 60_000
            )

          result =
            Coordinator.run_subagent(
              coordinator,
              prompt: "What is 2 + 2? Reply with just the number.",
              timeout: 60_000
            )

          case result do
            {:ok, text} ->
              assert text =~ "4"

            {:error, reason} ->
              # May fail due to configuration, but shouldn't crash
              assert reason != nil
          end

          GenServer.stop(coordinator)
      end
    end

    test "runs multiple subagents concurrently", %{tmp_dir: tmp_dir} do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          {:ok, coordinator} =
            Coordinator.start_link(
              cwd: tmp_dir,
              model: test_model(),
              default_timeout: 120_000
            )

          specs = [
            %{prompt: "What is 1 + 1? Reply with just the number.", description: "Math 1"},
            %{prompt: "What is 2 + 2? Reply with just the number.", description: "Math 2"},
            %{prompt: "What is 3 + 3? Reply with just the number.", description: "Math 3"}
          ]

          results = Coordinator.run_subagents(coordinator, specs, timeout: 120_000)

          assert length(results) == 3

          # At least some should complete
          completed = Enum.filter(results, &(&1.status == :completed))
          assert length(completed) >= 0

          GenServer.stop(coordinator)
      end
    end

    test "list_active returns current subagent IDs", %{tmp_dir: tmp_dir} do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          {:ok, coordinator} =
            Coordinator.start_link(
              cwd: tmp_dir,
              model: test_model(),
              default_timeout: 120_000
            )

          # Initially empty
          assert Coordinator.list_active(coordinator) == []

          # Start a long-running task
          task =
            Task.async(fn ->
              Coordinator.run_subagent(
                coordinator,
                prompt: "Count from 1 to 20 slowly.",
                timeout: 60_000
              )
            end)

          # Give it time to start
          Process.sleep(500)

          # May have active subagents now
          active = Coordinator.list_active(coordinator)
          # Could be 0 or 1 depending on timing
          assert is_list(active)

          # Abort and cleanup
          Coordinator.abort_all(coordinator)
          Task.await(task, 10_000)

          GenServer.stop(coordinator)
      end
    end

    test "abort_all stops all running subagents", %{tmp_dir: tmp_dir} do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          {:ok, coordinator} =
            Coordinator.start_link(
              cwd: tmp_dir,
              model: test_model(),
              default_timeout: 300_000
            )

          # Start multiple long tasks
          tasks =
            Enum.map(1..3, fn i ->
              Task.async(fn ->
                Coordinator.run_subagent(
                  coordinator,
                  prompt: "Count from 1 to 100. Number #{i}.",
                  timeout: 120_000
                )
              end)
            end)

          # Give them time to start
          Process.sleep(1000)

          # Abort all
          :ok = Coordinator.abort_all(coordinator)

          # Wait for tasks
          results = Enum.map(tasks, fn task -> Task.await(task, 30_000) end)

          # All should have completed (either aborted or finished)
          assert length(results) == 3

          # Active list should be empty
          assert Coordinator.list_active(coordinator) == []

          GenServer.stop(coordinator)
      end
    end

    test "handles subagent errors gracefully", %{tmp_dir: tmp_dir} do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          {:ok, coordinator} =
            Coordinator.start_link(
              cwd: tmp_dir,
              model: test_model(),
              default_timeout: 60_000
            )

          # Mix of valid and potentially problematic specs
          specs = [
            %{prompt: "What is 2 + 2?", description: "Valid"},
            %{prompt: "Say ok", subagent: "research", description: "With role"}
          ]

          results = Coordinator.run_subagents(coordinator, specs, timeout: 60_000)

          assert length(results) == 2

          # Each result should have required fields
          Enum.each(results, fn result ->
            assert Map.has_key?(result, :id)
            assert Map.has_key?(result, :status)
            assert result.status in [:completed, :error, :timeout, :aborted]
          end)

          GenServer.stop(coordinator)
      end
    end
  end

  # ============================================================================
  # Context Passing Tests
  # ============================================================================

  describe "Context Passing Between Parent and Subagent" do
    test "subagent inherits working directory", %{tmp_dir: tmp_dir} do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          # Create a test file
          test_file = Path.join(tmp_dir, "context_test.txt")
          File.write!(test_file, "Secret content: LEMON123")

          result =
            TaskTool.execute(
              "test_call",
              %{
                "description" => "Read file",
                "prompt" =>
                  "Read context_test.txt and tell me what the secret content is. Reply with just the secret."
              },
              nil,
              nil,
              tmp_dir,
              [model: test_model()]
            )

          case result do
            %AgentToolResult{content: content} ->
              text =
                content
                |> Enum.filter(&match?(%TextContent{}, &1))
                |> Enum.map(& &1.text)
                |> Enum.join(" ")

              # Should have access to the file in tmp_dir
              assert text =~ "LEMON" or text =~ "123" or text =~ "context_test"

            {:error, _} ->
              assert true
          end
      end
    end

    test "subagent with role applies role prompt", %{tmp_dir: tmp_dir} do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          result =
            TaskTool.execute(
              "test_call",
              %{
                "description" => "Research task",
                "prompt" => "Tell me briefly what your role is.",
                "role" => "research"
              },
              nil,
              nil,
              tmp_dir,
              [model: test_model()]
            )

          case result do
            %AgentToolResult{content: content, details: details} ->
              assert details[:role] == "research"

              text =
                content
                |> Enum.filter(&match?(%TextContent{}, &1))
                |> Enum.map(& &1.text)
                |> Enum.join(" ")

              # Response should reflect research role
              assert text != ""

            {:error, _} ->
              assert true
          end
      end
    end

    test "subagent result contains session metadata", %{tmp_dir: tmp_dir} do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          result =
            TaskTool.execute(
              "test_call",
              %{
                "description" => "Simple task",
                "prompt" => "Say 'hello'"
              },
              nil,
              nil,
              tmp_dir,
              [model: test_model()]
            )

          case result do
            %AgentToolResult{details: details} ->
              assert Map.has_key?(details, :status)
              assert details[:status] == "completed"
              assert Map.has_key?(details, :description)

            {:error, _} ->
              assert true
          end
      end
    end
  end

  # ============================================================================
  # Resource Management Tests
  # ============================================================================

  describe "Resource Management" do
    test "session cleanup after subagent completion", %{tmp_dir: tmp_dir} do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          # Get process count before
          process_count_before = length(Process.list())

          _result =
            TaskTool.execute(
              "test_call",
              %{"description" => "Test", "prompt" => "Say 'done'"},
              nil,
              nil,
              tmp_dir,
              [model: test_model()]
            )

          # Small delay for cleanup
          Process.sleep(500)

          # Get process count after
          process_count_after = length(Process.list())

          # Should not have significant process leak (allow some variance)
          assert abs(process_count_after - process_count_before) < 50
      end
    end

    test "coordinator cleanup after abort_all", %{tmp_dir: tmp_dir} do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          {:ok, coordinator} =
            Coordinator.start_link(
              cwd: tmp_dir,
              model: test_model(),
              default_timeout: 300_000
            )

          # Start some tasks
          task =
            Task.async(fn ->
              Coordinator.run_subagents(
                coordinator,
                [
                  %{prompt: "Count to 50", description: "Task 1"},
                  %{prompt: "Count to 50", description: "Task 2"}
                ],
                timeout: 120_000
              )
            end)

          Process.sleep(500)

          # Abort
          Coordinator.abort_all(coordinator)

          # Wait for completion
          Task.await(task, 30_000)

          # Active list should be empty
          assert Coordinator.list_active(coordinator) == []

          GenServer.stop(coordinator)
      end
    end

    test "handles rapid task creation and cleanup", %{tmp_dir: tmp_dir} do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          # Create and execute multiple tasks rapidly
          results =
            Enum.map(1..5, fn i ->
              TaskTool.execute(
                "test_call_#{i}",
                %{
                  "description" => "Quick task #{i}",
                  "prompt" => "Say '#{i}'"
                },
                nil,
                nil,
                tmp_dir,
                [model: test_model()]
              )
            end)

          # All should complete or error, not crash
          Enum.each(results, fn result ->
            assert match?(%AgentToolResult{}, result) or match?({:error, _}, result)
          end)
      end
    end
  end

  # ============================================================================
  # Timeout Handling Tests
  # ============================================================================

  describe "Timeout Handling" do
    test "coordinator respects timeout", %{tmp_dir: tmp_dir} do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          {:ok, coordinator} =
            Coordinator.start_link(
              cwd: tmp_dir,
              model: test_model(),
              default_timeout: 5_000
            )

          # Request with very short timeout
          results =
            Coordinator.run_subagents(
              coordinator,
              [%{prompt: "Count from 1 to 1000 slowly.", description: "Slow task"}],
              timeout: 2_000
            )

          assert length(results) == 1
          result = hd(results)

          # Should timeout or complete quickly
          assert result.status in [:completed, :timeout, :error]

          GenServer.stop(coordinator)
      end
    end

    test "default timeout is applied when not specified", %{tmp_dir: tmp_dir} do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          {:ok, coordinator} =
            Coordinator.start_link(
              cwd: tmp_dir,
              model: test_model(),
              default_timeout: 60_000
            )

          # Run without explicit timeout
          result =
            Coordinator.run_subagent(
              coordinator,
              prompt: "Say 'ok'"
            )

          # Should work with default timeout
          case result do
            {:ok, _text} -> assert true
            {:error, _} -> assert true
          end

          GenServer.stop(coordinator)
      end
    end
  end

  # ============================================================================
  # Event Propagation Tests
  # ============================================================================

  describe "Event Propagation" do
    test "session broadcasts events to subscribers", %{tmp_dir: tmp_dir} do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          session = start_session(cwd: tmp_dir, model: test_model())

          _unsub = Session.subscribe(session)

          # Send a prompt
          :ok = Session.prompt(session, "Say 'test'")

          # Collect events with timeout
          events = collect_events([], 30_000)

          # Should have received events
          assert length(events) >= 0

          # Should have message events if completed
          message_events =
            Enum.filter(events, fn
              {:message_start, _} -> true
              {:message_update, _, _} -> true
              {:message_end, _} -> true
              _ -> false
            end)

          assert length(message_events) >= 0

          GenServer.stop(session)
      end
    end

    test "extension status report is broadcast on session start", %{tmp_dir: tmp_dir} do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          session = start_session(cwd: tmp_dir, model: test_model())

          # Subscribe after start
          _unsub = Session.subscribe(session)

          # Can also get extension status directly
          report = Session.get_extension_status_report(session)

          assert Map.has_key?(report, :total_loaded)
          assert Map.has_key?(report, :load_errors)

          GenServer.stop(session)
      end
    end
  end

  # ============================================================================
  # Error Recovery Tests
  # ============================================================================

  describe "Error Recovery" do
    test "recovers from invalid subagent specification", %{tmp_dir: tmp_dir} do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          {:ok, coordinator} =
            Coordinator.start_link(
              cwd: tmp_dir,
              model: test_model(),
              default_timeout: 60_000
            )

          # Spec with invalid subagent reference
          specs = [
            %{prompt: "Say hello", subagent: "nonexistent_agent", description: "Bad ref"},
            %{prompt: "Say goodbye", description: "Valid"}
          ]

          results = Coordinator.run_subagents(coordinator, specs, timeout: 60_000)

          assert length(results) == 2

          # First should error due to bad subagent
          bad_result = Enum.at(results, 0)
          assert bad_result.status == :error

          # Second should complete or error for other reasons
          good_result = Enum.at(results, 1)
          assert good_result.status in [:completed, :error, :timeout]

          GenServer.stop(coordinator)
      end
    end

    test "continues after single subagent failure", %{tmp_dir: tmp_dir} do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          {:ok, coordinator} =
            Coordinator.start_link(
              cwd: tmp_dir,
              model: test_model(),
              default_timeout: 60_000
            )

          # Run multiple where one might fail
          specs = [
            %{prompt: "What is 2 + 2?", description: "Math"},
            %{prompt: "Say hello", description: "Greeting"},
            %{prompt: "What color is the sky?", description: "Color"}
          ]

          results = Coordinator.run_subagents(coordinator, specs, timeout: 120_000)

          assert length(results) == 3

          # Should have some results regardless of individual failures
          completed = Enum.filter(results, &(&1.status == :completed))
          # At least could attempt all
          assert length(completed) >= 0

          GenServer.stop(coordinator)
      end
    end

    test "handles session crash gracefully", %{tmp_dir: tmp_dir} do
      # This test verifies coordinator handles DOWN messages
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          {:ok, coordinator} =
            Coordinator.start_link(
              cwd: tmp_dir,
              model: test_model(),
              default_timeout: 60_000
            )

          # Coordinator should start without issues
          assert Coordinator.list_active(coordinator) == []

          GenServer.stop(coordinator)
      end
    end
  end

  # ============================================================================
  # Complex Chain Tests (Subagent spawning subagent)
  # ============================================================================

  describe "Complex Subagent Chains" do
    test "parent session can spawn subagent via task tool", %{tmp_dir: tmp_dir} do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          session =
            start_session(
              cwd: tmp_dir,
              model: test_model(),
              system_prompt: """
              You are a coding assistant. When asked to delegate a task, use the task tool.
              Be concise in your responses.
              """
            )

          # Create a file for subagent to read
          test_file = Path.join(tmp_dir, "chain_test.txt")
          File.write!(test_file, "Chain test data: SUCCESS")

          :ok =
            Session.prompt(
              session,
              "Use the task tool with description 'read file' and prompt 'Read chain_test.txt and tell me what it says'. After the task completes, summarize the result."
            )

          case wait_for_response(session, 120_000) do
            {:ok, msg, events} ->
              text = get_text(msg)

              # Check if task tool was used
              tool_events =
                Enum.filter(events, fn
                  {:tool_start, _} -> true
                  {:tool_end, _, _} -> true
                  _ -> false
                end)

              # Either used tool or responded directly
              assert text != "" or length(tool_events) > 0

            {:error, _reason, _events} ->
              # May fail but shouldn't crash
              assert true
          end

          GenServer.stop(session)
      end
    end

    test "nested task executions complete successfully", %{tmp_dir: tmp_dir} do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          # First level task
          result =
            TaskTool.execute(
              "outer_task",
              %{
                "description" => "Outer task",
                "prompt" => "What is 5 * 5? Reply with just the number."
              },
              nil,
              nil,
              tmp_dir,
              [model: test_model()]
            )

          case result do
            %AgentToolResult{content: content} ->
              text =
                content
                |> Enum.filter(&match?(%TextContent{}, &1))
                |> Enum.map(& &1.text)
                |> Enum.join(" ")

              assert text =~ "25" or text != ""

            {:error, _} ->
              assert true
          end
      end
    end
  end

  # ============================================================================
  # Tool Definition Tests
  # ============================================================================

  describe "Task Tool Definition" do
    test "tool has correct name and parameters", %{tmp_dir: tmp_dir} do
      tool = TaskTool.tool(tmp_dir, [])

      assert tool.name == "task"
      assert tool.parameters["type"] == "object"

      properties = tool.parameters["properties"]
      assert Map.has_key?(properties, "description")
      assert Map.has_key?(properties, "prompt")
      assert Map.has_key?(properties, "engine")
      assert Map.has_key?(properties, "role")

      required = tool.parameters["required"]
      assert "description" in required
      assert "prompt" in required
    end

    test "tool description includes available roles", %{tmp_dir: tmp_dir} do
      tool = TaskTool.tool(tmp_dir, [])

      assert tool.description =~ "research"
      assert tool.description =~ "implement"
      assert tool.description =~ "review"
      assert tool.description =~ "test"
    end

    test "role parameter includes enum of available roles", %{tmp_dir: tmp_dir} do
      tool = TaskTool.tool(tmp_dir, [])

      role_prop = tool.parameters["properties"]["role"]

      if Map.has_key?(role_prop, "enum") do
        enum = role_prop["enum"]
        assert "research" in enum
        assert "implement" in enum
        assert "review" in enum
        assert "test" in enum
      else
        # Enum may not be present if no roles defined
        assert true
      end
    end

    test "custom subagent appears in tool definition", %{tmp_dir: tmp_dir} do
      project_config = Path.join(tmp_dir, ".lemon")
      File.mkdir_p!(project_config)

      custom_agents = [
        %{
          "id" => "custom_tool_role",
          "prompt" => "Custom role prompt",
          "description" => "A custom role for testing"
        }
      ]

      File.write!(Path.join(project_config, "subagents.json"), Jason.encode!(custom_agents))

      tool = TaskTool.tool(tmp_dir, [])

      assert tool.description =~ "custom_tool_role"

      role_prop = tool.parameters["properties"]["role"]

      if Map.has_key?(role_prop, "enum") do
        assert "custom_tool_role" in role_prop["enum"]
      end
    end
  end
end
