defmodule LemonSkills.ConfigTest do
  use ExUnit.Case, async: false

  alias LemonCore.Doctor.Check
  alias LemonSkills.{Config, PromptView, Usage}

  @moduletag :tmp_dir

  setup do
    previous_agent_dir_env = System.get_env("LEMON_AGENT_DIR")
    previous_lemon_skills_agent_dir = capture_app_env(:lemon_skills, :agent_dir)
    previous_coding_agent_agent_dir = capture_app_env(:coding_agent, :agent_dir)

    on_exit(fn ->
      restore_env("LEMON_AGENT_DIR", previous_agent_dir_env)
      restore_app_env(:lemon_skills, :agent_dir, previous_lemon_skills_agent_dir)
      restore_app_env(:coding_agent, :agent_dir, previous_coding_agent_agent_dir)
    end)

    :ok
  end

  describe "agent_dir/0" do
    test "uses env first, then :lemon_skills app env, then :coding_agent app env", %{
      tmp_dir: tmp_dir
    } do
      env_agent_dir = Path.join(tmp_dir, "env-agent")
      lemon_skills_agent_dir = Path.join(tmp_dir, "lemon-skills-agent")
      coding_agent_agent_dir = Path.join(tmp_dir, "coding-agent")

      System.put_env("LEMON_AGENT_DIR", env_agent_dir)
      Application.put_env(:lemon_skills, :agent_dir, lemon_skills_agent_dir)
      Application.put_env(:coding_agent, :agent_dir, coding_agent_agent_dir)

      assert Config.agent_dir() == env_agent_dir

      System.delete_env("LEMON_AGENT_DIR")
      assert Config.agent_dir() == lemon_skills_agent_dir

      Application.delete_env(:lemon_skills, :agent_dir)
      assert Config.agent_dir() == coding_agent_agent_dir
    end
  end

  describe "disabled_keys/1 and skill_disabled?/2" do
    test "unites the global and project disabled lists; the project prompt omits both",
         %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "project")
      System.put_env("LEMON_AGENT_DIR", Path.join(tmp_dir, "agent"))
      for key <- ["a", "b", "c"], do: write_project_skill!(project_dir, key)

      write_json!(Config.global_config_file(), %{"disabled" => ["a"]})
      write_json!(Config.project_config_file(project_dir), %{"disabled" => ["b"]})

      assert {:ok, keys} = Config.disabled_keys(project_dir)
      assert Enum.sort(keys) == ["a", "b"]
      assert {:ok, global_keys} = Config.disabled_keys()
      assert Enum.sort(global_keys) == ["a"]
      assert Config.skill_disabled?("a", project_dir)
      assert Config.skill_disabled?("b", project_dir)
      refute Config.skill_disabled?("c", project_dir)
      refute Config.skill_disabled?("b")

      LemonSkills.refresh(cwd: project_dir)
      on_exit(fn -> LemonSkills.refresh() end)

      prompt = PromptView.render_for_prompt(project_dir)
      assert prompt =~ "<key>c</key>"
      refute prompt =~ "<key>a</key>"
      refute prompt =~ "<key>b</key>"
    end

    test "settings keys in skills.json are ignored", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "project")
      System.put_env("LEMON_AGENT_DIR", Path.join(tmp_dir, "agent"))

      write_json!(Config.project_config_file(project_dir), %{
        "learning_nudge" => %{"enabled" => false},
        "skills" => %{"lint" => %{"endpoint" => "https://attacker.example"}}
      })

      assert {:ok, keys} = Config.disabled_keys(project_dir)
      assert MapSet.size(keys) == 0
    end
  end

  describe "disable/2 and enable/2" do
    test "a project enable leaves globally disabled and archived skills disabled",
         %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "project")
      System.put_env("LEMON_AGENT_DIR", Path.join(tmp_dir, "agent"))
      File.mkdir_p!(project_dir)
      project = [global: false, cwd: project_dir]

      write_json!(Config.global_config_file(), %{"disabled" => ["global-off", "global-archived"]})
      assert :ok = Usage.set_state("global-archived", :archived)

      # The curator archives a project skill: disabled, then marked archived.
      assert :ok = Config.disable("archived", project)
      assert :ok = Usage.set_state("archived", :archived, scope: :project, cwd: project_dir)
      assert :ok = Config.disable("local-off", project)
      assert :ok = Config.disable("local-off", project)

      assert read_json!(Config.project_config_file(project_dir)) == %{
               "disabled" => ["archived", "local-off"]
             }

      global_before = File.read!(Config.global_config_file())

      assert {:error, :disabled_globally} = Config.enable("global-off", project)
      assert {:error, :disabled_globally} = Config.enable("global-archived", project)
      assert {:error, :archived} = Config.enable("archived", project)
      assert {:error, :archived} = Config.enable("global-archived")
      assert :ok = Config.enable("local-off", project)

      assert File.read!(Config.global_config_file()) == global_before
      assert read_json!(Config.project_config_file(project_dir)) == %{"disabled" => ["archived"]}

      for key <- ["global-off", "global-archived", "archived"],
          do: assert(Config.skill_disabled?(key, project_dir))

      refute Config.skill_disabled?("local-off", project_dir)
      assert Usage.archived?("archived", scope: :project, cwd: project_dir)
      assert Usage.archived?("global-archived")
    end

    test "enable writes nothing without a key to remove and never leaves an empty list",
         %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "project")
      System.put_env("LEMON_AGENT_DIR", Path.join(tmp_dir, "agent"))
      project = [global: false, cwd: project_dir]
      path = Config.project_config_file(project_dir)

      assert :ok = Config.enable("never-disabled", project)
      refute File.exists?(path)

      assert :ok = Config.disable("local-skill", project)
      assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
      refute Config.skill_disabled?("local-skill")

      assert :ok = Config.enable("local-skill", project)
      assert read_json!(path) == %{}
      refute Config.skill_disabled?("local-skill", project_dir)

      assert {:error, :missing_cwd} = Config.disable("x", global: false)
    end

    test "a corrupt skills.json re-enables nothing and the doctor reports it",
         %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "project")
      System.put_env("LEMON_AGENT_DIR", Path.join(tmp_dir, "agent"))
      write_project_skill!(project_dir, "visible")
      global = Config.global_config_file()
      File.mkdir_p!(Path.dirname(global))

      for {bytes, reason} <- [
            {~s({"disabled": ["visible"]), :invalid_json},
            {~s(["visible"]), :not_an_object},
            {~s({"disabled": "visible"}), :invalid_disabled}
          ] do
        File.write!(global, bytes)

        assert {:error, {:skills_state, :global, ^reason}} = Config.disabled_keys(project_dir)
        assert Config.skill_disabled?("visible", project_dir)
        assert Config.skill_disabled?("anything-else")
        assert {:error, {:skills_state, :global, ^reason}} = Config.enable("visible")
        assert {:error, {:skills_state, :global, ^reason}} = Config.disable("other")
        assert File.read!(global) == bytes

        assert [%Check{status: :fail} = check] =
                 project_dir |> doctor() |> Enum.filter(&(&1.name == "skills.state"))

        assert check.message =~ to_string(reason)
      end

      LemonSkills.refresh(cwd: project_dir)
      on_exit(fn -> LemonSkills.refresh() end)
      refute PromptView.render_for_prompt(project_dir) =~ "<key>visible</key>"
      assert LemonSkills.find_relevant("visible", cwd: project_dir) == []

      File.write!(global, ~s({"disabled": []}))
      project_state = Config.project_config_file(project_dir)
      File.write!(project_state, "not json")

      assert {:error, {:skills_state, :project, :invalid_json}} =
               Config.disabled_keys(project_dir)

      assert {:error, {:skills_state, :project, :invalid_json}} =
               Config.enable("visible", global: false, cwd: project_dir)

      assert File.read!(project_state) == "not json"
      assert Config.skill_disabled?("visible", project_dir)
      refute Config.skill_disabled?("visible")

      File.rm!(project_state)

      assert [%Check{status: :pass}] =
               Enum.filter(doctor(project_dir), &(&1.name == "skills.state"))
    end
  end

  defp doctor(project_dir), do: LemonSkills.Doctor.Checks.Skills.run(project_dir: project_dir)

  defp write_project_skill!(project_dir, key) do
    dir = Path.join(Config.project_skills_dir(project_dir), key)
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "SKILL.md"), """
    ---
    name: #{key}
    description: Visible test skill #{key}
    ---

    Body of #{key}
    """)

    {:ok, hash} = LemonSkills.Bundle.compute_hash(dir)
    :ok = LemonSkills.Audit.State.authorize({:project, project_dir}, key, hash, :pass)
  end

  defp write_json!(path, data) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(data, pretty: true))
  end

  defp read_json!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
  end

  defp capture_app_env(app, key) do
    case Application.fetch_env(app, key) do
      {:ok, value} -> {:set, value}
      :error -> :unset
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp restore_app_env(app, key, :unset), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, {:set, value}), do: Application.put_env(app, key, value)
end
