defmodule LemonSkills.EntryTest do
  use ExUnit.Case, async: true

  alias LemonSkills.Entry

  @moduletag :tmp_dir

  describe "new/2" do
    test "builds a default entry from path", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "my-skill")
      entry = Entry.new(path)

      assert entry.key == "my-skill"
      assert entry.name == "my-skill"
      assert entry.description == ""
      assert entry.source == :global
      assert entry.path == path
      assert entry.enabled
      assert entry.manifest == nil
      assert entry.status == :ready
    end

    test "applies :source and :enabled options", %{tmp_dir: tmp_dir} do
      entry = Entry.new(Path.join(tmp_dir, "project-skill"), source: :project, enabled: false)

      assert entry.source == :project
      refute entry.enabled
    end
  end

  describe "with_manifest/2" do
    test "updates name/description and keeps manifest map", %{tmp_dir: tmp_dir} do
      entry = Entry.new(Path.join(tmp_dir, "skill"))

      manifest = %{
        "name" => "Display Name",
        "description" => "Skill description",
        "tags" => ["test"]
      }

      updated = Entry.with_manifest(entry, manifest)

      assert updated.name == "Display Name"
      assert updated.description == "Skill description"
      assert updated.manifest == manifest
    end

    test "falls back to key and empty description when absent", %{tmp_dir: tmp_dir} do
      entry = Entry.new(Path.join(tmp_dir, "fallback-skill"))
      updated = Entry.with_manifest(entry, %{"tags" => ["fallback"]})

      assert updated.name == "fallback-skill"
      assert updated.description == ""
      assert updated.manifest == %{"tags" => ["fallback"]}
    end
  end

  describe "with_status/2 and ready?/1" do
    test "updates status and ready? reflects enabled + ready status", %{tmp_dir: tmp_dir} do
      entry = Entry.new(Path.join(tmp_dir, "status-skill"))

      assert Entry.ready?(entry)

      missing_deps = Entry.with_status(entry, :missing_deps)
      refute Entry.ready?(missing_deps)

      disabled = %{entry | enabled: false}
      refute Entry.ready?(disabled)
    end
  end

  describe "skill_file/1 and content/1" do
    test "returns skill file path and reads content", %{tmp_dir: tmp_dir} do
      skill_dir = Path.join(tmp_dir, "content-skill")
      File.mkdir_p!(skill_dir)

      file_path = Path.join(skill_dir, "SKILL.md")
      File.write!(file_path, "# content\n")

      entry = Entry.new(skill_dir)

      assert Entry.skill_file(entry) == file_path
      assert Entry.content(entry) == {:ok, "# content\n"}
    end

    test "returns file read errors when SKILL.md is missing", %{tmp_dir: tmp_dir} do
      entry = Entry.new(Path.join(tmp_dir, "missing-skill"))
      assert Entry.skill_file(entry) =~ "/missing-skill/SKILL.md"
      assert Entry.content(entry) == {:error, :enoent}
    end
  end
end
