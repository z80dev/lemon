defmodule CodingAgent.Tools.MemoryPathsTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.{Edit, Read, Write}

  defp tool_text(%{content: content}) when is_list(content) do
    case Enum.find(content, &match?(%Ai.Types.TextContent{}, &1)) do
      %Ai.Types.TextContent{text: text} -> text
      _ -> ""
    end
  end

  @tag :tmp_dir
  test "read resolves MEMORY.md to workspace_dir (./ escape hatch stays in cwd)", %{
    tmp_dir: tmp_dir
  } do
    project_dir = Path.join(tmp_dir, "project")
    workspace_dir = Path.join(tmp_dir, "workspace")

    File.mkdir_p!(project_dir)
    File.mkdir_p!(workspace_dir)

    File.write!(Path.join(project_dir, "MEMORY.md"), "project-memory")
    File.write!(Path.join(workspace_dir, "MEMORY.md"), "workspace-memory")

    tool = Read.tool(project_dir, workspace_dir: workspace_dir)

    result_workspace = tool.execute.("t1", %{"path" => "MEMORY.md"}, nil, nil)
    assert String.contains?(tool_text(result_workspace), "workspace-memory")
    refute String.contains?(tool_text(result_workspace), "project-memory")

    result_project = tool.execute.("t2", %{"path" => "./MEMORY.md"}, nil, nil)
    assert String.contains?(tool_text(result_project), "project-memory")
    refute String.contains?(tool_text(result_project), "workspace-memory")
  end

  @tag :tmp_dir
  test "write resolves memory/ to workspace_dir (./ escape hatch stays in cwd)", %{
    tmp_dir: tmp_dir
  } do
    project_dir = Path.join(tmp_dir, "project")
    workspace_dir = Path.join(tmp_dir, "workspace")

    File.mkdir_p!(project_dir)
    File.mkdir_p!(workspace_dir)

    tool = Write.tool(project_dir, workspace_dir: workspace_dir)

    _result_ws =
      tool.execute.(
        "t1",
        %{"path" => "memory/2026-02-05.md", "content" => "ws-day"},
        nil,
        nil
      )

    assert File.read!(Path.join([workspace_dir, "memory", "2026-02-05.md"])) == "ws-day"
    refute File.exists?(Path.join([project_dir, "memory", "2026-02-05.md"]))

    _result_project =
      tool.execute.(
        "t2",
        %{"path" => "./memory/2026-02-06.md", "content" => "proj-day"},
        nil,
        nil
      )

    assert File.read!(Path.join([project_dir, "memory", "2026-02-06.md"])) == "proj-day"
    refute File.exists?(Path.join([workspace_dir, "memory", "2026-02-06.md"]))
  end

  @tag :tmp_dir
  test "edit resolves MEMORY.md to workspace_dir", %{tmp_dir: tmp_dir} do
    project_dir = Path.join(tmp_dir, "project")
    workspace_dir = Path.join(tmp_dir, "workspace")

    File.mkdir_p!(project_dir)
    File.mkdir_p!(workspace_dir)

    File.write!(Path.join(project_dir, "MEMORY.md"), "project-foo")
    File.write!(Path.join(workspace_dir, "MEMORY.md"), "ws-foo")

    tool = Edit.tool(project_dir, workspace_dir: workspace_dir)

    _result =
      tool.execute.(
        "t1",
        %{"path" => "MEMORY.md", "old_text" => "ws-foo", "new_text" => "ws-bar"},
        nil,
        nil
      )

    assert File.read!(Path.join(workspace_dir, "MEMORY.md")) == "ws-bar"
    assert File.read!(Path.join(project_dir, "MEMORY.md")) == "project-foo"
  end
end
