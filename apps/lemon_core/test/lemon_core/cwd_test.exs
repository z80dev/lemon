defmodule LemonCore.CwdTest do
  use ExUnit.Case, async: false

  alias LemonCore.Cwd

  @gateway_config_key :gateway_test_config

  setup do
    previous_gateway = Application.get_env(:lemon_core, @gateway_config_key)
    previous_agent_dir = System.get_env("LEMON_AGENT_DIR")
    tmp = Path.join(System.tmp_dir!(), "lemon_cwd_test_#{System.unique_integer([:positive])}")
    agent_dir = Path.join(tmp, "agent")
    System.put_env("LEMON_AGENT_DIR", agent_dir)

    on_exit(fn ->
      if previous_gateway,
        do: Application.put_env(:lemon_core, @gateway_config_key, previous_gateway),
        else: Application.delete_env(:lemon_core, @gateway_config_key)

      if previous_agent_dir,
        do: System.put_env("LEMON_AGENT_DIR", previous_agent_dir),
        else: System.delete_env("LEMON_AGENT_DIR")

      File.rm_rf(tmp)
    end)

    {:ok, tmp: tmp, agent_dir: agent_dir}
  end

  test "channel runs default to the assistant home and create it", %{agent_dir: agent_dir} do
    Application.put_env(:lemon_core, @gateway_config_key, %{default_cwd: nil})
    home = Path.expand(Path.join(agent_dir, "workspace"))

    refute File.exists?(home)
    assert Cwd.channel_default_cwd() == home
    assert File.dir?(home)
    assert LemonCore.Paths.assistant_home() == home
  end

  test "operator runs keep the home-directory default" do
    Application.put_env(:lemon_core, @gateway_config_key, %{default_cwd: nil})

    assert Cwd.default_cwd() in [System.user_home(), File.cwd!()]
    refute Cwd.default_cwd() == LemonCore.Paths.assistant_home()
  end

  test "a configured gateway.default_cwd wins for channel runs", %{tmp: tmp} do
    project = Path.join(tmp, "project")
    File.mkdir_p!(project)
    Application.put_env(:lemon_core, @gateway_config_key, %{default_cwd: project})

    assert Cwd.channel_default_cwd() == project
  end
end
