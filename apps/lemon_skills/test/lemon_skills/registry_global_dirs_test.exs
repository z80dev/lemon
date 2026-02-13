defmodule LemonSkills.RegistryGlobalDirsTest do
  use ExUnit.Case, async: false

  test "loads skills from ~/.agents/skills" do
    skill_name = "agents-global-#{System.unique_integer([:positive])}"
    skill_dir = Path.join([System.user_home!(), ".agents", "skills", skill_name])

    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      """
      ---
      name: #{skill_name}
      description: Global skill from ~/.agents/skills
      ---

      body
      """
    )

    on_exit(fn ->
      File.rm_rf(skill_dir)
      LemonSkills.refresh()
    end)

    LemonSkills.refresh()

    assert {:ok, entry} = LemonSkills.get(skill_name)
    assert entry.path == skill_dir
  end
end
