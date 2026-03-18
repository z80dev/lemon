defmodule LemonSkills.BundleTest do
  use ExUnit.Case, async: true

  alias LemonSkills.Bundle

  @moduletag :tmp_dir

  test "bundle hash changes when supporting files change", %{tmp_dir: tmp_dir} do
    skill_dir = make_skill!(tmp_dir, "hash-skill")
    File.mkdir_p!(Path.join(skill_dir, "references"))
    File.write!(Path.join(skill_dir, "references/guide.md"), "v1")

    assert {:ok, hash1} = Bundle.compute_hash(skill_dir)

    File.write!(Path.join(skill_dir, "references/guide.md"), "v2")

    assert {:ok, hash2} = Bundle.compute_hash(skill_dir)
    refute hash1 == hash2
  end

  test "bundle hash includes path identity", %{tmp_dir: tmp_dir} do
    skill_dir = make_skill!(tmp_dir, "path-skill")
    File.mkdir_p!(Path.join(skill_dir, "references"))
    File.mkdir_p!(Path.join(skill_dir, "templates"))
    File.write!(Path.join(skill_dir, "references/file.txt"), "same")
    assert {:ok, hash1} = Bundle.compute_hash(skill_dir)

    File.rm!(Path.join(skill_dir, "references/file.txt"))
    File.write!(Path.join(skill_dir, "templates/file.txt"), "same")
    assert {:ok, hash2} = Bundle.compute_hash(skill_dir)

    refute hash1 == hash2
  end

  test "hidden metadata files do not affect bundle hash", %{tmp_dir: tmp_dir} do
    skill_dir = make_skill!(tmp_dir, "hidden-skill")
    assert {:ok, hash1} = Bundle.compute_hash(skill_dir)

    File.write!(Path.join(skill_dir, ".draft_meta.json"), ~s({"ignored":true}))
    File.write!(Path.join(skill_dir, ".DS_Store"), "ignored")

    assert {:ok, hash2} = Bundle.compute_hash(skill_dir)
    assert hash1 == hash2
  end

  test "rejects symlinked bundle entries", %{tmp_dir: tmp_dir} do
    skill_dir = make_skill!(tmp_dir, "symlink-skill")
    outside_file = Path.join(tmp_dir, "outside.txt")
    File.write!(outside_file, "secret")

    File.mkdir_p!(Path.join(skill_dir, "references"))
    :ok = File.ln_s(outside_file, Path.join(skill_dir, "references/leak.txt"))

    assert {:error, {:symlink_not_allowed, "references/leak.txt"}} =
             Bundle.compute_hash(skill_dir)

    assert {:error, {:symlink_not_allowed, "references/leak.txt"}} =
             Bundle.review_payload(skill_dir)
  end

  defp make_skill!(tmp_dir, name) do
    skill_dir = Path.join(tmp_dir, name)
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      """
      ---
      name: #{name}
      description: bundle test
      ---

      # #{name}
      """
    )

    skill_dir
  end
end
