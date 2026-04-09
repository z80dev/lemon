defmodule CodingAgent.Tools.Task.ExecutionTest do
  use ExUnit.Case, async: false

  alias AgentCore.Types.AgentToolResult
  alias Ai.Types.TextContent
  alias CodingAgent.RunGraph
  alias CodingAgent.TaskProgressBindingServer
  alias CodingAgent.TaskProgressBindingStore
  alias CodingAgent.TaskStore
  alias CodingAgent.Tools.Task
  alias CodingAgent.Tools.Task.Execution

  setup do
    try do
      TaskStore.clear()
    catch
      _, _ -> :ok
    end

    try do
      RunGraph.clear()
    catch
      _, _ -> :ok
    end

    try do
      TaskProgressBindingServer.clear(CodingAgent.TaskProgressBindingServer)
    catch
      _, _ -> :ok
    end

    :ok
  end

  describe "async task progress binding" do
    test "stores parent surface binding when async task launches" do
      result =
        Task.execute(
          "tool_call_123",
          %{
            "description" => "Binding test task",
            "prompt" => "Return hello",
            "async" => true
          },
          nil,
          nil,
          "/tmp",
          parent_run_id: "run_parent_123",
          session_key: "agent:default:telegram:default:dm:12345",
          agent_id: "default"
        )

      assert %AgentCore.Types.AgentToolResult{} = result
      assert result.details.status == "queued"
      assert is_binary(result.details.task_id)
      assert is_binary(result.details.run_id)

      assert {:ok, binding} = TaskProgressBindingStore.get_by_task_id(result.details.task_id)
      assert binding.task_id == result.details.task_id
      assert binding.child_run_id == result.details.run_id
      assert binding.parent_run_id == "run_parent_123"
      assert binding.parent_session_key == "agent:default:telegram:default:dm:12345"
      assert binding.parent_agent_id == "default"
      assert binding.root_action_id == "tool_call_123"
      assert binding.surface == {:status_task, "tool_call_123"}
      assert binding.status == :running
    end

    test "does not store binding when parent surface metadata is unavailable" do
      result =
        Task.execute(
          nil,
          %{
            "description" => "No binding task",
            "prompt" => "Return hello",
            "async" => true
          },
          nil,
          nil,
          "/tmp",
          parent_run_id: "run_parent_123",
          session_key: "agent:default:telegram:default:dm:12345",
          agent_id: "default",
          root_action_id: nil,
          surface: nil
        )

      assert %AgentCore.Types.AgentToolResult{} = result

      assert {:error, :not_found} =
               TaskProgressBindingStore.get_by_task_id(result.details.task_id)
    end
  end

  describe "direct provider fast path" do
    test "routes pure text codex tasks through direct providers instead of the CLI" do
      owner = self()

      result =
        Task.execute(
          "tool_call_direct_codex",
          %{
            "description" => "Write a riddle",
            "prompt" => "Write one short original riddle.",
            "engine" => "codex",
            "async" => false
          },
          nil,
          nil,
          "/tmp",
          direct_provider_override: fn request ->
            send(owner, {:direct_provider_request, request})

            %AgentToolResult{
              content: [%TextContent{text: "riddle"}],
              details: %{status: "completed", execution_path: "direct_provider"}
            }
          end
        )

      assert_receive {:direct_provider_request, request}
      assert request.engine == "codex"
      assert request.prompt == "Write one short original riddle."
      assert request.model == "openai-codex:gpt-5.4"
      assert is_binary(request.system_prompt)
      assert request.system_prompt != ""

      assert %AgentToolResult{} = result
      assert [%TextContent{text: "riddle"}] = result.content
      assert result.details.execution_path == "direct_provider"
    end

    test "keeps tool-requiring codex tasks off the direct provider fast path" do
      owner = self()

      result =
        Task.execute(
          "tool_call_tooling_codex",
          %{
            "description" => "Check outbox",
            "prompt" => "Use bash/read/grep tools only. Return whether outbox.ex exists.",
            "engine" => "codex",
            "async" => false
          },
          nil,
          nil,
          "/tmp",
          direct_provider_override: fn request ->
            send(owner, {:unexpected_direct_provider_request, request})

            %AgentToolResult{
              content: [%TextContent{text: "unexpected"}],
              details: %{status: "completed", execution_path: "direct_provider"}
            }
          end,
          run_override: fn _on_update, _signal ->
            %AgentToolResult{
              content: [%TextContent{text: "cli-or-session"}],
              details: %{status: "completed", execution_path: "fallback"}
            }
          end
        )

      refute_receive {:unexpected_direct_provider_request, _request}
      assert %AgentToolResult{} = result
      assert [%TextContent{text: "cli-or-session"}] = result.content
      assert result.details.execution_path == "fallback"
    end
  end

  describe "internal bash fast path" do
    test "routes bash-only internal tasks through direct bash execution" do
      result =
        Execution.run(
          "call_internal_bash_fast_path",
          %{
            description: "print alpha",
            prompt:
              "Use bash tools only. Do not use any tool except bash. Run `printf alpha`, verify the bash output, and return exactly `alpha`.",
            role_id: nil,
            engine: nil,
            async: false,
            auto_followup: true,
            cwd: nil,
            tool_policy: %{allow: ["bash"]},
            meta: %{},
            session_key: nil,
            agent_id: nil,
            queue_mode: nil,
            resolved_queue_mode: :followup
          },
          nil,
          nil,
          "/tmp",
          []
        )

      assert %AgentCore.Types.AgentToolResult{} = result
      assert AgentCore.get_text(result) == "alpha"
      assert result.details.execution_path == "internal_bash_fast_path"
    end
  end
end
