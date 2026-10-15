defmodule LemonCore.Update.VersionTest do
  use ExUnit.Case, async: false

  alias LemonCore.Update.Version

  setup do
    keys = ["RELEASE_VSN", "RELEASE_ROOT", "LEMON_PATH", "LEMON_CHANNEL"]
    original = Map.new(keys, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(original, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

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
      assert Version.compare("0.1.0", "0.2.0") == :lt
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
    test "source reports the umbrella CalVer instead of the OTP application version" do
      System.delete_env("RELEASE_VSN")
      System.delete_env("LEMON_PATH")
      assert Version.valid?(Version.current())
      assert %{mode: "source", channel: "source"} = Version.info()
    end
  end

  test "release identity uses assembled metadata rather than the updater channel" do
    root = Path.join(System.tmp_dir!(), "lemon-version-#{System.unique_integer([:positive])}")
    version_dir = Path.join(root, "releases/2026.09.2")
    File.mkdir_p!(version_dir)
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(
      Path.join(version_dir, "lemon-build.json"),
      Jason.encode!(%{commit: "0123456789ab", channel: "preview"})
    )

    System.put_env("RELEASE_VSN", "2026.09.2")
    System.put_env("RELEASE_ROOT", root)
    System.put_env("LEMON_CHANNEL", "stable")

    assert Version.current() == "2026.09.2"

    assert Version.info() == %{
             version: "2026.09.2",
             mode: "release",
             commit: "0123456789ab",
             channel: "preview"
           }

    assert Version.describe() ==
             "Lemon 2026.09.2 (release; commit 0123456789ab; channel preview)"

    File.rm!(Path.join(version_dir, "lemon-build.json"))
    assert %{commit: "unknown", channel: "unknown"} = Version.info()
  end
end
