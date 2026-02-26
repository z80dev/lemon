defmodule Mix.Tasks.Lemon.SkillTest do
  @moduledoc """
  Tests for the lemon.skill Mix task.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonSkills.HttpClient.Mock, as: HttpMock
  alias Mix.Tasks.Lemon.Skill

  setup do
    HttpMock.reset()

    # Deterministic discovery stubs so discover/search tests do not depend on network.
    HttpMock.stub("https://api.github.com/search/repositories", {:ok, ~s({"items": []})})
    HttpMock.stub("https://skills.lemon.agent/", {:error, :nxdomain})
    HttpMock.stub("https://raw.githubusercontent.com/lemon-agent/skills/main/", {:error, :nxdomain})

    :ok
  end

  describe "usage" do
    test "prints help on unknown command" do
      output = capture_io(fn ->
        Skill.run(["unknown-command"])
      end)

      assert output =~ "Manage Lemon skills"
      assert output =~ "Commands"
      assert output =~ "list"
      assert output =~ "search"
      assert output =~ "install"
    end

    test "prints help on no arguments" do
      output = capture_io(fn ->
        Skill.run([])
      end)

      assert output =~ "Manage Lemon skills"
    end
  end

  describe "list command" do
    test "lists skills in table format" do
      output = capture_io(fn ->
        Skill.run(["list"])
      end)

      # Should show skills table header
      assert output =~ "KEY"
      assert output =~ "STATUS"
      assert output =~ "SOURCE"
      assert output =~ "DESCRIPTION"
    end
  end

  describe "search command" do
    test "searches local skills" do
      output = capture_io(fn ->
        Skill.run(["search", "api", "--no-online"])
      end)

      assert output =~ "Searching for 'api'"
      assert output =~ "Local Skills"
    end
  end

  describe "discover command" do
    test "shows message when no skills found" do
      output = capture_io(fn ->
        Skill.run(["discover", "xyz123nonexistent"])
      end)

      assert output =~ "Discovering skills for 'xyz123nonexistent'"
      assert output =~ "No skills found on GitHub"
    end
  end

  describe "install command" do
    test "shows usage on missing source" do
      output = capture_io(fn ->
        Skill.run(["install"])
      end)

      assert output =~ "Manage Lemon skills"
    end
  end

  describe "info command" do
    test "shows error for non-existent skill" do
      assert_raise Mix.Error, fn ->
        capture_io(fn ->
          Skill.run(["info", "non-existent-skill"])
        end)
      end
    end
  end
end
