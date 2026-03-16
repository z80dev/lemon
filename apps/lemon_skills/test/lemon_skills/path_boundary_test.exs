defmodule LemonSkills.PathBoundaryTest do
  use ExUnit.Case, async: true

  alias LemonSkills.PathBoundary

  describe "within?/2 — POSIX paths" do
    test "exact match is within" do
      assert PathBoundary.within?("/a/b", "/a/b")
    end

    test "direct child is within" do
      assert PathBoundary.within?("/a/b", "/a/b/c")
    end

    test "deep nested child is within" do
      assert PathBoundary.within?("/a/b", "/a/b/c/d/e")
    end

    test "sibling with shared prefix is NOT within" do
      refute PathBoundary.within?("/a/b", "/a/b-other")
    end

    test "sibling directory is NOT within" do
      refute PathBoundary.within?("/a/b", "/a/other/file")
    end

    test "parent directory is NOT within" do
      refute PathBoundary.within?("/a/b", "/a")
    end
  end

  describe "within?/2 — Windows-style paths" do
    test "exact match is within" do
      assert PathBoundary.within?("C:\\Skills\\my-skill", "C:\\Skills\\my-skill")
    end

    test "direct child is within" do
      assert PathBoundary.within?("C:\\Skills\\my-skill", "C:\\Skills\\my-skill\\file.txt")
    end

    test "deep nested child is within" do
      assert PathBoundary.within?("C:\\Skills\\my-skill", "C:\\Skills\\my-skill\\sub\\file.txt")
    end

    test "sibling with shared prefix is NOT within" do
      refute PathBoundary.within?("C:\\Skills\\my-skill", "C:\\Skills\\my-skill-evil")
    end

    test "sibling directory is NOT within" do
      refute PathBoundary.within?("C:\\Skills\\my-skill", "C:\\Skills\\other-skill\\file.txt")
    end

    test "parent directory is NOT within" do
      refute PathBoundary.within?("C:\\Skills\\my-skill", "C:\\Skills")
    end
  end
end
