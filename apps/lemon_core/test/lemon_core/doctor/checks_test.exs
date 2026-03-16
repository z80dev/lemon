defmodule LemonCore.Doctor.ChecksTest do
  use ExUnit.Case, async: true

  alias LemonCore.Doctor.Check
  alias LemonCore.Doctor.Checks.{Config, NodeTools, Runtime, Skills}

  describe "Config.run/1" do
    test "returns a list of Check structs" do
      checks = Config.run()
      assert is_list(checks)
      assert Enum.all?(checks, &match?(%Check{}, &1))
    end

    test "check names are unique" do
      names = Config.run() |> Enum.map(& &1.name)
      assert length(names) == length(Enum.uniq(names))
    end
  end

  describe "Runtime.run/1" do
    test "returns a list of Check structs" do
      checks = Runtime.run()
      assert is_list(checks)
      assert Enum.all?(checks, &match?(%Check{}, &1))
    end
  end

  describe "NodeTools.run/1" do
    test "returns a check per binary" do
      checks = NodeTools.run()
      assert is_list(checks)
      assert length(checks) >= 1
    end

    test "git check is present" do
      checks = NodeTools.run()
      assert Enum.any?(checks, &String.contains?(&1.name, "git"))
    end

    test "git check passes when git is on PATH" do
      # In CI/dev environments git is always available
      if System.find_executable("git") do
        checks = NodeTools.run()
        git_check = Enum.find(checks, &String.contains?(&1.name, "git"))
        assert git_check.status == :pass
      end
    end
  end

  describe "Skills.run/1" do
    test "returns a list of Check structs" do
      checks = Skills.run()
      assert is_list(checks)
      assert Enum.all?(checks, &match?(%Check{}, &1))
    end

    test "skills directory check has expected name" do
      checks = Skills.run()
      assert Enum.any?(checks, &(&1.name == "skills.directory"))
    end
  end
end
