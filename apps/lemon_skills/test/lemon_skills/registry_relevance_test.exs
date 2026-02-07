defmodule LemonSkills.RegistryRelevanceTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  test "find_relevant/2 scores by key/name/description and returns best matches", %{tmp_dir: tmp_dir} do
    foo_dir = Path.join([tmp_dir, ".lemon", "skill", "foo-skill"])
    bar_dir = Path.join([tmp_dir, ".lemon", "skill", "bar-skill"])
    File.mkdir_p!(foo_dir)
    File.mkdir_p!(bar_dir)

    File.write!(
      Path.join(foo_dir, "SKILL.md"),
      """
      ---
      name: foo-skill
      description: Use this when working on foo pipelines
      ---

      body
      """
    )

    File.write!(
      Path.join(bar_dir, "SKILL.md"),
      """
      ---
      name: bar-skill
      description: Use this when working on bar pipelines
      ---

      body
      """
    )

    LemonSkills.refresh(cwd: tmp_dir)

    [best | _] = LemonSkills.find_relevant("need foo help", cwd: tmp_dir, max_results: 2)
    assert best.key == "foo-skill"
  end

  test "find_relevant/2 can match on SKILL.md body content", %{tmp_dir: tmp_dir} do
    skill_dir = Path.join([tmp_dir, ".lemon", "skill", "no-desc-match"])
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      """
      ---
      name: no-desc-match
      description: unrelated
      ---

      This skill mentions kubernetes and kubectl in the body.
      """
    )

    LemonSkills.refresh(cwd: tmp_dir)

    [best | _] = LemonSkills.find_relevant("kubectl", cwd: tmp_dir, max_results: 1)
    assert best.key == "no-desc-match"
  end

  test "find_relevant/2 excludes disabled skills via skills.json", %{tmp_dir: tmp_dir} do
    skill_dir = Path.join([tmp_dir, ".lemon", "skill", "disabled-skill"])
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      """
      ---
      name: disabled-skill
      description: Use this when working on disabled things
      ---

      body
      """
    )

    lemon_dir = Path.join(tmp_dir, ".lemon")
    File.mkdir_p!(lemon_dir)

    File.write!(
      Path.join(lemon_dir, "skills.json"),
      ~s({"disabled":["disabled-skill"]})
    )

    LemonSkills.refresh(cwd: tmp_dir)

    results = LemonSkills.find_relevant("disabled", cwd: tmp_dir, max_results: 5)
    refute Enum.any?(results, &(&1.key == "disabled-skill"))
  end
end

