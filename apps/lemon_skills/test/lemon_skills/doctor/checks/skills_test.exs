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

    project_dir = Path.join(agent_dir, "project")
    File.mkdir_p!(project_dir)
    %{skills_dir: Path.join(agent_dir, "skill"), agent_dir: agent_dir, project_dir: project_dir}
  end

  defp run(ctx), do: Skills.run(project_dir: ctx.project_dir)

  test "skips when the global skills directory does not exist yet", %{skills_dir: dir} = ctx do
    assert [%Check{name: "skills.directory", status: :skip} = check, state] = run(ctx)
    assert %Check{name: "skills.state", status: :pass} = state
    # Doctor output is shared: the directory appears only as its label.
    assert check.message =~ LemonCore.Doctor.Redaction.path_label(dir)
    refute check.message =~ dir
  end

  test "counts installed skills in the global skills directory", %{skills_dir: dir} = ctx do
    File.mkdir_p!(Path.join(dir, "alpha"))
    File.mkdir_p!(Path.join(dir, "beta"))
    File.write!(Path.join(dir, "README.md"), "not a skill")

    assert [%Check{name: "skills.directory", status: :pass} = check, _state] = run(ctx)
    assert check.message =~ "2 skill(s) installed"
  end

  test "fails when a file occupies the skills directory path", %{skills_dir: dir} = ctx do
    File.mkdir_p!(Path.dirname(dir))
    File.write!(dir, "")

    assert [%Check{name: "skills.directory", status: :fail} = check, _state] = run(ctx)
    assert check.remediation =~ LemonCore.Doctor.Redaction.path_label(dir)
    refute check.remediation =~ dir
  end

  test "fails on unusable skill state without printing paths or content", ctx do
    path = Path.join(ctx.project_dir, ".lemon/skills.json")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, ~s({"disabled": "secret-skill-name"}))

    assert [_dir, %Check{name: "skills.state", status: :fail} = check] = run(ctx)
    assert check.message =~ "invalid_disabled"
    assert check.message =~ "every skill is hidden"
    refute check.message =~ ctx.project_dir
    refute check.message =~ "secret-skill-name"
  end

  test "warns about settings left in skills.json", ctx do
    File.mkdir_p!(ctx.agent_dir)

    File.write!(
      Path.join(ctx.agent_dir, "skills.json"),
      ~s({"disabled": [], "learning_nudge": {}, "private-key-name": 1})
    )

    assert [_dir, %Check{name: "skills.state", status: :warn} = check] = run(ctx)
    assert check.message =~ "learning_nudge, 1 other key(s)"
    assert check.remediation =~ "[skills.learning_nudge]"
    refute check.message =~ "private-key-name"
  end
end
