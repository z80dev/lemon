defmodule LemonCore.Update.VersionTest do
  use ExUnit.Case, async: true

  alias LemonCore.Update.Version

  describe "parse/1" do
    test "parses a valid CalVer string" do
      assert {:ok, {2026, 3, 0}} = Version.parse("2026.03.0")
      assert {:ok, {2026, 3, 1}} = Version.parse("2026.03.1")
      assert {:ok, {2026, 12, 0}} = Version.parse("2026.12.0")
    end

    test "accepts pre-release suffix" do
      assert {:ok, {2026, 3, 0}} = Version.parse("2026.03.0-stable")
      assert {:ok, {2026, 3, 1}} = Version.parse("2026.03.1-preview")
    end

    test "returns :error for non-CalVer versions" do
      assert :error = Version.parse("0.1.0")
      assert :error = Version.parse("not-a-version")
      assert :error = Version.parse("")
      assert :error = Version.parse(nil)
    end
  end

  describe "compare/2" do
    test "returns :lt when v1 is older" do
      assert :lt = Version.compare("2026.03.0", "2026.03.1")
      assert :lt = Version.compare("2026.03.5", "2026.04.0")
      assert :lt = Version.compare("2025.12.0", "2026.01.0")
    end

    test "returns :eq for same version" do
      assert :eq = Version.compare("2026.03.0", "2026.03.0")
    end

    test "returns :gt when v1 is newer" do
      assert :gt = Version.compare("2026.03.1", "2026.03.0")
      assert :gt = Version.compare("2026.04.0", "2026.03.99")
    end

    test "falls back to string comparison for non-CalVer" do
      assert is_atom(Version.compare("0.1.0", "0.2.0"))
    end
  end

  describe "newer?/2" do
    test "returns true when candidate is newer" do
      assert Version.newer?("2026.03.0", "2026.03.1")
    end

    test "returns false when candidate is older or equal" do
      refute Version.newer?("2026.03.1", "2026.03.0")
      refute Version.newer?("2026.03.0", "2026.03.0")
    end
  end

  describe "valid?/1" do
    test "returns true for valid CalVer strings" do
      assert Version.valid?("2026.03.0")
      assert Version.valid?("2026.12.99")
    end

    test "returns false for non-CalVer strings" do
      refute Version.valid?("0.1.0")
      refute Version.valid?("latest")
    end
  end

  describe "current/0" do
    test "returns a string" do
      assert is_binary(Version.current())
    end
  end
end
