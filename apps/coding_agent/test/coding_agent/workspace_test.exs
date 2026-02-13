defmodule CodingAgent.WorkspaceTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Workspace

  @tag :tmp_dir
  test "ensure_workspace writes missing files without overwriting existing", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    template_dir = Path.join(tmp_dir, "templates")

    File.mkdir_p!(workspace_dir)
    File.mkdir_p!(template_dir)

    # Create a template file
    File.write!(Path.join(template_dir, "AGENTS.md"), "TEMPLATE AGENTS")
    File.write!(Path.join(template_dir, "SOUL.md"), "TEMPLATE SOUL")
    File.mkdir_p!(Path.join(template_dir, "memory/topics"))
    File.write!(Path.join(template_dir, "memory/topics/TEMPLATE.md"), "TEMPLATE TOPIC FILE")
    File.write!(Path.join(template_dir, "memory/topics/git.md"), "TEMPLATE GIT NOTE")

    # Pre-create AGENTS.md to ensure we do not overwrite
    File.write!(Path.join(workspace_dir, "AGENTS.md"), "EXISTING AGENTS")
    File.mkdir_p!(Path.join(workspace_dir, "memory/topics"))
    File.write!(Path.join(workspace_dir, "memory/topics/TEMPLATE.md"), "EXISTING TOPIC FILE")

    :ok =
      Workspace.ensure_workspace(
        workspace_dir: workspace_dir,
        template_dir: template_dir
      )

    assert File.read!(Path.join(workspace_dir, "AGENTS.md")) == "EXISTING AGENTS"
    assert File.read!(Path.join(workspace_dir, "SOUL.md")) == "TEMPLATE SOUL"

    assert File.read!(Path.join(workspace_dir, "memory/topics/TEMPLATE.md")) ==
             "EXISTING TOPIC FILE"

    assert File.read!(Path.join(workspace_dir, "memory/topics/git.md")) == "TEMPLATE GIT NOTE"
  end

  @tag :tmp_dir
  test "load_bootstrap_files marks missing required files", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    File.write!(Path.join(workspace_dir, "AGENTS.md"), "Agent config")

    files = Workspace.load_bootstrap_files(workspace_dir: workspace_dir, max_chars: 10_000)

    agents = Enum.find(files, &(&1.name == "AGENTS.md"))
    soul = Enum.find(files, &(&1.name == "SOUL.md"))

    assert agents.missing == false
    assert agents.content == "Agent config"

    assert soul.missing == true
    assert String.contains?(soul.content, "[MISSING]")
  end

  @tag :tmp_dir
  test "loads MEMORY.md when present", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    File.write!(Path.join(workspace_dir, "MEMORY.md"), "long-term memory")

    files = Workspace.load_bootstrap_files(workspace_dir: workspace_dir, max_chars: 10_000)
    memory = Enum.find(files, &(&1.name == "MEMORY.md"))

    assert memory != nil
    assert memory.content == "long-term memory"
  end

  @tag :tmp_dir
  test "does not load lowercase memory.md", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    File.write!(Path.join(workspace_dir, "memory.md"), "legacy")

    files = Workspace.load_bootstrap_files(workspace_dir: workspace_dir, max_chars: 10_000)
    memory = Enum.find(files, &(&1.name == "MEMORY.md"))

    assert memory == nil
  end

  @tag :tmp_dir
  test "subagent scope only keeps AGENTS.md and TOOLS.md", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    File.write!(Path.join(workspace_dir, "AGENTS.md"), "agents")
    File.write!(Path.join(workspace_dir, "TOOLS.md"), "tools")
    File.write!(Path.join(workspace_dir, "SOUL.md"), "soul")
    File.write!(Path.join(workspace_dir, "MEMORY.md"), "memory")

    files =
      Workspace.load_bootstrap_files(
        workspace_dir: workspace_dir,
        session_scope: :subagent,
        max_chars: 10_000
      )

    names = Enum.map(files, & &1.name)

    assert names == ["AGENTS.md", "TOOLS.md"]
  end

  @tag :tmp_dir
  test "truncates long files with a marker", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    File.write!(Path.join(workspace_dir, "AGENTS.md"), String.duplicate("a", 500))

    files = Workspace.load_bootstrap_files(workspace_dir: workspace_dir, max_chars: 100)
    agents = Enum.find(files, &(&1.name == "AGENTS.md"))

    assert String.contains?(agents.content, "truncated AGENTS.md")
  end
end
