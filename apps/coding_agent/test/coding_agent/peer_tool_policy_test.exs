defmodule CodingAgent.PeerToolPolicyTest do
  @moduledoc """
  The A2A `peer` tool sends session content to remote agents, so restrictive
  presets must withhold it at the registry boundary and approval gates must
  treat it as executable egress.
  """

  use ExUnit.Case, async: true

  alias CodingAgent.ToolRegistry
  alias LemonCore.ToolPolicy

  @moduletag :tmp_dir

  @registry_opts [include_extensions: false, include_mcp: false]

  test "restrictive presets withhold peer from the session inventory", %{tmp_dir: tmp_dir} do
    for profile <- [:no_external, :leaf_worker, :safe_mode, :subagent_restricted] do
      policy = ToolPolicy.from_profile(profile)
      opts = [tool_policy: policy] ++ @registry_opts

      refute ToolPolicy.allowed?(policy, "peer"), "#{profile} allowed peer"

      assert {:error, :not_found} = ToolRegistry.get_tool(tmp_dir, "peer", opts),
             "#{profile} exposed peer"

      refute "peer" in Enum.map(ToolRegistry.get_tools(tmp_dir, opts), & &1.name)
    end

    full = [tool_policy: ToolPolicy.from_profile(:full_access)] ++ @registry_opts
    assert {:ok, _} = ToolRegistry.get_tool(tmp_dir, "peer", full)
  end

  test "approval gates treat peer as executable egress", %{tmp_dir: tmp_dir} do
    owner = self()
    assert ToolPolicy.tier("peer") == :exec

    {:ok, tool} =
      ToolRegistry.get_tool(
        tmp_dir,
        "peer",
        [
          tool_policy: ToolPolicy.custom(approval_mode: :write),
          session_key: "agent:peer-approval:main",
          agent_id: "peer-approval",
          approval_request_fun: fn request ->
            send(owner, {:peer_approval, request})
            {:ok, :denied}
          end
        ] ++ @registry_opts
      )

    result =
      tool.execute.(
        "peer-call",
        %{"action" => "message", "peer_id" => "anyone", "text" => "session secrets"},
        nil,
        nil
      )

    assert result.is_error
    assert result.details.reason == :approval_denied
    assert_receive {:peer_approval, %{tool: "peer"}}
  end
end
