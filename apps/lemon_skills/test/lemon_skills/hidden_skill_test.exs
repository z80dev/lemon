defmodule LemonSkills.HiddenSkillTest do
  use ExUnit.Case, async: false

  alias LemonSkills.{PromptView, SkillView}
  alias LemonSkills.Tools.ReadSkill

  @moduletag :tmp_dir

  defp write_skill(root, key, frontmatter) do
    dir = Path.join([root, ".lemon", "skill", key])
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "SKILL.md"), """
    ---
    name: #{key}
    description: Zebra stripes handbook for #{key}
    #{frontmatter}
    ---

    Body of #{key}
    """)
  end

  test "hide / disable-model-invocation skills leave model prompts but stay loadable",
       %{tmp_dir: cwd} do
    write_skill(cwd, "hide-true", "hide: true")
    write_skill(cwd, "dmi-true", "disable-model-invocation: true")
    write_skill(cwd, "hide-false", "hide: false")
    write_skill(cwd, "dmi-false", "disable-model-invocation: false")
    write_skill(cwd, "hide-junk", "hide: \"yes\"")
    write_skill(cwd, "plain", "")
    LemonSkills.refresh(cwd: cwd)

    on_exit(fn -> LemonSkills.refresh() end)

    hidden = ["hide-true", "dmi-true"]
    visible = ["hide-false", "dmi-false", "hide-junk", "plain"]

    # Stable prompt listing omits only hidden skills.
    prompt = PromptView.render_for_prompt(cwd)
    for key <- visible, do: assert(prompt =~ "<key>#{key}</key>")
    for key <- hidden, do: refute(prompt =~ key)

    # Turn-local relevance selection (as CodingAgent.Session does) omits them too,
    # although the registry still surfaces them as relevant matches.
    matches = LemonSkills.find_relevant("zebra stripes handbook", cwd: cwd, max_results: 10)
    match_keys = Enum.map(matches, & &1.key)
    for key <- hidden ++ visible, do: assert(key in match_keys)

    prompt_keys =
      matches
      |> Enum.map(&SkillView.from_entry(&1, cwd: cwd))
      |> Enum.filter(&SkillView.prompt_visible?/1)
      |> Enum.map(& &1.key)

    assert Enum.sort(prompt_keys) == Enum.sort(visible)

    missing = ReadSkill.execute("missing", %{"key" => "not-a-skill"}, nil, nil, cwd)
    suggestions = Enum.map_join(missing.content, "\n", &Map.get(&1, :text, ""))
    for key <- hidden, do: refute(suggestions =~ key)
    for key <- visible, do: assert(suggestions =~ key)

    # Listing and explicit loads are unaffected.
    listed = LemonSkills.list(cwd: cwd) |> Enum.map(& &1.key)
    for key <- hidden, do: assert(key in listed)

    for key <- hidden do
      result = ReadSkill.execute("t-#{key}", %{"key" => key}, nil, nil, cwd)
      assert result.details[:error] == nil
      assert Enum.any?(result.content, &(Map.get(&1, :text, "") =~ "Body of #{key}"))
    end
  end
end
