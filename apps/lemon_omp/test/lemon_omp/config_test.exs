defmodule LemonOmp.ConfigTest do
  use ExUnit.Case, async: false

  import LemonOmp.TestSupport

  alias LemonOmp.Config

  setup do
    for name <- ~w(LEMON_OMP_APPROVALS LEMON_OMP_APPROVAL_TIMEOUT_MS LEMON_OMP_SESSION_DIR) do
      previous = System.get_env(name)
      System.delete_env(name)

      on_exit(fn ->
        if previous, do: System.put_env(name, previous), else: System.delete_env(name)
      end)
    end

    put_app_env(:approvals, :bridge)
    put_app_env(:approval_timeout_ms, 600_000)
    put_app_env(:session_dir, nil)
    :ok
  end

  test "bridge and ten minutes are the default approval settings" do
    assert Config.approvals() == :bridge
    assert Config.approval_timeout_ms() == 600_000
  end

  test "decline can be configured in application env and overridden by environment" do
    put_app_env(:approvals, :decline)
    assert Config.approvals() == :decline
    System.put_env("LEMON_OMP_APPROVALS", "bridge")
    assert Config.approvals() == :bridge
    System.put_env("LEMON_OMP_APPROVALS", " decline ")
    assert Config.approvals() == :decline
    System.put_env("LEMON_OMP_APPROVALS", "invalid")
    assert Config.approvals() == :decline
    put_app_env(:approvals, :invalid)
    assert Config.approvals() == :bridge
  end

  test "approval timeout uses positive integers and environment takes precedence" do
    put_app_env(:approval_timeout_ms, 500)
    assert Config.approval_timeout_ms() == 500
    System.put_env("LEMON_OMP_APPROVAL_TIMEOUT_MS", "200")
    assert Config.approval_timeout_ms() == 200

    for value <- ["0", "-1", "never", "1.5"] do
      System.put_env("LEMON_OMP_APPROVAL_TIMEOUT_MS", value)
      assert Config.approval_timeout_ms() == 500
    end

    put_app_env(:approval_timeout_ms, 0)
    assert Config.approval_timeout_ms() == 600_000
  end

  test "session history defaults to Lemon's per-user state, not omp's agent directory" do
    expected = Path.expand(Path.join(LemonCore.Paths.home_state_dir(), "omp/sessions"))
    assert Config.session_dir() == expected
    assert Config.sessions_dir() == expected
    refute expected == Config.omp_sessions_dir()
  end

  test "session path is expanded and environment overrides application config" do
    put_app_env(:session_dir, "./app-history")
    assert Config.session_dir() == Path.expand("./app-history")
    System.put_env("LEMON_OMP_SESSION_DIR", " ~/env-history ")
    assert Config.session_dir() == Path.expand("~/env-history")
    System.put_env("LEMON_OMP_SESSION_DIR", "omp")
    assert Config.session_dir() == nil
    assert Config.sessions_dir() == Config.omp_sessions_dir()
    System.delete_env("LEMON_OMP_SESSION_DIR")
    put_app_env(:session_dir, "omp")
    assert Config.session_dir() == nil
  end

  test "invalid session paths safely fall back through app config to Lemon's default" do
    put_app_env(:session_dir, "./app-history")

    for value <- ["", "  ", "bad\npath"] do
      System.put_env("LEMON_OMP_SESSION_DIR", value)
      assert Config.session_dir() == Path.expand("./app-history")
    end

    System.delete_env("LEMON_OMP_SESSION_DIR")

    for value <- [nil, false, 42, [], %{}, "", "bad\0path", <<255>>] do
      put_app_env(:session_dir, value)

      assert Config.session_dir() ==
               Path.expand(Path.join(LemonCore.Paths.home_state_dir(), "omp/sessions"))
    end
  end
end
