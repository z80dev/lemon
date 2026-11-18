defmodule LemonSkills.Doctor.Checks.SkillsTest do
  use ExUnit.Case, async: false

  alias LemonCore.Doctor.Check
  alias LemonSkills.Doctor.Checks.Skills

  setup do
    previous_env = System.get_env("LEMON_AGENT_DIR")
    agent_dir = Path.join(System.tmp_dir!(), "skills_check_#{System.unique_integer([:positive])}")
    System.put_env("LEMON_AGENT_DIR", agent_dir)

    on_exit(fn ->
      if previous_env,
        do: System.put_env("LEMON_AGENT_DIR", previous_env),
        else: System.delete_env("LEMON_AGENT_DIR")

      File.rm_rf!(agent_dir)
    end)

    %{skills_dir: Path.join(agent_dir, "skill")}
  end

  test "skips when the global skills directory does not exist yet", %{skills_dir: dir} do
    assert [%Check{name: "skills.directory", status: :skip} = check] = Skills.run()
    # Doctor output is shared: the directory appears only as its label.
    assert check.message =~ LemonCore.Doctor.Redaction.path_label(dir)
    refute check.message =~ dir
  end

  test "counts installed skills in the global skills directory", %{skills_dir: dir} do
    File.mkdir_p!(Path.join(dir, "alpha"))
    File.mkdir_p!(Path.join(dir, "beta"))
    File.write!(Path.join(dir, "README.md"), "not a skill")

    assert [%Check{name: "skills.directory", status: :pass} = check] = Skills.run()
    assert check.message =~ "2 skill(s) installed"
  end

  test "fails when a file occupies the skills directory path", %{skills_dir: dir} do
    File.mkdir_p!(Path.dirname(dir))
    File.write!(dir, "")

    assert [%Check{name: "skills.directory", status: :fail} = check] = Skills.run()
    assert check.remediation =~ LemonCore.Doctor.Redaction.path_label(dir)
    refute check.remediation =~ dir
  end
end
