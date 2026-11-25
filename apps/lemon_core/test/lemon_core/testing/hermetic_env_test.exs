defmodule LemonCore.Testing.HermeticEnvTest do
  use ExUnit.Case, async: false

  alias LemonCore.Testing.HermeticEnv

  setup do
    keys = ["OPENAI_API_KEY", "OPENROUTER_API_KEY", "NON_SECRET_TEST_VALUE"]
    snapshot = HermeticEnv.snapshot_env(keys)
    on_exit(fn -> HermeticEnv.restore_env(snapshot) end)
    :ok
  end

  test "with_restored_env restores modified, deleted, and newly created keys" do
    System.put_env("OPENAI_API_KEY", "original")
    System.put_env("NON_SECRET_TEST_VALUE", "original-non-secret")
    System.delete_env("OPENROUTER_API_KEY")

    result =
      HermeticEnv.with_restored_env(
        ["OPENAI_API_KEY", "NON_SECRET_TEST_VALUE", "OPENROUTER_API_KEY"],
        fn ->
          System.put_env("OPENAI_API_KEY", "changed")
          System.delete_env("NON_SECRET_TEST_VALUE")
          System.put_env("OPENROUTER_API_KEY", "new-secret")
          :inside
        end
      )

    assert result == :inside
    assert System.get_env("OPENAI_API_KEY") == "original"
    assert System.get_env("NON_SECRET_TEST_VALUE") == "original-non-secret"
    refute System.get_env("OPENROUTER_API_KEY")
  end
end
