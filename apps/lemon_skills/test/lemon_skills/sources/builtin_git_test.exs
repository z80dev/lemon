defmodule LemonSkills.Sources.BuiltinGitTest do
  use ExUnit.Case, async: true

  alias LemonSkills.Sources.{Builtin, Git}

  @moduletag :tmp_dir

  describe "builtin source" do
    test "enumerates and inspects the skills shipped in priv" do
      results = Builtin.search("ignored", [])

      assert results != []
      assert Enum.all?(results, &(&1.source == :builtin and &1.validated))
      assert Enum.all?(results, &(&1.entry.source_kind == :builtin))
      assert Enum.all?(results, &(&1.entry.trust_level == :builtin))
      assert Enum.any?(results, &(&1.entry.key == "skill-creator"))

      assert {:ok, %{"root" => root, "skills" => skills}} = Builtin.inspect(nil, [])
      assert File.dir?(root)
      assert Enum.sort(skills) == results |> Enum.map(& &1.url) |> Enum.sort()
    end

    test "reports its immutable source contract" do
      assert Builtin.trust_level() == :builtin
      assert Builtin.fetch(nil, "unused", []) == {:error, :use_builtin_seeder}
      assert Builtin.upstream_hash(nil, []) == {:error, :unsupported}
    end
  end

  describe "git source" do
    test "clones a local repository, strips git metadata, and reports its HEAD", %{
      tmp_dir: tmp_dir
    } do
      repo = create_repo!(tmp_dir, "source")
      dest = Path.join(tmp_dir, "installed")
      expected_head = git!(repo, ["rev-parse", "HEAD"])

      assert {:ok, ^expected_head} = Git.upstream_hash(repo, [])
      assert {:ok, ^dest} = Git.fetch(repo, dest, branch: "main", depth: 1)
      assert File.read!(Path.join(dest, "SKILL.md")) =~ "Source Skill"
      refute File.exists?(Path.join(dest, ".git"))
    end

    test "falls back to the repository default branch when the requested branch is absent", %{
      tmp_dir: tmp_dir
    } do
      repo = create_repo!(tmp_dir, "fallback")
      dest = Path.join(tmp_dir, "fallback-installed")

      assert {:ok, ^dest} = Git.fetch(repo, dest, branch: "missing-branch")
      assert File.exists?(Path.join(dest, "SKILL.md"))
      refute File.exists?(Path.join(dest, ".git"))
    end

    test "returns bounded source errors for unavailable repositories", %{tmp_dir: tmp_dir} do
      missing = Path.join(tmp_dir, "missing-repository")

      assert {:error, {:clone_failed, message}} =
               Git.fetch(missing, Path.join(tmp_dir, "missing-install"), [])

      assert is_binary(message)
      assert message != ""

      assert {:error, {:ls_remote_failed, remote_message}} = Git.upstream_hash(missing, [])
      assert is_binary(remote_message)
      assert remote_message != ""
    end

    test "loads valid manifests and rejects invalid or absent manifests", %{tmp_dir: tmp_dir} do
      valid = Path.join(tmp_dir, "valid-skill")
      File.mkdir_p!(valid)
      File.write!(Path.join(valid, "SKILL.md"), skill_document("Valid Skill"))

      assert {:ok, project_entry} = Git.load_from_dir(valid, false)
      assert project_entry.source == :project
      assert project_entry.source_kind == :git
      assert project_entry.trust_level == :community
      assert project_entry.name == "Valid Skill"

      assert {:ok, global_entry} = Git.load_from_dir(valid, true)
      assert global_entry.source == :global

      invalid = Path.join(tmp_dir, "invalid-skill")
      File.mkdir_p!(invalid)
      File.write!(Path.join(invalid, "SKILL.md"), "---\nname: []\n---\nbody")

      assert {:error, {:invalid_manifest, reason}} = Git.load_from_dir(invalid, false)
      assert is_binary(reason)
      assert {:error, :enoent} = Git.load_from_dir(Path.join(tmp_dir, "absent"), false)
    end

    test "exposes non-searchable community-source metadata" do
      assert Git.search("anything", []) == []
      assert Git.trust_level() == :community

      assert {:ok, %{"url" => "git@example.test:skills/example.git", "source_kind" => "git"}} =
               Git.inspect("git@example.test:skills/example.git", [])
    end
  end

  defp create_repo!(tmp_dir, name) do
    repo = Path.join(tmp_dir, name)
    File.mkdir_p!(repo)
    File.write!(Path.join(repo, "SKILL.md"), skill_document("Source Skill"))

    git!(repo, ["init", "--initial-branch=main"])
    git!(repo, ["config", "user.email", "skills-test@example.invalid"])
    git!(repo, ["config", "user.name", "Lemon Skills Test"])
    git!(repo, ["add", "SKILL.md"])
    git!(repo, ["commit", "-m", "initial skill"])
    repo
  end

  defp git!(repo, args) do
    case System.cmd("git", ["-C", repo | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git command failed with #{status}: #{output}")
    end
  end

  defp skill_document(name) do
    "---\nname: #{name}\ndescription: A source adapter fixture.\n---\n\n# Instructions\n\nUse it.\n"
  end
end
