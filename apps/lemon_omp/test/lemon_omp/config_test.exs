defmodule LemonOmp.ConfigTest do
  use ExUnit.Case, async: false

  import LemonOmp.TestSupport

  alias LemonOmp.Config

  setup do
    for name <- ~w(LEMON_OMP_APPROVALS LEMON_OMP_APPROVAL_TIMEOUT_MS) do
      previous = System.get_env(name)
      System.delete_env(name)

      on_exit(fn ->
        if previous, do: System.put_env(name, previous), else: System.delete_env(name)
      end)
    end

    put_app_env(:approvals, :bridge)
    put_app_env(:approval_timeout_ms, 600_000)
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
end
