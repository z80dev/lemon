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
               ready: false,
               missing_bins: [],
               missing_config: [],
               disabled: false,
               error: "Skill not found: #{missing_key}"
             }
    end
  end

  describe "check_entry/2" do
    test "returns disabled status when the entry is disabled", %{tmp_dir: tmp_dir} do
      entry = %Entry{
        key: "disabled-skill",
        path: tmp_dir,
        enabled: false,
        manifest: %{"requires" => %{"bins" => ["definitely-missing-bin"]}}
      }

      assert Status.check_entry(entry, cwd: tmp_dir) == %{
               ready: false,
               missing_bins: [],
               missing_config: [],
               disabled: true,
               error: nil
             }
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
