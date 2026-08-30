defmodule LemonSkills.RegistryRelevanceTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  test "find_relevant/2 scores by key/name/description and returns best matches", %{
    tmp_dir: tmp_dir
  } do
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

  test "find_relevant/2 matches string-key keywords with no other matching signal", %{
    tmp_dir: tmp_dir
  } do
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
      keywords:
        - docker
        - container
        - deployment
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

    # The key, name, description, and body do not contain "docker". This is a
    # keyword-only match and protects the parser's string-key manifest shape.
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

  test "invalidates cached body excerpts when SKILL.md changes", %{tmp_dir: tmp_dir} do
    skill_dir = Path.join([tmp_dir, ".lemon", "skill", "cached-body"])
    skill_file = Path.join(skill_dir, "SKILL.md")
    File.mkdir_p!(skill_dir)

    File.write!(
      skill_file,
      "---\nname: Cached Body\ndescription: Generic helper\n---\nquasarneedle"
    )

    LemonSkills.refresh(cwd: tmp_dir)
    assert [%{key: "cached-body"}] = LemonSkills.find_relevant("quasarneedle", cwd: tmp_dir)

    File.write!(
      skill_file,
      "---\nname: Cached Body\ndescription: Generic helper\n---\ncosmicneedle"
    )

    Process.sleep(75)

    assert [] = LemonSkills.find_relevant("quasarneedle", cwd: tmp_dir)
    assert [%{key: "cached-body"}] = LemonSkills.find_relevant("cosmicneedle", cwd: tmp_dir)
  end

  test "invalidates disabled filtering and requirement views without refresh", %{tmp_dir: tmp_dir} do
    env_key = "LEMON_SKILL_CACHE_PROBE_#{System.unique_integer([:positive])}"
    System.delete_env(env_key)
    on_exit(fn -> System.delete_env(env_key) end)

    skill_dir = Path.join([tmp_dir, ".lemon", "skill", "dynamic-status"])
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      "---\nname: Dynamic Status\ndescription: statuscacheprobe helper\nrequires:\n  config:\n    - #{env_key}\n---\nbody"
    )

    LemonSkills.refresh(cwd: tmp_dir)

    assert [%{activation_state: :not_ready}] =
             LemonSkills.Registry.list_views(cwd: tmp_dir)
             |> Enum.filter(&(&1.key == "dynamic-status"))

    System.put_env(env_key, "present")

    assert [%{activation_state: :active}] =
             LemonSkills.Registry.list_views(cwd: tmp_dir)
             |> Enum.filter(&(&1.key == "dynamic-status"))

    File.mkdir_p!(Path.join(tmp_dir, ".lemon"))

    File.write!(
      Path.join([tmp_dir, ".lemon", "skills.json"]),
      ~s({"disabled":["dynamic-status"]})
    )

    Process.sleep(75)

    assert [] = LemonSkills.find_relevant("statuscacheprobe", cwd: tmp_dir)

    assert [%{activation_state: :hidden}] =
             LemonSkills.Registry.list_views(cwd: tmp_dir)
             |> Enum.filter(&(&1.key == "dynamic-status"))
  end

  test "discovers added and removed skill paths without refresh", %{tmp_dir: tmp_dir} do
    LemonSkills.refresh(cwd: tmp_dir)
    assert :error = LemonSkills.get("late-skill", cwd: tmp_dir)

    skill_dir = Path.join([tmp_dir, ".lemon", "skill", "late-skill"])
    File.mkdir_p!(skill_dir)
    File.write!(Path.join(skill_dir, "SKILL.md"), "---\nname: Late Skill\n---\nbody")

    Process.sleep(75)

    assert {:ok, %{key: "late-skill"}} = LemonSkills.get("late-skill", cwd: tmp_dir)

    File.rm_rf!(skill_dir)
    Process.sleep(75)
    assert :error = LemonSkills.get("late-skill", cwd: tmp_dir)
  end

  test "breaks equal-score ties by stable skill key", %{tmp_dir: tmp_dir} do
    for key <- ["zeta-helper", "alpha-helper"] do
      skill_dir = Path.join([tmp_dir, ".lemon", "skill", key])
      File.mkdir_p!(skill_dir)

      File.write!(
        Path.join(skill_dir, "SKILL.md"),
        "---\nname: Generic Helper\ndescription: Handles tieprobe jobs\n---\nbody"
      )
    end

    LemonSkills.refresh(cwd: tmp_dir)

    assert Enum.map(LemonSkills.find_relevant("tieprobe", cwd: tmp_dir), & &1.key) == [
             "alpha-helper",
             "zeta-helper"
           ]
  end

  test "serves concurrent cached relevance and lookup calls", %{tmp_dir: tmp_dir} do
    skill_dir = Path.join([tmp_dir, ".lemon", "skill", "parallel-helper"])
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      "---\nname: Parallel Helper\ndescription: Handles concurrencyprobe jobs\n---\nbody"
    )

    LemonSkills.refresh(cwd: tmp_dir)

    tasks =
      for index <- 1..40 do
        Task.async(fn ->
          if rem(index, 2) == 0 do
            LemonSkills.find_relevant("concurrencyprobe", cwd: tmp_dir, max_results: 1)
          else
            LemonSkills.get("parallel-helper", cwd: tmp_dir)
          end
        end)
      end

    results = Task.await_many(tasks, 2_000)

    assert Enum.count(results, &match?([%{key: "parallel-helper"}], &1)) == 20
    assert Enum.count(results, &match?({:ok, %{key: "parallel-helper"}}, &1)) == 20
  end
end
