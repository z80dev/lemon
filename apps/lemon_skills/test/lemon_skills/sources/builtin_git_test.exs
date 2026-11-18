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
      assert Builtin.fetch(nil, "unused", []) == {:error, :use_builtin_seeder}
      assert Builtin.upstream_hash(nil, []) == {:error, :unsupported}
    end
  end

  describe "git source" do
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

      assert {:ok, %{"url" => "git@example.test:skills/example.git", "source_kind" => "git"}} =
               Git.inspect("git@example.test:skills/example.git", [])
    end
  end

  defp skill_document(name) do
    "---\nname: #{name}\ndescription: A source adapter fixture.\n---\n\n# Instructions\n\nUse it.\n"
  end
end
