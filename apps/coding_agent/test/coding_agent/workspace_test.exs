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
  @tag :tmp_dir
  test "profile snapshot overrides persona without writing destination files", %{tmp_dir: root} do
    File.write!(Path.join(root, "SOUL.md"), "destination-stale-persona")
    File.write!(Path.join(root, "IDENTITY.md"), "destination-stale-identity")
    File.write!(Path.join(root, "MEMORY.md"), "destination-only-memory")
    File.write!(Path.join(root, "TOOLS.md"), "destination-tools")
    File.write!(Path.join(root, "credentials.json"), "destination-only-credential")
    snapshot = %{"SOUL.md" => "controller-persona", "README.md" => "profile-job"}

    files = Workspace.load_bootstrap_files(workspace_dir: root, profile_instructions: snapshot)
    by_name = Map.new(files, &{&1.name, &1})
    assert by_name["SOUL.md"].content == "controller-persona"
    assert by_name["README.md"].content == "profile-job"
    refute Map.has_key?(by_name, "IDENTITY.md")
    assert by_name["MEMORY.md"].content == "destination-only-memory"
    assert by_name["TOOLS.md"].content == "destination-tools"
    assert File.read!(Path.join(root, "SOUL.md")) == "destination-stale-persona"
    assert File.read!(Path.join(root, "credentials.json")) == "destination-only-credential"
    refute File.exists?(Path.join(root, "README.md"))
  end

  @tag :tmp_dir
  test "profile snapshots retain truncation and subagent isolation", %{tmp_dir: root} do
    files =
      Workspace.load_bootstrap_files(
        workspace_dir: root,
        profile_instructions: %{
          "AGENTS.md" => String.duplicate("a", 500),
          "USER.md" => "private-user",
          "SOUL.md" => "private-persona",
          "README.md" => "private-job"
        },
        max_chars: 100,
        session_scope: :subagent
      )

    assert Enum.map(files, & &1.name) == ["AGENTS.md", "TOOLS.md"]
    assert hd(files).content =~ "truncated AGENTS.md"
    refute inspect(files) =~ "private-user"
    refute inspect(files) =~ "private-persona"
    refute inspect(files) =~ "private-job"
  end

  test "profile snapshots reject paths, credential files and non-text values" do
    for files <- [
          %{"../SOUL.md" => "escape"},
          %{"credentials.json" => "secret"},
          %{"MEMORY.md" => "controller-memory"},
          %{"USER.md" => 1},
          %{"SOUL.md" => <<0>>},
          %{"SOUL.md" => <<255>>},
          []
        ] do
      assert {:error, :invalid_profile_instructions} =
               Workspace.validate_profile_instructions(files)
    end
  end

end
