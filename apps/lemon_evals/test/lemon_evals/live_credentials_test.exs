defmodule LemonEvals.LiveCredentialsTest do
  use ExUnit.Case, async: false

  alias LemonEvals.Harness

  @env_vars ~w(
    LEMON_EVAL_API_KEY
    LEMON_EVAL_API_KEY_SECRET
    INTEGRATION_API_KEY
    INTEGRATION_API_KEY_SECRET
    ANTHROPIC_API_KEY
    TEST_LEMON_EVAL_SECRET
    TEST_INTEGRATION_EVAL_SECRET
  )

  setup do
    previous = Map.new(@env_vars, &{&1, System.get_env(&1)})
    Enum.each(@env_vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(@env_vars, &System.delete_env/1)

      Enum.each(previous, fn
        {_key, nil} -> :ok
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "resolves direct live eval credential first" do
    System.put_env("LEMON_EVAL_API_KEY", "direct-eval-key")
    System.put_env("LEMON_EVAL_API_KEY_SECRET", "TEST_LEMON_EVAL_SECRET")
    System.put_env("TEST_LEMON_EVAL_SECRET", "secret-eval-key")

    assert Harness.live_model_api_key() == "direct-eval-key"
  end

  test "resolves Lemon eval API key secret with env fallback" do
    System.put_env("LEMON_EVAL_API_KEY_SECRET", "TEST_LEMON_EVAL_SECRET")
    System.put_env("TEST_LEMON_EVAL_SECRET", "secret-eval-key")

    assert Harness.live_model_api_key() == "secret-eval-key"
  end

  test "resolves integration API key secret with env fallback" do
    System.put_env("INTEGRATION_API_KEY_SECRET", "TEST_INTEGRATION_EVAL_SECRET")
    System.put_env("TEST_INTEGRATION_EVAL_SECRET", "integration-secret-key")

    assert Harness.live_model_api_key() == "integration-secret-key"
  end

  test "falls back to legacy Anthropic API key" do
    System.put_env("ANTHROPIC_API_KEY", "legacy-anthropic-key")

    assert Harness.live_model_api_key() == "legacy-anthropic-key"
  end
end
