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

  defp build(attrs) do
    attrs
    |> Map.merge(%{
      origin: :control_plane,
      agent_id: "policy-admission",
      session_key: "agent:policy-admission:#{System.unique_integer([:positive])}",
      prompt: "Hello",
      run_id: "run_#{System.unique_integer([:positive])}"
    })
    |> RunRequest.new()
    |> SubmissionBuilder.build(%{
      run_supervisor: LemonRouter.RunSupervisor,
      run_process_module: LemonRouter.RunProcess,
      run_process_opts: %{notify_pid: self()}
    })
  end
end
