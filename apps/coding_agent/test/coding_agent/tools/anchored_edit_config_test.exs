defmodule CodingAgent.Tools.AnchoredEditConfigTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{FileReadTracker, SettingsManager, ToolRegistry}
  alias CodingAgent.Tools.AnchoredEdit
  alias LemonAgent.Types.AgentToolResult
  alias LemonCore.Config.ValidationError

  @moduletag :tmp_dir

  setup %{tmp_dir: cwd} do
    previous_paths = Application.get_env(:lemon_core, :paths)
    paths = Keyword.put(previous_paths || [], :global_config, Path.join(cwd, "global.toml"))
    Application.put_env(:lemon_core, :paths, paths)
    File.mkdir_p!(Path.join(cwd, ".lemon"))
    path = Path.join(cwd, "source.txt")
    File.write!(path, "first\nhidden\nlast\n")

    on_exit(fn ->
      FileReadTracker.forget_session(cwd)

      if is_nil(previous_paths),
        do: Application.delete_env(:lemon_core, :paths),
        else: Application.put_env(:lemon_core, :paths, previous_paths)
    end)

    %{cwd: cwd, path: path}
  end

  test "project config reaches registered edit tools through settings", ctx do
    configure(ctx.cwd, "true")
    settings = SettingsManager.load(ctx.cwd)
    assert settings.tools.edit.enforce_seen_lines
    opts = options(ctx.cwd, settings)
    {:ok, read} = ToolRegistry.get_tool(ctx.cwd, "read", opts)
    {:ok, edit} = ToolRegistry.get_tool(ctx.cwd, "edit", opts)
    result = read.execute.("read", %{"path" => ctx.path, "offset" => 1, "limit" => 1}, nil, nil)
    params = edit_params(ctx.path, result.details.snapshot)

    assert {:error, message} = edit.execute.("edit", params, nil, nil)
    assert message =~ "Unseen lines 2"
    assert message =~ "read #{ctx.path}:2"
    assert File.read!(ctx.path) == "first\nhidden\nlast\n"

    read.execute.("read", %{"path" => ctx.path, "offset" => 2, "limit" => 1}, nil, nil)
    assert %AgentToolResult{} = edit.execute.("edit", params, nil, nil)
    assert File.read!(ctx.path) == "first\nchanged\nlast\n"
  end

  test "explicit tool options override the configured default", ctx do
    configure(ctx.cwd, "true")

    opts =
      options(ctx.cwd, SettingsManager.load(ctx.cwd)) |> Keyword.put(:enforce_seen_lines, false)

    {:ok, read} = ToolRegistry.get_tool(ctx.cwd, "read", opts)
    {:ok, edit} = ToolRegistry.get_tool(ctx.cwd, "edit", opts)
    result = read.execute.("read", %{"path" => ctx.path, "limit" => 1}, nil, nil)

    assert %AgentToolResult{} =
             edit.execute.("edit", edit_params(ctx.path, result.details.snapshot), nil, nil)
  end

  test "unset config enforces seen lines; false config disables", ctx do
    for setting <- [nil, "false"] do
      cwd = Path.join(ctx.cwd, setting || "unset")
      File.mkdir_p!(Path.join(cwd, ".lemon"))
      if setting, do: configure(cwd, setting)
      settings = SettingsManager.load(cwd)
      assert settings.tools.edit.enforce_seen_lines == is_nil(setting)
      opts = options(ctx.cwd, settings)
      {:ok, edit} = ToolRegistry.get_tool(cwd, "edit", opts)
      File.write!(ctx.path, "first\nhidden\nlast\n")
      tag = AnchoredEdit.snapshot(File.read!(ctx.path))
      result = edit.execute.("edit", edit_params(ctx.path, tag), nil, nil)

      if setting do
        assert %AgentToolResult{} = result
      else
        assert {:error, _} = result
      end
    end
  end

  test "invalid config is rejected before creating tools", ctx do
    configure(ctx.cwd, ~s("true"))

    assert_raise ValidationError, ~r/runtime.tools.edit.enforce_seen_lines/, fn ->
      SettingsManager.load(ctx.cwd)
    end
  end

  defp configure(cwd, setting) do
    File.write!(
      Path.join(cwd, ".lemon/config.toml"),
      "[runtime.tools.edit]\nenforce_seen_lines = #{setting}\n"
    )
  end

  defp options(session_id, settings) do
    [
      session_id: session_id,
      settings_manager: settings,
      enabled_only: ["read", "edit"],
      include_extensions: false,
      include_mcp: false
    ]
  end

  defp edit_params(path, tag) do
    %{
      "path" => path,
      "snapshot" => tag,
      "edits" => [%{"start_line" => 2, "new_text" => "changed"}]
    }
  end
end
