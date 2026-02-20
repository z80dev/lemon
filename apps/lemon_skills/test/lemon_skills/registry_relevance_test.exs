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

  test "find_relevant/2 prioritizes exact name matches", %{tmp_dir: tmp_dir} do
    # Create skills where one has an exact name match
    exact_dir = Path.join([tmp_dir, ".lemon", "skill", "kubernetes"])
    partial_dir = Path.join([tmp_dir, ".lemon", "skill", "kubernetes-helper"])
    File.mkdir_p!(exact_dir)
    File.mkdir_p!(partial_dir)

    File.write!(
      Path.join(exact_dir, "SKILL.md"),
      """
      ---
      name: kubernetes
      description: A generic skill
      ---

      body
      """
    )

    File.write!(
      Path.join(partial_dir, "SKILL.md"),
      """
      ---
      name: kubernetes-helper
      description: Better description for kubernetes
      ---

      body
      """
    )

    LemonSkills.refresh(cwd: tmp_dir)

    # Exact match should win even with worse description
    [best | _] = LemonSkills.find_relevant("kubernetes", cwd: tmp_dir, max_results: 2)
    assert best.key == "kubernetes"
  end

  test "find_relevant/2 scores keywords highly", %{tmp_dir: tmp_dir} do
    # Create skills where one has matching keywords
    keyword_dir = Path.join([tmp_dir, ".lemon", "skill", "docker-expert"])
    other_dir = Path.join([tmp_dir, ".lemon", "skill", "other-skill"])
    File.mkdir_p!(keyword_dir)
    File.mkdir_p!(other_dir)

    File.write!(
      Path.join(keyword_dir, "SKILL.md"),
      """
      ---
      name: docker-expert
      description: A generic skill
      keywords: ["docker", "container", "deployment"]
      ---

      body
      """
    )

    File.write!(
      Path.join(other_dir, "SKILL.md"),
      """
      ---
      name: other-skill
      description: A skill about something else entirely
      ---

      body
      """
    )

    LemonSkills.refresh(cwd: tmp_dir)

    # Keyword match should win when other skill has no match
    [best | _] = LemonSkills.find_relevant("docker", cwd: tmp_dir, max_results: 2)
    assert best.key == "docker-expert"
  end

  test "find_relevant/2 prefers project skills over global", %{tmp_dir: tmp_dir} do
    # Create a global skill directory
    global_dir = Path.join([tmp_dir, ".lemon", "skill", "shared-skill"])
    File.mkdir_p!(global_dir)

    File.write!(
      Path.join(global_dir, "SKILL.md"),
      """
      ---
      name: shared-skill
      description: Global version
      ---

      body
      """
    )

    # Create a project skill directory
    project_dir = Path.join([tmp_dir, ".lemon", "skill", "project-skill"])
    File.mkdir_p!(project_dir)

    File.write!(
      Path.join(project_dir, "SKILL.md"),
      """
      ---
      name: project-skill
      description: Project version with matching term
      ---

      body
      """
    )

    LemonSkills.refresh(cwd: tmp_dir)

    # Both have similar relevance, but project skill should be first
    results = LemonSkills.find_relevant("matching term", cwd: tmp_dir, max_results: 2)
    assert hd(results).key == "project-skill"
  end
end

