defmodule LemonSkills.BuiltinSeederTest do
  use ExUnit.Case, async: true

  alias LemonSkills.{BuiltinSeeder, Config}

  @moduletag :tmp_dir

  test "seeds repo-bundled skills into the global skills dir when missing", %{tmp_dir: tmp_dir} do
    prev_home = System.get_env("HOME")

    home = Path.join(tmp_dir, "home")
    File.mkdir_p!(home)
    System.put_env("HOME", home)

    try do
      # Ensure destination is clean
      File.rm_rf!(Config.global_skills_dir())
      Config.ensure_dirs!()

      assert not File.dir?(Path.join(Config.global_skills_dir(), "skill-creator"))

      assert :ok == BuiltinSeeder.seed!(enabled: true)

      skill_file =
        Path.join([Config.global_skills_dir(), "skill-creator", "SKILL.md"])

      assert File.regular?(skill_file)
      contents = File.read!(skill_file)
      assert contents =~ "name: skill-creator"
      refute contents =~ "Codex"

      pinata_skill_file =
        Path.join([Config.global_skills_dir(), "pinata", "SKILL.md"])

      assert File.regular?(pinata_skill_file)
      pinata_contents = File.read!(pinata_skill_file)
      assert pinata_contents =~ "name: pinata"
    after
      if is_nil(prev_home), do: System.delete_env("HOME"), else: System.put_env("HOME", prev_home)
    end
  end

  test "does not overwrite existing destination skill directories", %{tmp_dir: tmp_dir} do
    prev_home = System.get_env("HOME")

    home = Path.join(tmp_dir, "home")
    File.mkdir_p!(home)
    System.put_env("HOME", home)

    try do
      dest_dir = Path.join(Config.global_skills_dir(), "skill-creator")
      File.mkdir_p!(dest_dir)

      File.write!(
        Path.join(dest_dir, "SKILL.md"),
        """
        ---
        name: skill-creator
        description: user customized
        ---
        """
      )

      assert :ok == BuiltinSeeder.seed!(enabled: true)

      assert File.read!(Path.join(dest_dir, "SKILL.md")) =~ "user customized"
    after
      if is_nil(prev_home), do: System.delete_env("HOME"), else: System.put_env("HOME", prev_home)
    end
  end
end
