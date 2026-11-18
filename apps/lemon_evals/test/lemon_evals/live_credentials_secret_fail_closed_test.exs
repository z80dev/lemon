defmodule LemonEvals.LiveCredentialsSecretFailClosedTest do
  use ExUnit.Case, async: false

  alias LemonCore.{Secrets, Store}
  alias LemonEvals.Harness

  @secret "TEST_LEMON_EVAL_FAILCLOSED_SECRET"
  @env_vars ["LEMON_SECRETS_MASTER_KEY" | ~w(
    LEMON_EVAL_API_KEY
    LEMON_EVAL_API_KEY_SECRET
    INTEGRATION_API_KEY
    INTEGRATION_API_KEY_SECRET
    ANTHROPIC_API_KEY
  )] ++ [@secret]

  setup do
    saved = Map.new(@env_vars, &{&1, System.get_env(&1)})
    Enum.each(@env_vars, &System.delete_env/1)
    clear_secrets_table()
    System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))

    on_exit(fn ->
      clear_secrets_table()

      Enum.each(saved, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)
    end)

    :ok
  end

  test "unreadable configured secret never falls back to the same-name env var" do
    Store.put(Secrets.table(), {"default", @secret}, "corrupt")
    System.put_env("LEMON_EVAL_API_KEY_SECRET", @secret)
    System.put_env(@secret, "ambient-eval-key")

    assert Harness.live_model_api_key() == nil
  end

  test "a missing secret still falls back to the same-name env var" do
    System.put_env("LEMON_EVAL_API_KEY_SECRET", @secret)
    System.put_env(@secret, "ambient-eval-key")

    assert Harness.live_model_api_key() == "ambient-eval-key"
  end

  defp clear_secrets_table do
    Store.list(Secrets.table())
    |> Enum.each(fn {key, _value} -> Store.delete(Secrets.table(), key) end)
  end
end
