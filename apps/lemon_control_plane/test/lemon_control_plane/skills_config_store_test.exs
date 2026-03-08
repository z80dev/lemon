defmodule LemonControlPlane.SkillsConfigStoreTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.SkillsConfigStore

  test "stores fallback skill enabled and env config through the typed wrapper" do
    cwd = "/tmp/skills-#{System.unique_integer([:positive])}"
    skill_key = "skill-#{System.unique_integer([:positive])}"
    env = %{"API_KEY" => "secret"}

    assert :ok = SkillsConfigStore.put_enabled(cwd, skill_key, true)
    assert :ok = SkillsConfigStore.put_env(cwd, skill_key, env)

    assert SkillsConfigStore.get_enabled(cwd, skill_key) == true
    assert SkillsConfigStore.get_env(cwd, skill_key) == env

    assert SkillsConfigStore.get_config(cwd, skill_key) == %{
             "enabled" => true,
             "env" => env
           }
  end
end
