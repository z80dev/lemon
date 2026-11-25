defmodule LemonSkills.ConfigTest do
  use ExUnit.Case, async: false

  alias LemonSkills.Config

  @moduletag :tmp_dir

  setup do
    previous_agent_dir_env = System.get_env("LEMON_AGENT_DIR")
    previous_lemon_skills_agent_dir = capture_app_env(:lemon_skills, :agent_dir)
    previous_core_agent_dir = capture_app_env(:lemon_core, :agent_dir)

    on_exit(fn ->
      restore_env("LEMON_AGENT_DIR", previous_agent_dir_env)
      restore_app_env(:lemon_skills, :agent_dir, previous_lemon_skills_agent_dir)
      restore_app_env(:lemon_core, :agent_dir, previous_core_agent_dir)
    end)

    :ok
  end

  describe "agent_dir/0" do
    test "uses env first, then :lemon_skills app env, then the core agent-dir override", %{
      tmp_dir: tmp_dir
    } do
      env_agent_dir = Path.join(tmp_dir, "env-agent")
      lemon_skills_agent_dir = Path.join(tmp_dir, "lemon-skills-agent")
      core_agent_dir = Path.join(tmp_dir, "core-agent")

      System.put_env("LEMON_AGENT_DIR", env_agent_dir)
      Application.put_env(:lemon_skills, :agent_dir, lemon_skills_agent_dir)
      Application.put_env(:lemon_core, :agent_dir, core_agent_dir)

      assert Config.agent_dir() == env_agent_dir

      System.delete_env("LEMON_AGENT_DIR")
      assert Config.agent_dir() == lemon_skills_agent_dir

      Application.delete_env(:lemon_skills, :agent_dir)
      assert Config.agent_dir() == core_agent_dir
    end
  end

  describe "load_config/1" do
    test "a project skills.json can disable and slow the learning nudge", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "project")
      System.put_env("LEMON_AGENT_DIR", Path.join(tmp_dir, "agent"))
      File.mkdir_p!(project_dir)

      write_json!(Config.project_config_file(project_dir), %{
        "disabled" => ["project-disabled", 7],
        "learning_nudge" => %{
          "enabled" => false,
          "memory_turn_interval" => 40,
          "skill_tool_threshold" => "99",
          "background_review" => %{"enabled" => true}
        }
      })

      assert Config.load_config(project_dir) == %{
               "disabled" => ["project-disabled"],
               "learning_nudge" => %{"enabled" => false, "memory_turn_interval" => 40}
             }

      assert Config.load_config() == %{}
    end

    test "a project skills.json can only narrow the operator config", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "project")
      System.put_env("LEMON_AGENT_DIR", Path.join(tmp_dir, "agent"))
      File.mkdir_p!(project_dir)

      write_json!(Config.global_config_file(), %{
        "disabled" => ["operator-disabled"],
        "learning_nudge" => %{"enabled" => false, "memory_turn_interval" => 20},
        "skills" => %{"lint" => %{"endpoint" => "https://operator.example"}}
      })

      write_json!(Config.project_config_file(project_dir), %{
        "disabled" => ["project-disabled"],
        "learning_nudge" => %{
          "enabled" => true,
          "memory_turn_interval" => 1,
          "skill_tool_threshold" => 1
        },
        "skills" => %{"lint" => %{"endpoint" => "https://attacker.example"}},
        "mode" => "project"
      })

      config = Config.load_config(project_dir)

      assert Enum.sort(config["disabled"]) == ["operator-disabled", "project-disabled"]
      assert Config.skill_disabled?("operator-disabled", project_dir)
      assert config["learning_nudge"] == %{"enabled" => false, "memory_turn_interval" => 20}
      assert config["skills"] == %{"lint" => %{"endpoint" => "https://operator.example"}}
      refute Map.has_key?(config, "mode")
    end
  end

  describe "disable/2, enable/2, and skill_disabled?/2" do
    test "updates project config only when global: false", %{tmp_dir: tmp_dir} do
      agent_dir = Path.join(tmp_dir, "agent")
      project_dir = Path.join(tmp_dir, "project")

      System.put_env("LEMON_AGENT_DIR", agent_dir)
      File.mkdir_p!(project_dir)

      write_json!(Config.global_config_file(), %{"disabled" => ["global-only"]})

      refute Config.skill_disabled?("local-skill", project_dir)

      assert :ok = Config.disable("local-skill", global: false, cwd: project_dir)
      assert Config.skill_disabled?("local-skill", project_dir)
      refute Config.skill_disabled?("local-skill")

      assert read_json!(Config.project_config_file(project_dir)) == %{
               "disabled" => ["local-skill"]
             }

      assert :ok = Config.disable("local-skill", global: false, cwd: project_dir)

      assert read_json!(Config.project_config_file(project_dir)) == %{
               "disabled" => ["local-skill"]
             }

      assert :ok = Config.enable("local-skill", global: false, cwd: project_dir)
      refute Config.skill_disabled?("local-skill", project_dir)

      assert read_json!(Config.project_config_file(project_dir)) == %{
               "disabled" => []
             }

      assert read_json!(Config.global_config_file()) == %{"disabled" => ["global-only"]}
    end
  end

  describe "set_skill_config/2 and get_skill_config/1" do
    test "per-skill configuration is operator-only", %{tmp_dir: tmp_dir} do
      System.put_env("LEMON_AGENT_DIR", Path.join(tmp_dir, "agent"))
      skill_config = %{"timeout" => 10, "nested" => %{"a" => 1}}

      assert :ok = Config.set_skill_config("lint", skill_config)
      assert Config.get_skill_config("lint") == skill_config
      assert read_json!(Config.global_config_file()) == %{"skills" => %{"lint" => skill_config}}
      assert Config.get_skill_config("other") == %{}
    end
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
