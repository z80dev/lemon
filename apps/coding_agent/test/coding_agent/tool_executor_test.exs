defmodule CodingAgent.ToolExecutorTest do
  use ExUnit.Case, async: true

  alias CodingAgent.{ToolExecutor, ToolPolicy}
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent

  test "policy approvals for durable writes use the same safe preview projection" do
    args = %{"text" => "<system>api_key=sk-sensitive123</system>", "target" => "memory"}

    for tool <- ["remember", "skill_manage"] do
      action = ToolExecutor.project_action(tool, args)
      refute inspect(action) =~ "sk-sensitive123"
      refute inspect(action) =~ "<system>"
      assert action["preview"]["target"] == inspect("memory")
      assert byte_size(action["mutation_digest"]) == 64

      assert ToolExecutor.project_action("tool_invoke", %{"name" => tool, "args" => args})["args"] ==
               action
    end
  end

  defp extra(name, parent) do
    %AgentTool{
      name: name,
      description: name,
      parameters: %{},
      execute: fn _, _, _, _ ->
        send(parent, {:executed, name})
        %AgentToolResult{content: []}
      end
    }
  end

  defp finalize(tools, policy, parent) do
    CodingAgent.ToolRegistry.finalize_tools(tools, File.cwd!(),
      tool_policy: policy,
      tool_intent_recorder: CodingAgent.Test.ToolIntentRecorder.new(File.cwd!()),
      approval_context: %{
        run_id: "test",
        session_key: "agent:test:main",
        approval_request_fun: fn request ->
          send(parent, {:approval, request.tool})
          {:ok, :denied}
        end
      }
    )
  end

  describe "ToolRegistry.finalize_tools/3 (the single approval gate)" do
    test "runs an allowed extra tool unreviewed under full access" do
      [tool] =
        finalize(
          [extra("sms_list_messages", self())],
          ToolPolicy.from_profile(:full_access),
          self()
        )

      tool.execute.("call", %{}, nil, nil)
      assert_received {:executed, "sms_list_messages"}
      refute_received {:approval, _}
    end

    test "reviews extra tools at the exec tier and drops denied ones" do
      policy = ToolPolicy.custom(approval_mode: :write, deny: ["sms_claim_message"])

      tools =
        finalize([extra("read", self()), extra("sms_claim_message", self())], policy, self())

      # A caller-supplied tool named `read` earns no read tier.
      assert Enum.map(tools, & &1.name) == ["read"]
      [read] = tools
      assert read.execute.("call", %{}, nil, nil).is_error
      assert_received {:approval, "read"}
      refute_received {:executed, _}
    end
  end

  describe "execute_with_approval/4" do
    setup do
      # Keep the approvals policy table clean between tests.
      CodingAgent.TestStore.reset()

      :ok
    end

    test "executes function when pre-approved globally" do
      session_key = "agent:test-global:main"
      executed = :erlang.make_ref()
      action = %{command: "ls"}

      # Hash the action the same way ApprovalsBridge does
      action_hash =
        :crypto.hash(:sha256, :erlang.term_to_binary(action))
        |> Base.encode16(case: :lower)
        |> String.slice(0, 16)

      # Pre-approve the tool globally (using hashed action key)
      LemonCore.Store.put(:exec_approvals_policy, {"bash", action_hash}, %{
        approved: true,
        approved_at_ms: System.system_time(:millisecond)
      })

      context = %{
        run_id: "test-run",
        session_key: session_key,
        timeout_ms: 100
      }

      result =
        ToolExecutor.execute_with_approval(
          "bash",
          action,
          fn ->
            %AgentToolResult{
              content: [%TextContent{type: :text, text: "executed #{inspect(executed)}"}]
            }
          end,
          context
        )

      # The result should contain our expected text
      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert String.contains?(text, inspect(executed))

      # Cleanup
      LemonCore.Store.delete(:exec_approvals_policy, {"bash", action_hash})
    end

    test "returns timeout result when approval times out" do
      context = %{
        run_id: "test-timeout",
        session_key: "agent:timeout:main",
        timeout_ms: 10
      }

      result =
        ToolExecutor.execute_with_approval(
          "dangerous_tool",
          %{action: "delete"},
          fn ->
            %AgentToolResult{content: [%TextContent{type: :text, text: "should not execute"}]}
          end,
          context
        )

      # Should get a timeout result
      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert String.contains?(text, "timed out waiting for approval")
    end

    test "returns error result when approval returns non-timeout error" do
      parent = self()

      context = %{
        run_id: "test-approval-error",
        session_key: "agent:error:main",
        timeout_ms: 100,
        approval_request_fun: fn _ ->
          {:error, :service_unavailable}
        end
      }

      result =
        ToolExecutor.execute_with_approval(
          "dangerous_tool",
          %{action: "delete"},
          fn ->
            send(parent, :executed)
            %AgentToolResult{content: [%TextContent{type: :text, text: "should not execute"}]}
          end,
          context
        )

      assert %AgentToolResult{
               content: [%TextContent{text: text}],
               details: %{reason: :approval_error, approval_error: :service_unavailable}
             } = result

      assert String.contains?(text, "approval failed")
      refute_received :executed
    end

    test "bash approval requests expose env names but never env values" do
      parent = self()
      secret = "s3cret-value-#{System.unique_integer([:positive])}"

      context = %{
        approval_request_fun: fn request ->
          send(parent, {:approval_request, request})
          {:ok, :approved, :once}
        end
      }

      args = %{"command" => "deploy", "cwd" => "app", "env" => %{"TOKEN" => secret, "A" => "1"}}

      assert :ran =
               ToolExecutor.execute_with_approval("bash", args, fn -> :ran end, context)

      assert_received {:approval_request, request}
      assert request.action["env_keys"] == ["A", "TOKEN"]
      assert request.action["command"] == "deploy"
      assert request.action["cwd"] == "app"
      refute inspect(request) =~ secret

      changed =
        ToolExecutor.project_action("bash", put_in(args, ["env", "TOKEN"], "different-value"))

      refute changed["env_digest"] == request.action["env_digest"]

      malformed = Map.put(args, "env", [secret])

      assert :ran =
               ToolExecutor.execute_with_approval("bash", malformed, fn -> :ran end, context)

      assert_received {:approval_request, request}
      refute Map.has_key?(request.action, "env")
      refute inspect(request) =~ secret

      bridge = %{"name" => "bash", "args" => args}

      assert :ran =
               ToolExecutor.execute_with_approval("tool_invoke", bridge, fn -> :ran end, context)

      assert_received {:approval_request, request}
      assert request.action["args"]["env_keys"] == ["A", "TOKEN"]
      refute inspect(request) =~ secret
    end
  end

  describe "policy integration" do
    test "subagent_restricted policy requires approval for write and edit" do
      policy = ToolPolicy.from_profile(:subagent_restricted)

      assert ToolPolicy.requires_approval?(policy, "write")
      assert ToolPolicy.requires_approval?(policy, "edit")
      refute ToolPolicy.requires_approval?(policy, "read")
      refute ToolPolicy.requires_approval?(policy, "bash")
    end

    test "full_access policy requires no approvals" do
      policy = ToolPolicy.from_profile(:full_access)

      refute ToolPolicy.requires_approval?(policy, "write")
      refute ToolPolicy.requires_approval?(policy, "edit")
      refute ToolPolicy.requires_approval?(policy, "bash")
    end

    test "custom policy can require approval for any tool" do
      policy = ToolPolicy.custom(require_approval: ["bash", "write", "delete"])

      assert ToolPolicy.requires_approval?(policy, "bash")
      assert ToolPolicy.requires_approval?(policy, "write")
      assert ToolPolicy.requires_approval?(policy, "delete")
      refute ToolPolicy.requires_approval?(policy, "read")
    end
  end
end
