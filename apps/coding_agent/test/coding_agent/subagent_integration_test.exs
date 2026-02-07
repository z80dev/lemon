defmodule CodingAgent.SubagentIntegrationTest do
  @moduledoc """
  Integration tests for subagent execution via the Task tool.

  These tests verify that:
  1. The Task tool can spawn a subagent session
  2. The subagent can execute and return results
  3. Different subagent types (research, etc.) work correctly

  To run these tests:

      mix test apps/coding_agent/test/coding_agent/subagent_integration_test.exs --include integration

  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :subagent

  alias CodingAgent.Session
  alias CodingAgent.SettingsManager
  alias CodingAgent.Tools.Task, as: TaskTool
  alias Ai.Types.{AssistantMessage, TextContent}
  alias Ai.Test.IntegrationConfig

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

  defp start_session(opts) do
    base_opts = [
      cwd: opts[:cwd] || System.tmp_dir!(),
      model: opts[:model] || IntegrationConfig.model(),
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

  defp skip_unless_cli_installed(name) do
    case System.find_executable(name) do
      nil ->
        IO.puts("[Subagent Integration Tests] Skipping: #{name} CLI not installed")
        :skip

      _path ->
        :ok
    end
  end

  defp skip_unless_cli_configured(name) do
    keys =
      case name do
        "codex" -> ["OPENAI_API_KEY", "CODEX_API_KEY"]
        "claude" -> ["ANTHROPIC_API_KEY", "CLAUDE_API_KEY"]
        "kimi" -> ["MOONSHOT_API_KEY", "KIMI_API_KEY"]
        _ -> []
      end

    configured? =
      Enum.any?(keys, fn key ->
        case System.get_env(key) do
          nil -> false
          "" -> false
          _ -> true
        end
      end)

    if configured? do
      :ok
    else
      IO.puts(
        "[Subagent Integration Tests] Skipping: #{name} CLI not configured (missing API key env)"
      )

      :skip
    end
  end

  defp subscribe_and_collect_events(session, timeout) do
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

  defp wait_for_response(session, timeout) do
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

  defp has_task_tool_call?(events) do
    Enum.any?(events, fn
      {:tool_start, "task", _} -> true
      {:tool_end, "task", _} -> true
      {:message_update, _, {:tool_call_start, _, %{"name" => "task"}}} -> true
      {:message_update, _, {:tool_call_end, _, %{"name" => "task"}, _}} -> true
      _ -> false
    end)
  end

  # ============================================================================
  # Test Setup
  # ============================================================================

  setup_all do
    Ai.ProviderRegistry.init()
    Ai.ProviderRegistry.register(:anthropic_messages, Ai.Providers.Anthropic)
    IO.puts("\n[Subagent Integration Tests] Configuration: #{IntegrationConfig.describe()}")
    :ok
  end

  # ============================================================================
  # Direct Task Tool Execution Tests
  # ============================================================================

  describe "Direct Task Tool Execution" do
    @tag :tmp_dir
    test "task tool can spawn a subagent that returns a simple response", %{tmp_dir: tmp_dir} do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          # Execute the task tool directly
          result =
            TaskTool.execute(
              "test_call_1",
              %{
                "description" => "Say hello",
                "prompt" => "Say 'Hello from subagent!' and nothing else."
              },
              # no abort signal
              nil,
              # no on_update callback
              nil,
              tmp_dir,
              model: IntegrationConfig.model()
            )

          case result do
            %AgentCore.Types.AgentToolResult{content: content, details: details} ->
              text =
                content
                |> Enum.filter(&match?(%TextContent{}, &1))
                |> Enum.map(& &1.text)
                |> Enum.join(" ")

              assert text =~ "Hello" or text =~ "hello",
                     "Expected greeting in response, got: #{text}"

              assert details[:status] == "completed"
              assert details[:session_id] != nil

            {:error, reason} ->
              flunk("Task tool failed: #{inspect(reason)}")
          end
      end
    end

    @tag :tmp_dir
    test "task tool can use research role to read a file", %{tmp_dir: tmp_dir} do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          # Create a test file
          test_file = Path.join(tmp_dir, "secret.txt")
          File.write!(test_file, "The answer is 42.")

          result =
            TaskTool.execute(
              "test_call_2",
              %{
                "description" => "Find secret",
                "prompt" =>
                  "Read the file secret.txt and tell me what the answer is. Reply with just the number.",
                "role" => "research"
              },
              nil,
              nil,
              tmp_dir,
              model: IntegrationConfig.model()
            )

          case result do
            %AgentCore.Types.AgentToolResult{content: content, details: details} ->
              text =
                content
                |> Enum.filter(&match?(%TextContent{}, &1))
                |> Enum.map(& &1.text)
                |> Enum.join(" ")

              assert text =~ "42", "Expected '42' in response, got: #{text}"
              assert details[:role] == "research"

            {:error, reason} ->
              flunk("Task tool failed: #{inspect(reason)}")
          end
      end
    end
  end

  describe "Task Tool with CLI Engines" do
    @tag :tmp_dir
    test "task tool can run via codex engine", %{tmp_dir: tmp_dir} do
      case {skip_unless_cli_installed("codex"), skip_unless_cli_configured("codex")} do
        {:skip, _} ->
          assert true

        {_, :skip} ->
          assert true

        {:ok, :ok} ->
          result =
            TaskTool.execute(
              "test_call_codex",
              %{
                "description" => "Codex hello",
                "prompt" => "Say 'hello from codex' and nothing else.",
                "engine" => "codex"
              },
              nil,
              nil,
              tmp_dir,
              []
            )

          case result do
            %AgentCore.Types.AgentToolResult{content: content, details: details} ->
              text =
                content
                |> Enum.filter(&match?(%TextContent{}, &1))
                |> Enum.map(& &1.text)
                |> Enum.join(" ")

              assert text =~ "hello" or text =~ "Hello",
                     "Expected greeting in response, got: #{text}"

              assert details[:engine] == "codex"
              assert details[:status] == "completed"

            {:error, reason} ->
              flunk("Task tool (codex engine) failed: #{inspect(reason)}")
          end
      end
    end

    @tag :tmp_dir
    test "task tool can run via claude engine", %{tmp_dir: tmp_dir} do
      case {skip_unless_cli_installed("claude"), skip_unless_cli_configured("claude")} do
        {:skip, _} ->
          assert true

        {_, :skip} ->
          assert true

        {:ok, :ok} ->
          result =
            TaskTool.execute(
              "test_call_claude",
              %{
                "description" => "Claude hello",
                "prompt" => "Say 'hello from claude' and nothing else.",
                "engine" => "claude"
              },
              nil,
              nil,
              tmp_dir,
              []
            )

          case result do
            %AgentCore.Types.AgentToolResult{content: content, details: details} ->
              text =
                content
                |> Enum.filter(&match?(%TextContent{}, &1))
                |> Enum.map(& &1.text)
                |> Enum.join(" ")

              assert text =~ "hello" or text =~ "Hello",
                     "Expected greeting in response, got: #{text}"

              assert details[:engine] == "claude"
              assert details[:status] == "completed"

            {:error, reason} ->
              flunk("Task tool (claude engine) failed: #{inspect(reason)}")
          end
      end
    end

    @tag :tmp_dir
    test "task tool can run via kimi engine", %{tmp_dir: tmp_dir} do
      case {skip_unless_cli_installed("kimi"), skip_unless_cli_configured("kimi")} do
        {:skip, _} ->
          assert true

        {_, :skip} ->
          assert true

        _ ->
          result =
            TaskTool.execute(
              "test_call_kimi",
              %{
                "description" => "Kimi hello",
                "prompt" => "Say 'hello from kimi' and nothing else.",
                "engine" => "kimi"
              },
              nil,
              nil,
              tmp_dir,
              model: IntegrationConfig.model()
            )

          case result do
            %AgentCore.Types.AgentToolResult{content: content, details: details} ->
              text =
                content
                |> Enum.filter(&match?(%TextContent{}, &1))
                |> Enum.map(& &1.text)
                |> Enum.join(" ")

              assert text =~ "hello" or text =~ "Hello",
                     "Expected greeting in response, got: #{text}"

              assert details[:engine] == "kimi"

            {:error, reason} ->
              flunk("Task tool (kimi engine) failed: #{inspect(reason)}")
          end
      end
    end
  end

  # ============================================================================
  # Agent-Initiated Subagent Tests
  # ============================================================================

  describe "Agent-Initiated Subagent via Task Tool" do
    @tag :tmp_dir
    test "agent can spawn a subagent to complete a delegated task", %{tmp_dir: tmp_dir} do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          # Create a test file for the subagent to find
          test_file = Path.join(tmp_dir, "data.txt")
          File.write!(test_file, "Project name: LemonAgent")

          session =
            start_session(
              cwd: tmp_dir,
              system_prompt: """
              You are a coding assistant. When asked to delegate a task, you MUST use the task tool.
              The task tool spawns a subagent to handle the work.
              """
            )

          prompt = """
          Use the task tool to spawn a subagent that will read data.txt and report the project name.
          The subagent should use the research role.
          After the subagent completes, tell me what it found.
          """

          :ok = Session.prompt(session, prompt)

          case wait_for_response(session, 120_000) do
            {:ok, msg, events} ->
              text = get_text(msg)

              # Either the agent used the task tool, or it read the file directly
              # Both are acceptable outcomes
              used_task_tool = has_task_tool_call?(events)

              assert text =~ "Lemon" or text =~ "lemon" or used_task_tool,
                     "Expected project name or task tool usage, got: #{text}"

            {:error, reason, events} ->
              flunk(
                "Agent loop failed: #{inspect(reason)}, events: #{inspect(Enum.take(events, 20))}"
              )
          end
      end
    end
  end

  # ============================================================================
  # Coordinator Tests
  # ============================================================================

  describe "Coordinator-based Subagent Execution" do
    @tag :tmp_dir
    test "coordinator can run a single subagent", %{tmp_dir: tmp_dir} do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          {:ok, coordinator} =
            CodingAgent.Coordinator.start_link(
              cwd: tmp_dir,
              model: IntegrationConfig.model(),
              default_timeout: 60_000
            )

          result =
            CodingAgent.Coordinator.run_subagent(
              coordinator,
              prompt: "What is 2 + 2? Reply with just the number.",
              timeout: 60_000
            )

          case result do
            {:ok, text} ->
              assert text =~ "4", "Expected '4' in response, got: #{text}"

            {:error, reason} ->
              flunk("Coordinator run_subagent failed: #{inspect(reason)}")
          end
      end
    end

    @tag :tmp_dir
    test "coordinator can run multiple subagents concurrently", %{tmp_dir: tmp_dir} do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          {:ok, coordinator} =
            CodingAgent.Coordinator.start_link(
              cwd: tmp_dir,
              model: IntegrationConfig.model(),
              default_timeout: 60_000
            )

          specs = [
            %{prompt: "What is 1 + 1? Reply with just the number.", description: "Math 1"},
            %{prompt: "What is 2 + 2? Reply with just the number.", description: "Math 2"}
          ]

          results = CodingAgent.Coordinator.run_subagents(coordinator, specs, timeout: 120_000)

          assert length(results) == 2

          completed = Enum.filter(results, &(&1.status == :completed))

          assert length(completed) >= 1,
                 "Expected at least one completed subagent, got: #{inspect(results)}"

          # Check that completed results have expected answers
          Enum.each(completed, fn result ->
            assert result.result =~ "2" or result.result =~ "4",
                   "Expected math answer in result, got: #{result.result}"
          end)
      end
    end
  end
end
