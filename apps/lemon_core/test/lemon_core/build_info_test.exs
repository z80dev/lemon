defmodule LemonCore.BuildInfoTest do
  use ExUnit.Case, async: false

  test "reports application and runtime metadata" do
    info = LemonCore.BuildInfo.current()

    assert info.lemon_version == "0.1.0"
    assert info.runtime_mode in ["source-dev", "release-runtime"]
    assert is_map(info.git)
    assert is_binary(info.elixir)
    assert is_binary(info.otp)
    assert is_binary(info.system_architecture)
  end

  test "uses release and git environment metadata when present" do
    old_release_name = System.get_env("RELEASE_NAME")
    old_release_vsn = System.get_env("RELEASE_VSN")
    old_channel = System.get_env("LEMON_RELEASE_CHANNEL")
    old_sha = System.get_env("LEMON_GIT_SHA")
    old_branch = System.get_env("LEMON_GIT_BRANCH")

    System.put_env("RELEASE_NAME", "lemon_runtime_full")
    System.put_env("RELEASE_VSN", "2026.05.0-preview")
    System.put_env("LEMON_RELEASE_CHANNEL", "preview")
    System.put_env("LEMON_GIT_SHA", "abcdef123456")
    System.put_env("LEMON_GIT_BRANCH", "release/test")

    on_exit(fn ->
      restore_env("RELEASE_NAME", old_release_name)
      restore_env("RELEASE_VSN", old_release_vsn)
      restore_env("LEMON_RELEASE_CHANNEL", old_channel)
      restore_env("LEMON_GIT_SHA", old_sha)
      restore_env("LEMON_GIT_BRANCH", old_branch)
    end)

    info = LemonCore.BuildInfo.current()

    assert info.runtime_mode == "release-runtime"
    assert info.release_name == "lemon_runtime_full"
    assert info.release_version == "2026.05.0-preview"
    assert info.release_channel == "preview"
    assert info.git.commit == "abcdef123456"
    assert info.git.branch == "release/test"
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
