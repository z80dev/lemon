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

  test "hidden entries are violations that change the bundle hash", %{tmp_dir: tmp_dir} do
    skill_dir = make_skill!(tmp_dir, "hidden-skill")
    assert {:ok, hash1} = Bundle.compute_hash(skill_dir)

    File.write!(Path.join(skill_dir, ".DS_Store"), "not ignored")

    assert {:ok, hash2} = Bundle.compute_hash(skill_dir)
    refute hash1 == hash2
    assert {:ok, scan} = Bundle.scan(skill_dir)

    assert {:error, {:bundle_violations, [%{path: ".DS_Store", reason: :hidden}]}} =
             Bundle.require_clean(scan)
  end

  test "symlinked entries are violations and are never followed", %{tmp_dir: tmp_dir} do
    skill_dir = make_skill!(tmp_dir, "symlink-skill")
    outside_file = Path.join(tmp_dir, "outside.txt")
    File.write!(outside_file, "secret")

    File.mkdir_p!(Path.join(skill_dir, "references"))
    :ok = File.ln_s(outside_file, Path.join(skill_dir, "references/leak.txt"))

    assert {:ok, %{violations: [%{path: "references/leak.txt", reason: :symlink}]}} =
             Bundle.scan(skill_dir)

    assert {:ok, payload} = Bundle.review_payload(skill_dir)
    refute payload =~ "secret"
    assert {:error, :symlink} = Bundle.read_file(skill_dir, "references/leak.txt")
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
