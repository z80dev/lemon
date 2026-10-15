defmodule LemonControlPlane.Methods.StatusRuntimeIdentityTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.Status

  setup do
    keys = ~w(LEMON_RUNTIME_PROFILE LEMON_DEFAULT_MODEL)
    previous = Map.new(keys, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      LemonCore.Config.reload()
    end)

    :ok
  end

  test "status exposes the launcher's runtime profile and configured model id" do
    System.put_env("LEMON_RUNTIME_PROFILE", "runtime_full")
    System.put_env("LEMON_DEFAULT_MODEL", "openai:gpt-5")
    LemonCore.Config.reload()

    assert {:ok, %{"server" => server}} = Status.handle(%{}, %{})
    assert server["profile"] == "runtime_full"
    assert server["default_model"] == "openai:gpt-5"
    refute Map.has_key?(server, "home")
  end

  test "unknown profile and non-model config text are not exposed as identity" do
    System.put_env("LEMON_RUNTIME_PROFILE", "/private/runtime-profile")
    System.put_env("LEMON_DEFAULT_MODEL", "https://private.invalid/model?token=secret")
    LemonCore.Config.reload()

    assert {:ok, %{"server" => server}} = Status.handle(%{}, %{})
    assert server["profile"] == nil
    assert server["default_model"] == nil
    refute Jason.encode!(server) =~ "private"
    refute Jason.encode!(server) =~ "token=secret"
  end
end
