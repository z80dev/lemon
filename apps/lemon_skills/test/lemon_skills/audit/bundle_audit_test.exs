defmodule LemonSkills.Audit.BundleAuditTest do
  use ExUnit.Case, async: true

  alias LemonSkills.Audit.{BundleAudit, State}

  defmodule FirstFailsReviewer do
    def review(_payload, _opts) do
      count = Process.get(:bundle_audit_review_count, 0)
      Process.put(:bundle_audit_review_count, count + 1)

      if count == 0 do
        {:error, :temporary_failure}
      else
        {:ok, {:pass, []}}
      end
    end
  end

  @moduletag :tmp_dir

  setup do
    Application.put_env(:lemon_skills, :audit_llm, enabled: false)

    on_exit(fn ->
      Application.delete_env(:lemon_skills, :audit_llm)
    end)

    :ok
  end

  test "persists and reuses cached audit state until the bundle changes", %{tmp_dir: tmp_dir} do
    skill_dir = make_skill!(tmp_dir, "cached-skill")
    File.mkdir_p!(Path.join(skill_dir, "references"))
    File.write!(Path.join(skill_dir, "references/guide.md"), "safe content")

    scope = {:project, tmp_dir}

    assert {:ok, first} = BundleAudit.audit(skill_dir, scope, "cached-skill", kind: :skill)
    refute first["cached"]

    assert {:ok, stored} = State.get(scope, :skill, "cached-skill")
    assert stored["audit_fingerprint"] == first["audit_fingerprint"]

    assert {:ok, second} = BundleAudit.audit(skill_dir, scope, "cached-skill", kind: :skill)
    assert second["cached"]
    assert second["audit_fingerprint"] == first["audit_fingerprint"]

    File.write!(Path.join(skill_dir, "references/guide.md"), "changed content")

    assert {:ok, third} = BundleAudit.audit(skill_dir, scope, "cached-skill", kind: :skill)
    refute third["cached"]
    refute third["audit_fingerprint"] == first["audit_fingerprint"]
  end

  test "scans supporting files, not just SKILL.md", %{tmp_dir: tmp_dir} do
    skill_dir = make_skill!(tmp_dir, "script-skill")
    File.mkdir_p!(Path.join(skill_dir, "scripts"))
    File.write!(Path.join(skill_dir, "scripts/wipe.sh"), "rm -rf /tmp/demo\n")

    assert {:ok, audit} =
             BundleAudit.audit(skill_dir, {:project, tmp_dir}, "script-skill", kind: :skill)

    assert audit["final_verdict"] == "warn"
    assert Enum.any?(audit["combined_findings"], &String.contains?(&1, "destructive_commands"))
  end

  test "llm review outages do not become cache hits for unchanged bundles", %{tmp_dir: tmp_dir} do
    skill_dir = make_skill!(tmp_dir, "llm-cache-skill")
    scope = {:project, tmp_dir}

    Process.put(:bundle_audit_review_count, 0)

    assert {:ok, first} =
             BundleAudit.audit(skill_dir, scope, "llm-cache-skill",
               kind: :skill,
               llm: [enabled: true, model: "fake-model", reviewer: FirstFailsReviewer]
             )

    refute first["cached"]
    assert first["llm_review_complete"] == false

    assert {:ok, second} =
             BundleAudit.audit(skill_dir, scope, "llm-cache-skill",
               kind: :skill,
               llm: [enabled: true, model: "fake-model", reviewer: FirstFailsReviewer]
             )

    refute second["cached"]
    assert second["llm_review_complete"] == true
    assert Process.get(:bundle_audit_review_count) == 2
  end

  defp make_skill!(tmp_dir, name) do
    skill_dir = Path.join(tmp_dir, name)
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      """
      ---
      name: #{name}
      description: bundle audit test
      ---

      # #{name}
      """
    )

    skill_dir
  end
end
