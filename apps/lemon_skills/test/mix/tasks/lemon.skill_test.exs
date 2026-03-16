defmodule Mix.Tasks.Lemon.SkillTest do
  @moduledoc """
  Tests for the lemon.skill Mix task.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonSkills.HttpClient.Mock, as: HttpMock
  alias Mix.Tasks.Lemon.Skill

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    HttpMock.reset()

    # Deterministic discovery stubs so discover/search tests do not depend on network.
    HttpMock.stub("https://api.github.com/search/repositories", {:ok, ~s({"items": []})})
    HttpMock.stub("https://skills.lemon.agent/", {:error, :nxdomain})
    HttpMock.stub("https://raw.githubusercontent.com/lemon-agent/skills/main/", {:error, :nxdomain})

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

  describe "usage" do
    test "prints help on unknown command" do
      output =
        capture_io(fn ->
          Skill.run(["unknown-command"])
        end)

      assert output =~ "Manage Lemon skills"
      assert output =~ "Commands"
      assert output =~ "list"
      assert output =~ "search"
      assert output =~ "install"
    end

    test "prints help on no arguments" do
      output =
        capture_io(fn ->
          Skill.run([])
        end)

      assert output =~ "Manage Lemon skills"
    end

    test "help includes new commands" do
      output =
        capture_io(fn ->
          Skill.run(["unknown-command"])
        end)

      assert output =~ "browse"
      assert output =~ "inspect"
      assert output =~ "check"
    end
  end

  describe "list command" do
    test "lists skills in table format", %{tmp_dir: tmp_dir} do
      write_skill!(tmp_dir, "list-skill", "---\nname: Listed\ndescription: Listed skill\n---\nbody")
      LemonSkills.refresh(cwd: tmp_dir)

      output =
        capture_io(fn ->
          Skill.run(["list", "--cwd=#{tmp_dir}"])
        end)

      assert output =~ "KEY"
      assert output =~ "STATUS"
      assert output =~ "SOURCE"
      assert output =~ "DESCRIPTION"
      assert output =~ "list-skill"
    end

    test "shows empty message when no skills" do
      output =
        capture_io(fn ->
          Skill.run(["list"])
        end)

      # Either shows skills or the empty message
      assert output =~ "skill" or output =~ "No skills installed"
    end
  end

  describe "browse command" do
    test "shows activation state column", %{tmp_dir: tmp_dir} do
      write_skill!(
        tmp_dir,
        "browse-skill",
        "---\nname: Browseable\ndescription: Browse test\n---\nbody"
      )

      LemonSkills.refresh(cwd: tmp_dir)

      output =
        capture_io(fn ->
          Skill.run(["browse", "--cwd=#{tmp_dir}"])
        end)

      assert output =~ "ACTIVATION"
      assert output =~ "browse-skill"
      # active skills get the ✓ marker
      assert output =~ "active"
    end

    test "--active flag filters to active-only skills", %{tmp_dir: tmp_dir} do
      missing_bin = "definitely-missing-bin-#{System.unique_integer([:positive])}"

      write_skill!(
        tmp_dir,
        "active-skill",
        "---\nname: Active\ndescription: Active skill\n---\nbody"
      )

      write_skill!(
        tmp_dir,
        "broken-skill",
        """
        ---
        name: Broken
        description: Not ready skill
        requires:
          bins:
            - #{missing_bin}
        ---
        body
        """
      )

      LemonSkills.refresh(cwd: tmp_dir)

      output =
        capture_io(fn ->
          Skill.run(["browse", "--active", "--cwd=#{tmp_dir}"])
        end)

      assert output =~ "active-skill"
      refute output =~ "broken-skill"
    end

    test "--not-ready flag shows not_ready skills", %{tmp_dir: tmp_dir} do
      missing_bin = "definitely-missing-bin-#{System.unique_integer([:positive])}"

      write_skill!(
        tmp_dir,
        "active-skill2",
        "---\nname: Active2\ndescription: Active skill\n---\nbody"
      )

      write_skill!(
        tmp_dir,
        "broken-skill2",
        """
        ---
        name: Broken2
        description: Not ready skill
        requires:
          bins:
            - #{missing_bin}
        ---
        body
        """
      )

      LemonSkills.refresh(cwd: tmp_dir)

      output =
        capture_io(fn ->
          Skill.run(["browse", "--not-ready", "--cwd=#{tmp_dir}"])
        end)

      refute output =~ "active-skill2"
      assert output =~ "broken-skill2"
    end
  end

  describe "search command" do
    test "searches local skills", %{tmp_dir: tmp_dir} do
      output =
        capture_io(fn ->
          Skill.run(["search", "api", "--no-online", "--cwd=#{tmp_dir}"])
        end)

      assert output =~ "Searching for 'api'"
      assert output =~ "Local Skills"
    end
  end

  describe "discover command" do
    test "shows message when no skills found" do
      output =
        capture_io(fn ->
          Skill.run(["discover", "xyz123nonexistent"])
        end)

      assert output =~ "Discovering skills for 'xyz123nonexistent'"
      assert output =~ "No skills found on GitHub"
    end
  end

  describe "remove command - confirmation" do
    test "answering n cancels and leaves skill and lockfile intact", %{tmp_dir: tmp_dir} do
      skill_dir = write_skill!(tmp_dir, "remove-cancel-skill", "---\nname: Cancel\n---\nbody")
      LemonSkills.refresh(cwd: tmp_dir)

      output =
        capture_io("n\n", fn ->
          Skill.run(["remove", "remove-cancel-skill", "--cwd=#{tmp_dir}"])
        end)

      assert output =~ "Cancelled."
      assert File.dir?(skill_dir), "skill directory should still exist after cancelled remove"
    end
  end

  describe "install command" do
    test "shows usage on missing source" do
      output =
        capture_io(fn ->
          Skill.run(["install"])
        end)

      assert output =~ "Manage Lemon skills"
    end
  end

  describe "inspect command" do
    test "shows error for non-existent skill", %{tmp_dir: _tmp_dir} do
      assert_raise Mix.Error, fn ->
        capture_io(fn ->
          Skill.run(["inspect", "non-existent-skill"])
        end)
      end
    end

    test "shows provenance and activation state for a found skill", %{tmp_dir: tmp_dir} do
      write_skill!(
        tmp_dir,
        "inspect-skill",
        "---\nname: Inspect Me\ndescription: Inspect test skill\n---\nbody"
      )

      LemonSkills.refresh(cwd: tmp_dir)

      output =
        capture_io(fn ->
          Skill.run(["inspect", "inspect-skill", "--cwd=#{tmp_dir}"])
        end)

      assert output =~ "inspect-skill"
      assert output =~ "Inspect Me"
      assert output =~ "Activation:"
      assert output =~ "Provenance"
      assert output =~ "Content Hashes"
      assert output =~ "Install hash:"
      assert output =~ "Upstream hash:"
      assert output =~ "Current hash:"
      assert output =~ "Drift:"
    end

    test "shows requirements section for skills with deps", %{tmp_dir: tmp_dir} do
      missing_env = "INSPECT_TEST_ENV_#{System.unique_integer([:positive])}"
      prev = System.get_env(missing_env)
      on_exit(fn -> restore_env(missing_env, prev) end)
      System.delete_env(missing_env)

      write_skill!(
        tmp_dir,
        "deps-skill",
        """
        ---
        name: Deps Skill
        description: Has requirements
        required_environment_variables:
          - #{missing_env}
        ---
        body
        """
      )

      LemonSkills.refresh(cwd: tmp_dir)

      output =
        capture_io(fn ->
          Skill.run(["inspect", "deps-skill", "--cwd=#{tmp_dir}"])
        end)

      assert output =~ "Requirements"
      assert output =~ missing_env
      assert output =~ "✗"
    end

    test "shows references section for skills with references", %{tmp_dir: tmp_dir} do
      skill_dir =
        write_skill!(
          tmp_dir,
          "refs-skill",
          """
          ---
          name: Refs Skill
          description: Has references
          references:
            - path: extra.md
          ---
          body
          """
        )

      File.write!(Path.join(skill_dir, "extra.md"), "# Extra")
      LemonSkills.refresh(cwd: tmp_dir)

      output =
        capture_io(fn ->
          Skill.run(["inspect", "refs-skill", "--cwd=#{tmp_dir}"])
        end)

      assert output =~ "References"
      assert output =~ "extra.md"
    end

    test "info is an alias for inspect", %{tmp_dir: tmp_dir} do
      write_skill!(
        tmp_dir,
        "info-alias-skill",
        "---\nname: Info Skill\ndescription: Info alias test\n---\nbody"
      )

      LemonSkills.refresh(cwd: tmp_dir)

      output =
        capture_io(fn ->
          Skill.run(["info", "info-alias-skill", "--cwd=#{tmp_dir}"])
        end)

      assert output =~ "info-alias-skill"
      assert output =~ "Provenance"
    end
  end

  describe "check command" do
    test "shows error for non-existent skill", %{tmp_dir: _tmp_dir} do
      assert_raise Mix.Error, fn ->
        capture_io(fn ->
          Skill.run(["check", "non-existent-skill"])
        end)
      end
    end

    test "reports active skill as ready", %{tmp_dir: tmp_dir} do
      write_skill!(
        tmp_dir,
        "check-active",
        "---\nname: Check Active\ndescription: Check test\n---\nbody"
      )

      LemonSkills.refresh(cwd: tmp_dir)

      output =
        capture_io(fn ->
          Skill.run(["check", "check-active", "--cwd=#{tmp_dir}"])
        end)

      assert output =~ "Check: check-active"
      assert output =~ "Activation:"
      assert output =~ "active"
      assert output =~ "Readiness:"
      assert output =~ "Local drift:"
      assert output =~ "Upstream:"
    end

    test "reports missing requirements for not_ready skill", %{tmp_dir: tmp_dir} do
      missing_bin = "definitely-missing-check-bin-#{System.unique_integer([:positive])}"

      write_skill!(
        tmp_dir,
        "check-broken",
        """
        ---
        name: Check Broken
        description: Broken for check
        requires:
          bins:
            - #{missing_bin}
        ---
        body
        """
      )

      LemonSkills.refresh(cwd: tmp_dir)

      output =
        capture_io(fn ->
          Skill.run(["check", "check-broken", "--cwd=#{tmp_dir}"])
        end)

      assert output =~ "not_ready"
      assert output =~ "missing:"
      assert output =~ missing_bin
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp write_skill!(tmp_dir, key, skill_md) do
    skill_dir = Path.join([tmp_dir, ".lemon", "skill", key])
    File.mkdir_p!(skill_dir)
    File.write!(Path.join(skill_dir, "SKILL.md"), skill_md)
    skill_dir
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
