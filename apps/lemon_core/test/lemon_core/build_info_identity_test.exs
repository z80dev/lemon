defmodule LemonCore.BuildInfoIdentityTest do
  use ExUnit.Case, async: false

  alias LemonCore.BuildInfo

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

  describe "version/0" do
    test "source reports the umbrella CalVer instead of the OTP application version" do
      System.delete_env("RELEASE_VSN")
      System.delete_env("LEMON_PATH")
      assert LemonCore.ReleaseVersion.valid?(BuildInfo.version())
      assert %{mode: "source", channel: "source"} = BuildInfo.identity()
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

    assert BuildInfo.version() == "2026.09.2"

    assert BuildInfo.identity() == %{
             version: "2026.09.2",
             mode: "release",
             commit: "0123456789ab",
             channel: "preview"
           }

    assert BuildInfo.describe() ==
             "Lemon 2026.09.2 (release; commit 0123456789ab; channel preview)"

    File.rm!(Path.join(version_dir, "lemon-build.json"))
    assert %{commit: "unknown", channel: "unknown"} = BuildInfo.identity()
  end
end
