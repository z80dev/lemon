defmodule LemonSkills.RegistryGlobalDirsTest do
  use ExUnit.Case, async: false

  alias LemonSkills.Config

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous_harness_dir_env = System.get_env("LEMON_HARNESS_SKILLS_DIR")
    previous_harness_dir = Application.get_env(:lemon_skills, :harness_global_skills_dir)
    harness_dir = Path.join(tmp_dir, "harness-skills")

    System.put_env("LEMON_HARNESS_SKILLS_DIR", harness_dir)

    on_exit(fn ->
      restore_env("LEMON_HARNESS_SKILLS_DIR", previous_harness_dir_env)
      restore_app_env(:lemon_skills, :harness_global_skills_dir, previous_harness_dir)
      LemonSkills.refresh()
    end)

    :ok
  end

  test "loads skills from ~/.agents/skills" do
    skill_name = "agents-global-#{System.unique_integer([:positive])}"
    skill_dir = Path.join(Config.harness_global_skills_dir(), skill_name)

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

  test "skips invalid manifests when loading ~/.agents/skills entries" do
    skill_name = "agents-invalid-#{System.unique_integer([:positive])}"
    skill_dir = Path.join(Config.harness_global_skills_dir(), skill_name)

    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      """
      ---
      name: #{skill_name}
      platforms: linux
      ---

      body
      """
    )

    on_exit(fn ->
      File.rm_rf(skill_dir)
      LemonSkills.refresh()
    end)

    LemonSkills.refresh()

    assert :error = LemonSkills.get(skill_name)
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)
end
