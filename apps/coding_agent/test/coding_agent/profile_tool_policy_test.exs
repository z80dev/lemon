defmodule CodingAgent.ProfileToolPolicyTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Executor.SessionRunner
  alias CodingAgent.{ToolPolicy, ToolRegistry}
  alias LemonCore.ProfileStore
  alias LemonGateway.ExecutionRequest

  @tag :tmp_dir
  test "fresh runtime floor removes a real denied registry tool and retains approval gates", %{
    tmp_dir: root
  } do
    previous = Application.get_env(:lemon_core, :paths)
    config = Path.join(root, "config.toml")
    Application.put_env(:lemon_core, :paths, home_state_dir: root, global_config: config)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lemon_core, :paths, previous),
        else: Application.delete_env(:lemon_core, :paths)
    end)

    assert {:ok, _} =
             ProfileStore.create(%{
               id: "runtime-policy",
               toolPolicy: %{
                 "deny" => ["bash"],
                 "require_approval" => ["write"],
                 "approvals" => %{"write" => "always"}
               }
             })

    request = %ExecutionRequest{
      run_id: "runtime-policy-test",
      prompt: "Check destination policy",
      session_key: "agent:runtime-policy:main",
      tool_policy: %{allow: :all, deny: [], require_approval: [], approvals: %{"write" => :never}},
      meta: %{
        agent_id: "runtime-policy",
        profile_id: "runtime-policy",
        tool_policy: %{"allow" => "all", "approvals" => %{"write" => "never"}}
      }
    }

    policy = SessionRunner.execution_tool_policy(request, root, %{tool_policy: %{allow: :all}})

    opts = [
      include_extensions: false,
      include_mcp: false,
      tool_policy: policy,
      approval_context: %{
        run_id: "runtime-policy-test",
        session_key: request.session_key,
        approval_request_fun: fn _ -> {:ok, :denied} end
      }
    ]

    assert {:ok, _} =
             ToolRegistry.get_tool(root, "bash", include_extensions: false, include_mcp: false)

    assert {:error, :not_found} = ToolRegistry.get_tool(root, "bash", opts)
    assert {:ok, write} = ToolRegistry.get_tool(root, "write", opts)
    target = Path.join(root, "denied.txt")

    result =
      write.execute.("write-denied", %{"path" => target, "content" => "must not write"}, nil, nil)

    assert result.is_error
    refute File.exists?(target)

    assert {:ok, _} = ProfileStore.update("runtime-policy", %{toolPolicy: %{"allow" => ["read"]}})
    fresh = SessionRunner.execution_tool_policy(request, root)
    assert fresh.allow == ["read"]

    assert {:error, :not_found} =
             ToolRegistry.get_tool(root, "write", Keyword.put(opts, :tool_policy, fresh))

    # Destination-local ceilings cannot be replaced by incoming grants.
    ceiling =
      SessionRunner.execution_tool_policy(request, root, %{
        tool_policy: %{blocked_tools: ["read"]}
      })

    assert {:error, :not_found} =
             ToolRegistry.get_tool(root, "read", Keyword.put(opts, :tool_policy, ceiling))
  end

  @tag :tmp_dir
  test "legacy destination profiles expand native presets and select their local policy", %{
    tmp_dir: root
  } do
    previous = Application.get_env(:lemon_core, :paths)
    config = Path.join(root, "config.toml")

    File.write!(
      config,
      "[profiles.legacy.tool_policy]\nprofile = \"read_only\"\nallow = \"all\"\n"
    )

    Application.put_env(:lemon_core, :paths, home_state_dir: root, global_config: config)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lemon_core, :paths, previous),
        else: Application.delete_env(:lemon_core, :paths)
    end)

    request = %ExecutionRequest{
      run_id: "legacy-policy-test",
      prompt: "Check legacy policy",
      session_key: "agent:legacy:main",
      tool_policy: %{allow: :all},
      meta: %{}
    }

    policy = SessionRunner.execution_tool_policy(request, root)
    assert ToolPolicy.allowed?(policy, "read")
    refute ToolPolicy.allowed?(policy, "bash")

    assert {:error, :not_found} =
             ToolRegistry.get_tool(root, "bash",
               include_extensions: false,
               include_mcp: false,
               tool_policy: policy
             )
  end

  @tag :tmp_dir
  test "corrupt or unreadable destination profile storage cannot widen execution grants", %{
    tmp_dir: root
  } do
    previous = Application.get_env(:lemon_core, :paths)
    config = Path.join(root, "config.toml")
    Application.put_env(:lemon_core, :paths, home_state_dir: root, global_config: config)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lemon_core, :paths, previous),
        else: Application.delete_env(:lemon_core, :paths)
    end)

    request = %ExecutionRequest{
      run_id: "corrupt-policy-test",
      prompt: "Check unavailable policy",
      session_key: "agent:corrupt:main",
      tool_policy: %{allow: :all},
      meta: %{profile_id: "corrupt", agent_id: "corrupt"}
    }

    File.write!(config, "[profiles.corrupt\ninvalid")
    policy = SessionRunner.execution_tool_policy(request, root)
    refute ToolPolicy.allowed?(policy, "read")
    refute ToolPolicy.allowed?(policy, "bash")
    File.rm!(config)
    File.mkdir!(config)
    unavailable = SessionRunner.execution_tool_policy(request, root)
    refute ToolPolicy.allowed?(unavailable, "read")

    assert {:error, :not_found} =
             ToolRegistry.get_tool(root, "read",
               include_extensions: false,
               include_mcp: false,
               tool_policy: unavailable
             )
  end
end
