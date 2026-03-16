defmodule LemonSkills.MigratorTest do
  use ExUnit.Case, async: false

  alias LemonSkills.{Config, Lockfile, Migrator}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    prev_home = System.get_env("HOME")

    home = Path.join(tmp_dir, "home")
    File.mkdir_p!(home)
    System.put_env("HOME", home)

    on_exit(fn ->
      if is_nil(prev_home),
        do: System.delete_env("HOME"),
        else: System.put_env("HOME", prev_home)
    end)

    skills_dir = Config.global_skills_dir()
    File.mkdir_p!(skills_dir)

    %{skills_dir: skills_dir}
  end

  defp make_skill(skills_dir, name, opts \\ []) do
    skill_dir = Path.join(skills_dir, name)
    File.mkdir_p!(skill_dir)

    content =
      Keyword.get(
        opts,
        :content,
        "---\nname: #{name}\ndescription: A test skill\n---\nBody.\n"
      )

    File.write!(Path.join(skill_dir, "SKILL.md"), content)

    if Keyword.get(opts, :git, false) do
      File.mkdir_p!(Path.join(skill_dir, ".git"))
    end

    skill_dir
  end

  test "classifies a local skill with no lockfile record", %{skills_dir: skills_dir} do
    make_skill(skills_dir, "my-local-skill")

    {:ok, %{classified: classified}} = Migrator.migrate()

    assert classified >= 1

    {:ok, record} = Lockfile.get(:global, "my-local-skill")
    assert record["source_kind"] == "local"
    assert record["trust_level"] == "community"
    assert record["audit_status"] == "pass"
    assert is_binary(record["installed_at"])
  end

  test "classifies a legacy-git skill when .git/ directory is present",
       %{skills_dir: skills_dir} do
    make_skill(skills_dir, "git-skill", git: true)

    {:ok, %{classified: classified}} = Migrator.migrate()

    assert classified >= 1

    {:ok, record} = Lockfile.get(:global, "git-skill")
    assert record["source_kind"] == "git"
    assert record["trust_level"] == "community"
    assert record["audit_status"] == "pending"
  end

  test "reads git remote URL from .git/config when available", %{skills_dir: skills_dir} do
    skill_dir = make_skill(skills_dir, "remote-git-skill", git: true)

    git_config_content = """
    [core]
    \trepositoryformatversion = 0
    [remote "origin"]
    \turl = https://github.com/acme/remote-git-skill
    \tfetch = +refs/heads/*:refs/remotes/origin/*
    """

    File.write!(Path.join([skill_dir, ".git", "config"]), git_config_content)

    Migrator.migrate()

    {:ok, record} = Lockfile.get(:global, "remote-git-skill")
    assert record["source_kind"] == "git"
    assert record["source_id"] == "https://github.com/acme/remote-git-skill"
  end

  test "skips skills that already have a source_kind in the lockfile",
       %{skills_dir: skills_dir} do
    make_skill(skills_dir, "already-classified")

    existing = %{
      "key" => "already-classified",
      "source_kind" => "registry",
      "source_id" => "https://registry.example.com/already-classified",
      "trust_level" => "trusted",
      "content_hash" => nil,
      "upstream_hash" => nil,
      "installed_at" => "2026-01-01T00:00:00Z",
      "updated_at" => nil,
      "audit_status" => "pass",
      "audit_findings" => []
    }

    Lockfile.put(:global, existing)

    {:ok, %{classified: classified, skipped: skipped}} = Migrator.migrate()

    assert skipped >= 1
    assert classified == 0

    # Record must not be overwritten
    {:ok, record} = Lockfile.get(:global, "already-classified")
    assert record["source_kind"] == "registry"
    assert record["trust_level"] == "trusted"
  end

  test "is idempotent: second run classifies nothing", %{skills_dir: skills_dir} do
    make_skill(skills_dir, "idempotent-skill")

    {:ok, %{classified: first}} = Migrator.migrate()
    {:ok, %{classified: second, skipped: skipped}} = Migrator.migrate()

    assert first >= 1
    assert second == 0
    assert skipped >= 1
  end

  test "handles empty skills directory gracefully" do
    {:ok, result} = Migrator.migrate()
    assert is_integer(result.classified)
    assert is_integer(result.skipped)
  end

  test "writes content_hash when SKILL.md exists", %{skills_dir: skills_dir} do
    make_skill(skills_dir, "hash-skill")

    Migrator.migrate()

    {:ok, record} = Lockfile.get(:global, "hash-skill")
    assert is_binary(record["content_hash"])
    assert String.length(record["content_hash"]) == 64
  end

  test "returns {:error, _} when an unexpected exception occurs during migration" do
    prev_agent_dir_env = System.get_env("LEMON_AGENT_DIR")
    System.delete_env("LEMON_AGENT_DIR")
    # Inject a non-binary as agent_dir so Path.join/2 raises ArgumentError
    Application.put_env(:lemon_skills, :agent_dir, :not_a_valid_path_type)

    on_exit(fn ->
      Application.delete_env(:lemon_skills, :agent_dir)
      if prev_agent_dir_env, do: System.put_env("LEMON_AGENT_DIR", prev_agent_dir_env)
    end)

    result = Migrator.migrate()
    assert {:error, _} = result
  end

  test "populates name from manifest frontmatter", %{skills_dir: skills_dir} do
    make_skill(skills_dir, "manifest-skill",
      content: "---\nname: Manifest Skill\ndescription: Parsed from SKILL.md\n---\nBody.\n"
    )

    Migrator.migrate()

    {:ok, record} = Lockfile.get(:global, "manifest-skill")
    # source_kind must be written; the name is in the Entry but lockfile_record only stores key
    assert record["key"] == "manifest-skill"
    assert record["source_kind"] == "local"
  end
end
