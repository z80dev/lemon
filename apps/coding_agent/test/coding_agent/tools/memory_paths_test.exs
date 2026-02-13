defmodule CodingAgent.Tools.MemoryPathsTest do
  use ExUnit.Case, async: true

  alias AgentCore.Types.AgentToolResult
  alias CodingAgent.Tools.{Edit, Grep, Read, Write}

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
  test "read falls back to workspace SOUL.md and USER.md when missing in cwd", %{tmp_dir: tmp_dir} do
    project_dir = Path.join(tmp_dir, "project")
    workspace_dir = Path.join(tmp_dir, "workspace")

    File.mkdir_p!(project_dir)
    File.mkdir_p!(workspace_dir)

    File.write!(Path.join(workspace_dir, "SOUL.md"), "workspace-soul")
    File.write!(Path.join(workspace_dir, "USER.md"), "workspace-user")

    tool = Read.tool(project_dir, workspace_dir: workspace_dir)

    result_soul = tool.execute.("t1", %{"path" => "SOUL.md"}, nil, nil)
    assert String.contains?(tool_text(result_soul), "workspace-soul")

    result_user = tool.execute.("t2", %{"path" => "USER.md"}, nil, nil)
    assert String.contains?(tool_text(result_user), "workspace-user")

    result_explicit = tool.execute.("t3", %{"path" => "./SOUL.md"}, nil, nil)
    assert {:error, msg} = result_explicit
    assert msg =~ "File not found"
  end

  @tag :tmp_dir
  test "read treats missing workspace daily memory for today and yesterday as optional", %{
    tmp_dir: tmp_dir
  } do
    project_dir = Path.join(tmp_dir, "project")
    workspace_dir = Path.join(tmp_dir, "workspace")

    File.mkdir_p!(project_dir)
    File.mkdir_p!(workspace_dir)

    tool = Read.tool(project_dir, workspace_dir: workspace_dir)

    today = Date.utc_today() |> Date.to_iso8601()
    yesterday = Date.add(Date.utc_today(), -1) |> Date.to_iso8601()
    older = Date.add(Date.utc_today(), -7) |> Date.to_iso8601()

    result_today = tool.execute.("t1", %{"path" => "memory/#{today}.md"}, nil, nil)

    assert %AgentToolResult{details: details_today} = result_today
    assert details_today.missing_optional == true
    assert tool_text(result_today) == ""

    result_yesterday = tool.execute.("t2", %{"path" => "memory/#{yesterday}.md"}, nil, nil)

    assert %AgentToolResult{details: details_yesterday} = result_yesterday
    assert details_yesterday.missing_optional == true
    assert tool_text(result_yesterday) == ""

    result_older = tool.execute.("t3", %{"path" => "memory/#{older}.md"}, nil, nil)
    assert {:error, msg} = result_older
    assert msg =~ "File not found"
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

  @tag :tmp_dir
  test "grep resolves memory path to workspace_dir (./ escape hatch stays in cwd)", %{
    tmp_dir: tmp_dir
  } do
    project_dir = Path.join(tmp_dir, "project")
    workspace_dir = Path.join(tmp_dir, "workspace")

    File.mkdir_p!(Path.join(project_dir, "memory"))
    File.mkdir_p!(Path.join(workspace_dir, "memory"))

    File.write!(Path.join(project_dir, "memory/topic.md"), "project-secret")
    File.write!(Path.join(workspace_dir, "memory/topic.md"), "workspace-secret")

    tool = Grep.tool(project_dir, workspace_dir: workspace_dir)

    result_workspace =
      tool.execute.("t1", %{"pattern" => "workspace-secret", "path" => "memory"}, nil, nil)

    assert String.contains?(tool_text(result_workspace), "workspace-secret")
    refute String.contains?(tool_text(result_workspace), "project-secret")

    result_project =
      tool.execute.("t2", %{"pattern" => "project-secret", "path" => "./memory"}, nil, nil)

    assert String.contains?(tool_text(result_project), "project-secret")
    refute String.contains?(tool_text(result_project), "workspace-secret")
  end
end
