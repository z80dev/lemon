defmodule CodingAgent.RestrictedToolPolicyTest do
  use ExUnit.Case, async: true

  alias CodingAgent.{ToolExecutor, ToolPolicy}
  alias LemonAgent.Types.{AgentTool, AgentToolResult}

  @restricted_profiles [:read_only, :safe_mode, :subagent_restricted]
  @restricted_tools ["write", "edit", "hashline_edit", "patch", "memory_topic", "task", "agent"]

  test "restricted profiles deny every built-in editor, topic writer, and delegation tool" do
    for profile <- @restricted_profiles, name <- @restricted_tools do
      policy = ToolPolicy.from_profile(profile)

      refute ToolPolicy.allowed?(policy, name), "#{profile} must deny #{name}"
      assert is_binary(ToolPolicy.denial_reason(policy, name))
    end
  end

  test "restrictions survive policy serialization" do
    for profile <- @restricted_profiles do
      policy = profile |> ToolPolicy.from_profile() |> ToolPolicy.to_map() |> ToolPolicy.from_map()

      for name <- @restricted_tools do
        refute ToolPolicy.allowed?(policy, name)
      end
    end
  end

  test "full-access and orchestrator profiles still allow these operations" do
    for profile <- [:full_access, :orchestrator], name <- @restricted_tools do
      assert ToolPolicy.allowed?(ToolPolicy.from_profile(profile), name)
    end
  end

  test "read-only exploration remains available in restricted profiles" do
    for profile <- @restricted_profiles, name <- ~w(read read_skill search_memory grep find ls) do
      assert ToolPolicy.allowed?(ToolPolicy.from_profile(profile), name)
    end
  end

  test "list and map filtering remove the same forbidden tools" do
    tools = Enum.map(["read" | @restricted_tools], &%AgentTool{name: &1})
    tools_map = Map.new(tools, &{&1.name, &1})

    for profile <- @restricted_profiles do
      policy = ToolPolicy.from_profile(profile)
      {allowed, denied} = ToolPolicy.partition_tools(policy, tools)

      assert Enum.map(allowed, & &1.name) == ["read"]
      assert Enum.map(denied, & &1.name) == @restricted_tools
      assert ToolPolicy.apply_policy(policy, tools) == allowed
      assert Map.keys(ToolPolicy.apply_policy_to_map(policy, tools_map)) == ["read"]
    end
  end

  test "filtering before approval wrapping cannot execute a denied tool" do
    caller = self()
    marker = make_ref()

    tools =
      Enum.map(@restricted_tools, fn name ->
        %AgentTool{
          name: name,
          execute: fn _id, _args, _signal, _update ->
            send(caller, marker)
            %AgentToolResult{}
          end
        }
      end)

    for profile <- @restricted_profiles do
      policy = ToolPolicy.from_profile(profile)

      remaining =
        policy
        |> ToolPolicy.apply_policy(tools)
        |> ToolExecutor.wrap_all_with_approval(policy, %{
          approval_request_fun: fn _request ->
            flunk("denied tools must be filtered before requesting approval")
          end
        })

      assert remaining == []
      refute_received ^marker
    end
  end
end
