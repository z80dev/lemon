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

  describe "new/2 - v2 options" do
    test "accepts v2 provenance options", %{tmp_dir: tmp_dir} do
      now = DateTime.utc_now()

      entry =
        Entry.new(Path.join(tmp_dir, "prov-skill"),
          source_kind: :git,
          source_id: "https://github.com/acme/skill",
          trust_level: :community,
          content_hash: "abc123",
          upstream_hash: "def456",
          installed_at: now,
          updated_at: now,
          audit_status: :pass,
          audit_findings: ["all good"]
        )

      assert entry.source_kind == :git
      assert entry.source_id == "https://github.com/acme/skill"
      assert entry.trust_level == :community
      assert entry.content_hash == "abc123"
      assert entry.upstream_hash == "def456"
      assert entry.installed_at == now
      assert entry.updated_at == now
      assert entry.audit_status == :pass
      assert entry.audit_findings == ["all good"]
    end

    test "v2 fields default to nil when not provided", %{tmp_dir: tmp_dir} do
      entry = Entry.new(Path.join(tmp_dir, "plain-skill"))

      assert entry.source_kind == nil
      assert entry.source_id == nil
      assert entry.trust_level == nil
      assert entry.content_hash == nil
      assert entry.upstream_hash == nil
      assert entry.installed_at == nil
      assert entry.updated_at == nil
      assert entry.audit_status == nil
      assert entry.audit_findings == []
    end
  end

  describe "with_provenance/2" do
    test "applies provenance fields from a map", %{tmp_dir: tmp_dir} do
      entry = Entry.new(Path.join(tmp_dir, "prov-skill"))

      record = %{
        "source_kind" => "git",
        "source_id" => "https://github.com/acme/skill",
        "trust_level" => "community",
        "content_hash" => "abc123",
        "upstream_hash" => "def456",
        "installed_at" => "2026-01-01T00:00:00Z",
        "updated_at" => "2026-02-01T00:00:00Z",
        "audit_status" => "pass",
        "audit_findings" => ["ok"]
      }

      updated = Entry.with_provenance(entry, record)

      assert updated.source_kind == :git
      assert updated.source_id == "https://github.com/acme/skill"
      assert updated.trust_level == :community
      assert updated.content_hash == "abc123"
      assert updated.upstream_hash == "def456"
      assert %DateTime{year: 2026, month: 1} = updated.installed_at
      assert %DateTime{year: 2026, month: 2} = updated.updated_at
      assert updated.audit_status == :pass
      assert updated.audit_findings == ["ok"]
    end

    test "handles nil values gracefully", %{tmp_dir: tmp_dir} do
      entry = Entry.new(Path.join(tmp_dir, "nil-skill"))
      record = %{"source_kind" => nil, "trust_level" => nil, "audit_findings" => nil}
      updated = Entry.with_provenance(entry, record)

      assert updated.source_kind == nil
      assert updated.trust_level == nil
      assert updated.audit_findings == []
    end
  end

  describe "to_lockfile_record/1" do
    test "serialises all provenance fields", %{tmp_dir: tmp_dir} do
      now = ~U[2026-01-01 12:00:00Z]

      entry =
        Entry.new(Path.join(tmp_dir, "lock-skill"),
          source_kind: :git,
          source_id: "https://github.com/acme/skill",
          trust_level: :trusted,
          content_hash: "abc",
          upstream_hash: "def",
          installed_at: now,
          updated_at: now,
          audit_status: :warn,
          audit_findings: ["finding1"]
        )

      record = Entry.to_lockfile_record(entry)

      assert record["key"] == "lock-skill"
      assert record["source_kind"] == "git"
      assert record["source_id"] == "https://github.com/acme/skill"
      assert record["trust_level"] == "trusted"
      assert record["content_hash"] == "abc"
      assert record["upstream_hash"] == "def"
      assert record["installed_at"] == "2026-01-01T12:00:00Z"
      assert record["updated_at"] == "2026-01-01T12:00:00Z"
      assert record["audit_status"] == "warn"
      assert record["audit_findings"] == ["finding1"]
    end

    test "nil fields serialise as nil", %{tmp_dir: tmp_dir} do
      entry = Entry.new(Path.join(tmp_dir, "bare-skill"))
      record = Entry.to_lockfile_record(entry)

      assert record["source_kind"] == nil
      assert record["trust_level"] == nil
      assert record["installed_at"] == nil
    end
  end

  describe "compute_content_hash/1" do
    test "returns SHA-256 hex of SKILL.md content", %{tmp_dir: tmp_dir} do
      skill_dir = Path.join(tmp_dir, "hash-skill")
      File.mkdir_p!(skill_dir)
      File.write!(Path.join(skill_dir, "SKILL.md"), "# hash me\n")

      entry = Entry.new(skill_dir)
      hash = Entry.compute_content_hash(entry)

      assert is_binary(hash)
      assert String.length(hash) == 64
      assert hash =~ ~r/^[0-9a-f]+$/
    end

    test "returns nil when SKILL.md is missing", %{tmp_dir: tmp_dir} do
      entry = Entry.new(Path.join(tmp_dir, "no-file-skill"))
      assert Entry.compute_content_hash(entry) == nil
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
