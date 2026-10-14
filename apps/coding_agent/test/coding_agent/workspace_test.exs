defmodule CodingAgent.WorkspaceTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Workspace

  @moduletag :tmp_dir

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
  test "profile snapshot overrides persona without writing destination files", %{tmp_dir: root} do
    File.write!(Path.join(root, "SOUL.md"), "destination-stale-persona")
    File.write!(Path.join(root, "IDENTITY.md"), "destination-stale-identity")
    File.write!(Path.join(root, "MEMORY.md"), "destination-only-memory")
    File.write!(Path.join(root, "USER.md"), "destination-only-user")
    File.write!(Path.join(root, "TOOLS.md"), "destination-tools")
    File.write!(Path.join(root, "credentials.json"), "destination-only-credential")
    snapshot = %{"SOUL.md" => "controller-persona", "README.md" => "profile-job"}

    files = Workspace.load_bootstrap_files(workspace_dir: root, profile_instructions: snapshot)
    by_name = Map.new(files, &{&1.name, &1})
    assert by_name["SOUL.md"].content == "controller-persona"
    assert by_name["README.md"].content == "profile-job"
    refute Map.has_key?(by_name, "IDENTITY.md")
    assert by_name["USER.md"].content == "destination-only-user"
    assert by_name["MEMORY.md"].content == "destination-only-memory"
    assert by_name["TOOLS.md"].content == "destination-tools"
    assert File.read!(Path.join(root, "SOUL.md")) == "destination-stale-persona"
    assert File.read!(Path.join(root, "USER.md")) == "destination-only-user"
    assert File.read!(Path.join(root, "credentials.json")) == "destination-only-credential"
    refute File.exists?(Path.join(root, "README.md"))
  end

  @tag :tmp_dir
  test "profile snapshots retain truncation and subagent isolation", %{tmp_dir: root} do
    File.write!(Path.join(root, "USER.md"), "private-user")

    files =
      Workspace.load_bootstrap_files(
        workspace_dir: root,
        profile_instructions: %{
          "AGENTS.md" => String.duplicate("a", 500),
          "SOUL.md" => "private-persona",
          "README.md" => "private-job"
        },
        max_chars: 100,
        session_scope: :subagent
      )

    assert Enum.map(files, & &1.name) == ["AGENTS.md", "TOOLS.md"]
    refute inspect(files) =~ "private-user"
    refute inspect(files) =~ "private-persona"
    refute inspect(files) =~ "private-job"
  end

  @tag :tmp_dir
  test "empty persona snapshots preserve destination USER.md ownership", %{tmp_dir: root} do
    user_path = Path.join(root, "USER.md")

    files = Workspace.load_bootstrap_files(workspace_dir: root, profile_instructions: %{})
    missing_user = Enum.find(files, &(&1.name == "USER.md"))
    assert missing_user.missing
    assert missing_user.path == user_path
    refute File.exists?(user_path)

    File.write!(user_path, "local-user-preference")
    files = Workspace.load_bootstrap_files(workspace_dir: root, profile_instructions: %{})
    local_user = Enum.find(files, &(&1.name == "USER.md"))
    refute local_user.missing
    assert local_user.content == "local-user-preference"
  end

  @tag :tmp_dir
  test "stale USER.md snapshots fail closed without changing destination data", %{tmp_dir: root} do
    user_path = Path.join(root, "USER.md")
    snapshot = %{"SOUL.md" => "controller-persona", "USER.md" => "stale-controller-user"}

    for local_content <- [nil, "destination-only-user"] do
      if local_content, do: File.write!(user_path, local_content)

      assert {:error, :invalid_profile_instructions} =
               Workspace.validate_profile_instructions(snapshot)

      assert_raise ArgumentError, "invalid profile instruction snapshot", fn ->
        Workspace.load_bootstrap_files(workspace_dir: root, profile_instructions: snapshot)
      end

      if local_content do
        assert File.read!(user_path) == local_content
      else
        refute File.exists?(user_path)
      end
    end
  end

  test "profile snapshots accept only the four authoritative persona filenames" do
    snapshot =
      Map.new(~w(AGENTS.md IDENTITY.md README.md SOUL.md), fn name ->
        {name, "controller #{name}"}
      end)

    assert :ok = Workspace.validate_profile_instructions(snapshot)
  end

  test "profile snapshots reject paths, local workspace files and non-text values" do
    for files <- [
          %{"../SOUL.md" => "escape"},
          %{"credentials.json" => "secret"},
          %{"MEMORY.md" => "controller-memory"},
          %{"USER.md" => "controller-user"},
          %{"TOOLS.md" => "controller-tools"},
          %{"SOUL.md" => 1},
          %{"SOUL.md" => <<0>>},
          %{"SOUL.md" => <<255>>},
          []
        ] do
      assert {:error, :invalid_profile_instructions} =
               Workspace.validate_profile_instructions(files)
    end
  end

  @tag :tmp_dir
  test "context-owned bootstrap projects only canonical shared facts, never raw or private preferences",
       %{tmp_dir: tmp_dir} do
    {store, context, opts} = scoped_workspace(tmp_dir)
    user_path = Path.join(context.workspace_dir, "USER.md")
    memory_path = Path.join(context.workspace_dir, "MEMORY.md")
    File.write!(user_path, "Unknown legacy obsidian preference.\n")
    File.write!(memory_path, "Unknown legacy onyx memory.\n")

    assert {:ok, _} =
             LemonMemory.Preferences.remember(context, "user", "Private azure preference.", nil,
               store: store
             )

    shared = Map.put(context, :shared_memory_grant, true)

    assert {:ok, _} =
             LemonMemory.Preferences.remember(shared, "user", "Shared sunflower preference.", nil,
               store: store
             )

    assert {:ok, _} =
             LemonMemory.Preferences.remember(shared, "memory", "Shared marigold memory.", nil,
               store: store
             )

    other = %{context | memory_context_key: "actor-b"}

    assert {:ok, _} =
             LemonMemory.Preferences.remember(other, "user", "Private cobalt preference.", nil,
               store: store
             )

    for key <- ["actor-a", "actor-b"] do
      files = Workspace.load_bootstrap_files(Keyword.put(opts, :memory_context_key, key))
      user = Enum.find(files, &(&1.name == "USER.md"))
      memory = Enum.find(files, &(&1.name == "MEMORY.md"))
      assert user.source == :verified_shared_memory
      assert user.content =~ "sunflower"
      assert memory.content =~ "marigold"
      text = Enum.map_join(files, "\n", & &1.content)
      for excluded <- ["obsidian", "onyx", "azure", "cobalt"], do: refute(text =~ excluded)
    end

    assert File.read!(user_path) == "Unknown legacy obsidian preference.\n"
    assert File.read!(memory_path) == "Unknown legacy onyx memory.\n"
    subagent = Workspace.load_bootstrap_files(Keyword.put(opts, :session_scope, :subagent))
    assert Enum.map(subagent, & &1.name) == ["AGENTS.md", "TOOLS.md"]
  end

  @tag :tmp_dir
  test "unproven contexts and unavailable shared stores cannot fall back to legacy bootstrap files",
       %{tmp_dir: tmp_dir} do
    {_store, context, opts} = scoped_workspace(tmp_dir)
    File.write!(Path.join(context.workspace_dir, "USER.md"), "Private legacy moonstone")
    File.write!(Path.join(context.workspace_dir, "MEMORY.md"), "Private legacy agate")

    for failing_opts <- [
          Keyword.put(opts, :memory_context_verified, false),
          Keyword.delete(opts, :invocation_context_key),
          Keyword.put(opts, :memory_store, :missing_bootstrap_memory_store)
        ] do
      files = Workspace.load_bootstrap_files(failing_opts)
      refute Enum.any?(files, &(&1.name in ["USER.md", "MEMORY.md"]))
      text = Enum.map_join(files, "\n", & &1.content)
      refute text =~ "moonstone"
      refute text =~ "agate"
    end

    legacy =
      Workspace.load_bootstrap_files(
        workspace_dir: context.workspace_dir,
        memory_context_verified: false,
        shared_memory_grant: false
      )

    assert Enum.find(legacy, &(&1.name == "USER.md")).content =~ "moonstone"
    assert Enum.find(legacy, &(&1.name == "MEMORY.md")).content =~ "agate"
  end

  defp scoped_workspace(tmp_dir) do
    workspace = Path.join(tmp_dir, "scoped-workspace")
    File.mkdir_p!(workspace)
    store = :"workspace_private_#{System.unique_integer([:positive])}"
    start_supervised!({LemonMemory.Store, name: store, path: Path.join(tmp_dir, "store")})

    context = %{
      workspace_dir: workspace,
      cwd: tmp_dir,
      agent_id: "bootstrap",
      session_scope: :main,
      session_key: "agent:bootstrap:main",
      invocation_context_key: "invocation-1",
      memory_context_key: "actor-a",
      memory_context_verified: true
    }

    opts = context |> Map.to_list() |> Keyword.put(:memory_store, store)
    {store, context, opts}
  end
end
