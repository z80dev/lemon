defmodule CodingAgent.Tools.BashConfigTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{SettingsManager, ToolRegistry}
  alias LemonAgent.Types.AgentToolResult
  alias LemonCore.Config.ValidationError

  @moduletag :tmp_dir

  setup %{tmp_dir: cwd} do
    previous = Application.get_env(:lemon_core, :paths)

    Application.put_env(
      :lemon_core,
      :paths,
      Keyword.put(previous || [], :global_config, Path.join(cwd, "global.toml"))
    )

    File.mkdir_p!(Path.join(cwd, ".lemon"))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lemon_core, :paths, previous),
        else: Application.delete_env(:lemon_core, :paths)
    end)

    :ok
  end

  test "config flows through settings and uses the actual filtered tool set", %{tmp_dir: cwd} do
    configure(cwd, "enabled = true")
    settings = SettingsManager.load(cwd)
    assert settings.tools.bash.interceptor.enabled
    File.write!(Path.join(cwd, "file"), "data")

    for {tools, blocked} <- [{["bash", "read"], true}, {["bash"], false}] do
      {:ok, bash} =
        ToolRegistry.get_tool(cwd, "bash",
          settings_manager: settings,
          enabled_only: tools,
          include_extensions: false,
          include_mcp: false
        )

      assert %AgentToolResult{is_error: ^blocked} =
               bash.execute.("id", %{"command" => "cat file"}, nil, nil)
    end
  end

  test "default config leaves interceptor disabled", %{tmp_dir: cwd} do
    refute SettingsManager.load(cwd).tools.bash.interceptor.enabled
  end

  test "project custom rules replace defaults", %{tmp_dir: cwd} do
    configure(cwd, """
    enabled = true
    rules = [{pattern = '^echo ', tool = 'read', message = 'Use reader'}]
    """)

    settings = SettingsManager.load(cwd)

    {:ok, bash} =
      ToolRegistry.get_tool(cwd, "bash",
        settings_manager: settings,
        enabled_only: ["bash", "read"],
        include_extensions: false,
        include_mcp: false
      )

    assert %AgentToolResult{is_error: true} =
             bash.execute.("id", %{"command" => "echo x"}, nil, nil)
  end

  test "invalid enabled values and regex rules fail validation", %{tmp_dir: cwd} do
    for setting <- [
          ~s(enabled = "true"),
          "rules = [{pattern = '[', tool = 'read', message = 'bad'}]",
          "rules = false"
        ] do
      configure(cwd, setting)

      assert_raise ValidationError, ~r/runtime.tools.bash.interceptor/, fn ->
        SettingsManager.load(cwd)
      end
    end
  end

  defp configure(cwd, body),
    do:
      File.write!(
        Path.join(cwd, ".lemon/config.toml"),
        "[runtime.tools.bash.interceptor]\n" <> body <> "\n"
      )
end
