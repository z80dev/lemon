defmodule LemonGateway.WorkspaceTest do
  use ExUnit.Case, async: false

  alias LemonGateway.Workspace

  defmodule StubAgentConfig do
    def workspace_dir, do: "/srv/agent/workspace"
  end

  setup do
    original = Application.get_env(:lemon_gateway, :workspace_dir)
    original_env = System.get_env("LEMON_AGENT_DIR")

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:lemon_gateway, :workspace_dir)
      else
        Application.put_env(:lemon_gateway, :workspace_dir, original)
      end

      if original_env do
        System.put_env("LEMON_AGENT_DIR", original_env)
      else
        System.delete_env("LEMON_AGENT_DIR")
      end
    end)

    :ok
  end

  test "uses a configured path" do
    Application.put_env(:lemon_gateway, :workspace_dir, "/tmp/gateway-workspace")

    assert Workspace.dir() == "/tmp/gateway-workspace"
  end

  test "resolves an MFA, which is how the runtime forwards the agent's value" do
    Application.put_env(:lemon_gateway, :workspace_dir, {StubAgentConfig, :workspace_dir, []})

    assert Workspace.dir() == "/srv/agent/workspace"
  end

  test "falls back to the agent directory layout when unconfigured" do
    Application.delete_env(:lemon_gateway, :workspace_dir)
    System.put_env("LEMON_AGENT_DIR", "/tmp/agent-dir")

    assert Workspace.dir() == "/tmp/agent-dir/workspace"
  end

  test "falls back when the configured module is not loaded" do
    Application.put_env(
      :lemon_gateway,
      :workspace_dir,
      {Definitely.Not.Loaded, :workspace_dir, []}
    )

    System.put_env("LEMON_AGENT_DIR", "/tmp/agent-dir")

    assert Workspace.dir() == "/tmp/agent-dir/workspace"
  end
end
