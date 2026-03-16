defmodule LemonSkills.StatusTest do
  use ExUnit.Case, async: false

  alias LemonSkills.{Entry, Status}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous_home = System.get_env("HOME")
    previous_agent_dir = System.get_env("LEMON_AGENT_DIR")

    home = Path.join(tmp_dir, "home")
    agent_dir = Path.join(tmp_dir, "agent")

    File.mkdir_p!(home)
    File.mkdir_p!(agent_dir)

    System.put_env("HOME", home)
    System.put_env("LEMON_AGENT_DIR", agent_dir)
    LemonSkills.refresh()

    on_exit(fn ->
      restore_env("HOME", previous_home)
      restore_env("LEMON_AGENT_DIR", previous_agent_dir)
      LemonSkills.refresh()
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "binary_available?/1" do
    test "returns true for an existing binary and false for a missing binary" do
      existing_binary =
        Enum.find(["elixir", "sh", "env"], &Status.binary_available?/1)

      assert is_binary(existing_binary)
      assert Status.binary_available?(existing_binary)

      missing_binary = "missing-bin-#{System.unique_integer([:positive])}"
      refute Status.binary_available?(missing_binary)
    end
  end

  describe "config_available?/1" do
    test "returns false when env is missing/empty and true when set" do
      config_key = "LEMON_SKILLS_STATUS_#{System.unique_integer([:positive])}"
      previous = System.get_env(config_key)

      on_exit(fn -> restore_env(config_key, previous) end)

      System.delete_env(config_key)
      refute Status.config_available?(config_key)

      System.put_env(config_key, "")
      refute Status.config_available?(config_key)

      System.put_env(config_key, "configured")
      assert Status.config_available?(config_key)
    end
  end

  describe "check/2" do
    test "returns not-found error map for an unknown key", %{tmp_dir: tmp_dir} do
      missing_key = "missing-skill-#{System.unique_integer([:positive])}"

      assert Status.check(missing_key, cwd: tmp_dir) == %{
               activation_state: :not_ready,
               ready: false,
               platform_compatible: true,
               missing_bins: [],
               missing_config: [],
               missing_env_vars: [],
               missing_tools: [],
               disabled: false,
               error: "Skill not found: #{missing_key}"
             }
    end
  end

  describe "check_entry/2" do
    test "returns hidden status when the entry is disabled", %{tmp_dir: tmp_dir} do
      entry = %Entry{
        key: "disabled-skill",
        path: tmp_dir,
        enabled: false,
        manifest: %{"requires" => %{"bins" => ["definitely-missing-bin"]}}
      }

      assert Status.check_entry(entry, cwd: tmp_dir) == %{
               activation_state: :hidden,
               ready: false,
               platform_compatible: true,
               missing_bins: [],
               missing_config: [],
               missing_env_vars: [],
               missing_tools: [],
               disabled: true,
               error: nil
             }
    end

    test "returns active status when entry is ready", %{tmp_dir: tmp_dir} do
      entry = %Entry{key: "simple-skill", path: tmp_dir, enabled: true}

      result = Status.check_entry(entry, cwd: tmp_dir)
      assert result.activation_state == :active
      assert result.ready == true
      assert result.platform_compatible == true
      assert result.disabled == false
    end

    test "returns not_ready when bins are missing", %{tmp_dir: tmp_dir} do
      missing_bin = "definitely-missing-bin-#{System.unique_integer([:positive])}"

      entry = %Entry{
        key: "needs-bin",
        path: tmp_dir,
        enabled: true,
        manifest: %{"requires" => %{"bins" => [missing_bin]}}
      }

      result = Status.check_entry(entry, cwd: tmp_dir)
      assert result.activation_state == :not_ready
      assert result.ready == false
      assert result.missing_bins == [missing_bin]
    end

    test "returns platform_incompatible when platform does not match", %{tmp_dir: tmp_dir} do
      # Use a platform that is definitely not the current one
      bad_platform =
        case :os.type() do
          {:unix, :darwin} -> "win32"
          _ -> "win32"
        end

      entry = %Entry{
        key: "platform-skill",
        path: tmp_dir,
        enabled: true,
        manifest: %{"platforms" => [bad_platform]}
      }

      result = Status.check_entry(entry, cwd: tmp_dir)
      assert result.activation_state == :platform_incompatible
      assert result.ready == false
      assert result.platform_compatible == false
    end
  end

  describe "platform_compatible?/1" do
    test "returns true when platforms includes 'any'" do
      entry = %Entry{
        key: "any-platform",
        path: "/tmp",
        manifest: %{"platforms" => ["any"]}
      }

      assert Status.platform_compatible?(entry)
    end

    test "returns true when manifest is nil" do
      entry = %Entry{key: "no-manifest", path: "/tmp"}
      assert Status.platform_compatible?(entry)
    end

    test "returns true when platforms is absent (defaults to any)" do
      entry = %Entry{key: "no-platforms", path: "/tmp", manifest: %{}}
      # Manifest.platforms/1 defaults to ["any"] when absent
      assert Status.platform_compatible?(entry)
    end

    test "returns false for a platform that does not match current OS" do
      bad_platform =
        case :os.type() do
          {:unix, :darwin} -> "win32"
          _ -> "win32"
        end

      entry = %Entry{
        key: "bad-platform",
        path: "/tmp",
        manifest: %{"platforms" => [bad_platform]}
      }

      refute Status.platform_compatible?(entry)
    end
  end

  describe "missing_env_vars/1" do
    test "returns missing required_environment_variables", %{tmp_dir: _tmp_dir} do
      env_key = "STATUS_ENV_#{System.unique_integer([:positive])}"
      prev = System.get_env(env_key)
      on_exit(fn -> restore_env(env_key, prev) end)

      System.delete_env(env_key)

      entry = %Entry{
        key: "env-skill",
        path: "/tmp",
        manifest: %{"required_environment_variables" => [env_key]}
      }

      assert Status.missing_env_vars(entry) == [env_key]

      System.put_env(env_key, "set")
      assert Status.missing_env_vars(entry) == []
    end

    test "returns [] for entries with no manifest" do
      entry = %Entry{key: "no-manifest", path: "/tmp"}
      assert Status.missing_env_vars(entry) == []
    end
  end

  describe "missing_tools/1" do
    test "returns missing requires_tools binaries" do
      missing = "definitely-missing-tool-#{System.unique_integer([:positive])}"

      entry = %Entry{
        key: "tool-skill",
        path: "/tmp",
        manifest: %{"requires_tools" => [missing]}
      }

      assert Status.missing_tools(entry) == [missing]
    end

    test "returns [] when all tools are present" do
      present = Enum.find(["sh", "env", "elixir"], &Status.binary_available?/1)

      entry = %Entry{
        key: "tool-skill",
        path: "/tmp",
        manifest: %{"requires_tools" => [present]}
      }

      assert Status.missing_tools(entry) == []
    end

    test "returns [] for entries with no manifest" do
      entry = %Entry{key: "no-manifest", path: "/tmp"}
      assert Status.missing_tools(entry) == []
    end
  end

  describe "missing_binaries/1 and missing_config/1" do
    test "returns missing requirements declared in the manifest", %{tmp_dir: tmp_dir} do
      present_binary =
        Enum.find(["elixir", "sh", "env"], &Status.binary_available?/1)

      assert is_binary(present_binary)

      missing_binary = "missing-bin-#{System.unique_integer([:positive])}"
      present_config = "STATUS_SET_#{System.unique_integer([:positive])}"
      missing_config = "STATUS_MISSING_#{System.unique_integer([:positive])}"

      previous_present = System.get_env(present_config)
      previous_missing = System.get_env(missing_config)

      on_exit(fn ->
        restore_env(present_config, previous_present)
        restore_env(missing_config, previous_missing)
      end)

      System.put_env(present_config, "ok")
      System.delete_env(missing_config)

      write_skill!(
        tmp_dir,
        "requires-check",
        """
        ---
        name: requires-check
        description: Checks dependency requirements
        requires:
          bins:
            - #{present_binary}
            - #{missing_binary}
          config:
            - #{present_config}
            - #{missing_config}
        ---

        body
        """
      )

      LemonSkills.refresh(cwd: tmp_dir)

      assert {:ok, entry} = LemonSkills.get("requires-check", cwd: tmp_dir)
      assert Status.missing_binaries(entry) == [missing_binary]
      assert Status.missing_config(entry) == [missing_config]
    end
  end

  defp write_skill!(tmp_dir, key, skill_md) do
    skill_dir = Path.join([tmp_dir, ".lemon", "skill", key])
    File.mkdir_p!(skill_dir)
    File.write!(Path.join(skill_dir, "SKILL.md"), skill_md)
    skill_dir
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
