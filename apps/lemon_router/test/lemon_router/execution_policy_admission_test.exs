defmodule LemonRouter.ExecutionPolicyAdmissionTest do
  @moduledoc """
  Router admission applies the canonical tool-policy parser (#72): a malformed
  supplied policy is refused with the parser's own reason, and an admitted
  command carries exactly one validated policy, shared with its execution
  context, whose authority equals the supplied policy.
  """

  use ExUnit.Case, async: false

  alias LemonCore.{ExecutionCommand, ExecutionContext, RunRequest, ToolPolicy}
  alias LemonRouter.SubmissionBuilder

  @tools ~w(read grep write edit bash task agent webfetch zz_unclassified_tool)

  setup do
    original = :sys.get_state(LemonRouter.AgentProfiles)

    :sys.replace_state(LemonRouter.AgentProfiles, fn state ->
      %{
        state
        | profiles: %{
            "policy-admission" => %{
              id: "policy-admission",
              name: "Policy admission",
              tool_policy: nil,
              system_prompt: nil,
              model: nil
            },
            "policy-exempt" => %{
              id: "policy-exempt",
              name: "Policy exempt",
              tool_policy: %{workspace_read_exempt: true, approval_mode: :write},
              system_prompt: nil,
              model: nil
            }
          }
      }
    end)

    on_exit(fn -> :sys.replace_state(LemonRouter.AgentProfiles, fn _ -> original end) end)
    :ok
  end

  test "malformed supplied policy is refused with the canonical parser's reason" do
    for policy <- [
          %{"allow" => 123},
          %{allow: %{"read" => true}},
          %{"profile" => "root"},
          %{profile: :superuser},
          %{"deny" => "bash"},
          %{"approvals" => %{"bash" => "maybe"}},
          %{"files" => true},
          %{"allow" => ["read"], allow: ["read", "bash"]},
          "root",
          false,
          ["read"]
        ] do
      assert {:error, reason} = ToolPolicy.parse(policy)
      assert {:error, ^reason} = build(%{tool_policy: policy}), inspect(policy)
    end
  end

  test "admitted commands carry one validated policy equal to the supplied authority" do
    for policy <- [
          %{"allow" => ["read", "grep", "bash"], "deny" => ["bash"]},
          %{"profile" => "read_only"},
          %{profile: :safe_mode, require_approval: [:write]},
          %{"approval_mode" => "ask", "approvals" => %{"read" => "never"}},
          "leaf_worker"
        ] do
      expected = ToolPolicy.parse!(policy)
      assert {:ok, submission} = build(%{tool_policy: policy})

      assert %ExecutionCommand{tool_policy: admitted, execution_context: context} =
               submission.execution_request

      assert ToolPolicy.validated?(admitted)
      assert {:ok, ^context} = ExecutionContext.validate(context)
      assert admitted == context.tool_policy

      for tool <- @tools do
        assert ToolPolicy.allowed?(admitted, tool) == ToolPolicy.allowed?(expected, tool),
               "#{inspect(policy)} allow #{tool}"

        assert ToolPolicy.requires_approval?(admitted, tool) ==
                 ToolPolicy.requires_approval?(expected, tool),
               "#{inspect(policy)} approval #{tool}"
      end
    end
  end

  test "a request override narrows operator authority but cannot add to it" do
    # The override cannot enable a read exemption no operator layer grants.
    assert {:ok, submission} = build(%{tool_policy: %{workspace_read_exempt: true}})
    assert submission.execution_request.tool_policy.workspace_read_exempt == nil
    assert submission.execution_request.execution_context.tool_policy.workspace_read_exempt == nil

    # An operator profile layer grants it; an absent override inherits it.
    assert {:ok, submission} = build(%{agent_id: "policy-exempt"})
    assert submission.execution_request.tool_policy.workspace_read_exempt == true

    # An override cannot waive the profile's argument-dependent approval gate.
    assert {:ok, submission} =
             build(%{agent_id: "policy-exempt", tool_policy: %{approvals: %{"write" => "never"}}})

    admitted = submission.execution_request.tool_policy
    assert admitted.workspace_read_exempt == true
    assert ToolPolicy.requires_approval?(admitted, "write", %{"diagnostics" => true})

    # An explicit false withdraws the operator grant.
    assert {:ok, submission} =
             build(%{agent_id: "policy-exempt", tool_policy: %{workspace_read_exempt: false}})

    assert submission.execution_request.tool_policy.workspace_read_exempt == false
  end

  defp build(attrs) do
    agent_id = Map.get(attrs, :agent_id, "policy-admission")

    %{
      origin: :control_plane,
      agent_id: agent_id,
      session_key: "agent:#{agent_id}:#{System.unique_integer([:positive])}",
      prompt: "Hello",
      run_id: "run_#{System.unique_integer([:positive])}"
    }
    |> Map.merge(attrs)
    |> RunRequest.new()
    |> SubmissionBuilder.build(%{
      run_supervisor: LemonRouter.RunSupervisor,
      run_process_module: LemonRouter.RunProcess,
      run_process_opts: %{notify_pid: self()}
    })
  end
end
