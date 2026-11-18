defmodule LemonCore.ToolPolicyRestrictedProfilesTest do
  use ExUnit.Case, async: true

  alias LemonCore.ToolPolicy

  @restricted [:safe_mode, :subagent_restricted, :leaf_worker, :no_external]

  # Satellite, A2A and external-messaging tools plus names the platform never
  # classified (a contributed satellite, an MCP tool, an extension tool).
  @unprivileged_names ~w(
    omp cua_js cua_js_reset peer
    honcho_conclude honcho_context honcho_profile honcho_reasoning honcho_search
    contributed_satellite_tool mcp__github__create_issue ext_shell
  )

  defp round_trip(policy), do: policy |> ToolPolicy.to_map() |> ToolPolicy.from_map()

  test "restricted profiles deny satellite, delegation and unclassified tools" do
    for profile <- @restricted, name <- @unprivileged_names do
      policy = ToolPolicy.from_profile(profile)

      refute ToolPolicy.allowed?(policy, name), "#{profile} must deny #{name}"
      refute ToolPolicy.allowed?(round_trip(policy), name), "#{profile} round trip allows #{name}"
      refute ToolPolicy.allowed?(%{"profile" => Atom.to_string(profile)}, name)

      {:ok, restricted} = ToolPolicy.restrict(ToolPolicy.from_profile(:full_access), policy)
      refute ToolPolicy.allowed?(restricted, name), "restricted #{profile} allows #{name}"
      assert is_binary(ToolPolicy.denial_reason(policy, name))
    end
  end

  test "restricted profiles keep agent_message for family sends only" do
    for profile <- @restricted do
      policy = ToolPolicy.from_profile(profile)
      assert ToolPolicy.allowed?(policy, "agent_message"), "#{profile} denies agent_message"
      assert ToolPolicy.family_messaging_only?(policy)
      assert ToolPolicy.family_messaging_only?(round_trip(policy))
    end

    refute ToolPolicy.family_messaging_only?(ToolPolicy.from_profile(:full_access))
    assert ToolPolicy.family_messaging_only?(ToolPolicy.from_profile(:read_only))
    assert ToolPolicy.family_messaging_only?(%{allow: ["agent_message", "task"]})
    assert ToolPolicy.family_messaging_only?(:not_a_policy)
  end

  test "restricted profiles keep their classified built-ins" do
    for profile <- @restricted, name <- ~w(read grep find ls recall read_skill) do
      assert ToolPolicy.allowed?(ToolPolicy.from_profile(profile), name)
    end

    leaf = ToolPolicy.from_profile(:leaf_worker)
    for name <- ~w(bash write edit webfetch), do: assert(ToolPolicy.allowed?(leaf, name))
    for name <- ~w(task agent goal kanban cron), do: refute(ToolPolicy.allowed?(leaf, name))

    no_external = ToolPolicy.from_profile(:no_external)
    for name <- ~w(bash write edit), do: assert(ToolPolicy.allowed?(no_external, name))

    for name <- ~w(webfetch websearch browser_navigate),
        do: refute(ToolPolicy.allowed?(no_external, name))
  end

  test "full access still allows satellite tools" do
    for profile <- [:full_access, :orchestrator], name <- @unprivileged_names do
      assert ToolPolicy.allowed?(ToolPolicy.from_profile(profile), name)
    end
  end
end
