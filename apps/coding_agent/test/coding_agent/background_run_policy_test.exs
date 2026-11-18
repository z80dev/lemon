defmodule CodingAgent.BackgroundRunPolicyTest do
  @moduledoc """
  `/bg` from a channel passes only the session key, cwd, model and thinking
  level. The background session must still inherit the destination agent's
  config and profile tool-policy floor and the bound profile workspace.
  """
  use ExUnit.Case, async: false

  alias CodingAgent.{BackgroundRun, Session, TaskStore}
  alias LemonAgent.Test.Mocks
  alias LemonCore.ProfileStore

  setup do
    TaskStore.clear()
    root = Path.join(System.tmp_dir!(), "bg-policy-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "project"))
    config = Path.join(root, "config.toml")
    previous_paths = Application.get_env(:lemon_core, :paths)

    Application.put_env(:lemon_core, :paths,
      home_state_dir: Path.join(root, "state"),
      global_config: config
    )

    on_exit(fn ->
      TaskStore.clear()

      if previous_paths,
        do: Application.put_env(:lemon_core, :paths, previous_paths),
        else: Application.delete_env(:lemon_core, :paths)

      File.rm_rf(root)
    end)

    %{root: root, cwd: Path.join(root, "project"), config: config}
  end

  # Mirrors `LemonChannels.PortableCommand.start_background/2`: the channel
  # forwards only these keys to the runtime.
  defp channel_bg(session_key, cwd, runner) do
    BackgroundRun.start("do work",
      session_key: session_key,
      cwd: cwd,
      model: nil,
      thinking_level: nil,
      runner: runner
    )
  end

  defp capturing_runner do
    owner = self()

    fn session_opts, _prompt, _signal, _timeout ->
      {:ok, child} =
        Session.start_link(Keyword.merge(session_opts, model: Mocks.mock_model(), tools: nil))

      state = Session.get_state(child)
      send(owner, {:bg_session, session_opts, state})
      GenServer.stop(child)
      {:ok, "done"}
    end
  end

  test "channel /bg on a config-restricted agent keeps the agent's bash deny", %{
    cwd: cwd,
    config: config
  } do
    File.write!(config, """
    [profiles.restricted.tool_policy]
    deny = ["bash"]
    """)

    key = "agent:restricted:telegram:bot:dm:42"
    assert {:ok, %{id: _id}} = channel_bg(key, cwd, capturing_runner())
    assert_receive {:bg_session, opts, state}, 5_000

    assert opts[:agent_id] == "restricted"
    assert "bash" in (opts[:tool_policy][:deny] || [])
    refute LemonCore.ToolPolicy.allowed?(opts[:execution_context].tool_policy, "bash")
    refute Enum.any?(state.tools, &(&1.name == "bash"))
  end

  test "channel /bg on a profile-bound agent uses the profile policy and workspace", %{
    cwd: cwd
  } do
    id = "writer#{System.unique_integer([:positive])}"

    assert {:ok, profile} =
             ProfileStore.create(%{"id" => id, "toolPolicy" => %{"deny" => ["bash"]}})

    key = "agent:#{id}:discord:bot:channel:7"
    assert {:ok, %{id: _}} = channel_bg(key, cwd, capturing_runner())
    assert_receive {:bg_session, opts, state}, 5_000

    refute LemonCore.ToolPolicy.allowed?(opts[:execution_context].tool_policy, "bash")
    refute Enum.any?(state.tools, &(&1.name == "bash"))
    assert opts[:workspace_dir] == profile["paths"]["workspace"]
    refute opts[:workspace_dir] == CodingAgent.Config.workspace_dir()
  end

  test "a profile store failure on the floor read fails closed with no run", %{
    cwd: cwd,
    config: config
  } do
    File.write!(config, "[profiles\nthis is not toml")

    assert {:error, _} =
             channel_bg("agent:restricted:telegram:bot:dm:42", cwd, capturing_runner())

    refute_receive {:bg_session, _, _}, 200
    assert BackgroundRun.list() == []
  end

  test "an unknown session key fails closed and creates no TaskStore record", %{cwd: cwd} do
    assert {:error, _} = channel_bg("not-a-session-key", cwd, capturing_runner())
    refute_receive {:bg_session, _, _}, 200
    assert BackgroundRun.list() == []
  end

  test "a requested but unavailable parent is a hard error, not full access", %{cwd: cwd} do
    assert {:error, _} =
             BackgroundRun.start("do work",
               parent_session: "missing-parent-session",
               cwd: cwd,
               runner: capturing_runner()
             )

    refute_receive {:bg_session, _, _}, 200

    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, _, _}

    assert {:error, _} =
             BackgroundRun.start("do work", parent_session: dead, runner: capturing_runner())

    refute_receive {:bg_session, _, _}, 200
    assert BackgroundRun.list() == []
  end
end
