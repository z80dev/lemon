defmodule LemonCore.Testing.HermeticEnvTest do
  use ExUnit.Case, async: false

  alias LemonCore.Testing.HermeticEnv

  @credential_keys [
    "ANTHROPIC_API_KEY",
    "OPENAI_API_KEY",
    "OPENROUTER_API_KEY",
    "AWS_SECRET_ACCESS_KEY",
    "LEMON_SECRETS_MASTER_KEY",
    "CHATGPT_TOKEN",
    "OPENCODE_API_KEY",
    "GOOGLE_GENERATIVE_AI_API_KEY",
    "GOOGLE_GEMINI_CLI_API_KEY",
    "GH_TOKEN",
    "GITHUB_COPILOT_API_KEY",
    "GITHUB_TOKEN",
    "LEMON_EVAL_API_KEY",
    "LEMON_EVAL_API_KEY_SECRET",
    "INTEGRATION_API_KEY",
    "INTEGRATION_API_KEY_SECRET",
    "KIMI_API_KEY",
    "MOONSHOT_API_KEY",
    "ZAI_API_KEY",
    "MINIMAX_API_KEY",
    "FIREWORKS_API_KEY"
  ]

  setup do
    keys = @credential_keys ++ ["LEMON_TEST_ALLOW_LIVE_CREDENTIALS", "NON_SECRET_TEST_VALUE"]
    snapshot = Map.new(keys, fn key -> {key, System.get_env(key)} end)

    on_exit(fn ->
      Enum.each(snapshot, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "credential_env_vars lists provider secrets scrubbed from unit lanes" do
    credential_vars = HermeticEnv.credential_env_vars()

    for key <- @credential_keys do
      assert key in credential_vars
    end
  end

  test "vars registered under :test_credential_env_vars are unioned in and scrubbed" do
    original = Application.fetch_env(:lemon_core, :test_credential_env_vars)
    throwaway = "LEMON_TEST_THROWAWAY_CREDENTIAL"

    Application.put_env(:lemon_core, :test_credential_env_vars, [throwaway])

    on_exit(fn ->
      case original do
        {:ok, vars} -> Application.put_env(:lemon_core, :test_credential_env_vars, vars)
        :error -> Application.delete_env(:lemon_core, :test_credential_env_vars)
      end

      System.delete_env(throwaway)
    end)

    System.put_env(throwaway, "ambient-secret")

    assert throwaway in HermeticEnv.credential_env_vars()
    assert :ok = HermeticEnv.scrub_unit_credentials!()
    refute System.get_env(throwaway)
  end

  test "scrub_unit_credentials! removes ambient provider credentials" do
    for key <- @credential_keys do
      System.put_env(key, "ambient-real-secret")
    end

    System.put_env("NON_SECRET_TEST_VALUE", "keep-me")

    assert :ok = HermeticEnv.scrub_unit_credentials!()

    for key <- @credential_keys do
      refute System.get_env(key), "expected #{key} to be scrubbed"
    end

    assert System.get_env("NON_SECRET_TEST_VALUE") == "keep-me"
  end

  test "scrub_unit_credentials! preserves credentials when live integration opt-in is set" do
    System.put_env("OPENAI_API_KEY", "live-test-secret")
    System.put_env("LEMON_TEST_ALLOW_LIVE_CREDENTIALS", "1")

    assert {:skipped, :live_credentials_allowed} = HermeticEnv.scrub_unit_credentials!()

    assert System.get_env("OPENAI_API_KEY") == "live-test-secret"
  end

  test "scrub_unit_credentials! preserves credentials when allow_live option is set" do
    System.put_env("OPENAI_API_KEY", "live-test-secret")

    assert {:skipped, :live_credentials_allowed} =
             HermeticEnv.scrub_unit_credentials!(allow_live?: true)

    assert System.get_env("OPENAI_API_KEY") == "live-test-secret"
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
