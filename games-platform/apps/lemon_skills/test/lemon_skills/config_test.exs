defmodule LemonSkills.ConfigTest do
  use ExUnit.Case, async: false

  alias LemonSkills.Config

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

  describe "load_config/1" do
    test "deep merges global and project configs with project precedence", %{tmp_dir: tmp_dir} do
      agent_dir = Path.join(tmp_dir, "agent")
      project_dir = Path.join(tmp_dir, "project")

      System.put_env("LEMON_AGENT_DIR", agent_dir)
      File.mkdir_p!(project_dir)

      global_config = %{
        "disabled" => ["global-disabled"],
        "mode" => "global",
        "skills" => %{
          "global-only" => %{"level" => "global"},
          "shared" => %{
            "global_only" => true,
            "nested" => %{"keep" => 1, "override" => "global"}
          }
        }
      }

      project_config = %{
        "disabled" => ["project-disabled"],
        "mode" => "project",
        "skills" => %{
          "project-only" => %{"level" => "project"},
          "shared" => %{
            "nested" => %{"override" => "project", "project_only" => 2},
            "project_only" => true
          }
        }
      }

      write_json!(Config.global_config_file(), global_config)
      write_json!(Config.project_config_file(project_dir), project_config)

      assert Config.load_config(project_dir) == %{
               "disabled" => ["project-disabled"],
               "mode" => "project",
               "skills" => %{
                 "global-only" => %{"level" => "global"},
                 "project-only" => %{"level" => "project"},
                 "shared" => %{
                   "global_only" => true,
                   "nested" => %{"keep" => 1, "override" => "project", "project_only" => 2},
                   "project_only" => true
                 }
               }
             }
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

  describe "set_skill_config/3 and get_skill_config/2" do
    test "sets and reads project skill config when global: false", %{tmp_dir: tmp_dir} do
      agent_dir = Path.join(tmp_dir, "agent")
      project_dir = Path.join(tmp_dir, "project")

      System.put_env("LEMON_AGENT_DIR", agent_dir)
      File.mkdir_p!(project_dir)

      global_skill_config = %{
        "timeout" => 10,
        "nested" => %{"a" => 1, "b" => 2},
        "global_only" => true
      }

      write_json!(Config.global_config_file(), %{
        "skills" => %{
          "lint" => global_skill_config
        }
      })

      project_skill_config = %{
        "timeout" => 30,
        "nested" => %{"b" => 99},
        "project_only" => true
      }

      assert :ok =
               Config.set_skill_config("lint", project_skill_config,
                 global: false,
                 cwd: project_dir
               )

      assert Config.get_skill_config("lint", project_dir) == %{
               "timeout" => 30,
               "nested" => %{"a" => 1, "b" => 99},
               "global_only" => true,
               "project_only" => true
             }

      assert Config.get_skill_config("lint") == global_skill_config

      assert read_json!(Config.project_config_file(project_dir)) == %{
               "skills" => %{
                 "lint" => project_skill_config
               }
             }
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
