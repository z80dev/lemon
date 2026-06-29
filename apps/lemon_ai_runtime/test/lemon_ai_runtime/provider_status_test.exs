defmodule LemonAiRuntime.ProviderStatusTest do
  use ExUnit.Case, async: false

  alias LemonCore.Secrets

  @env_keys ~w(
    ANTHROPIC_API_KEY
    ANTHROPIC_TOKEN
    CLAUDE_CODE_OAUTH_TOKEN
    OPENAI_API_KEY
    OPENAI_CODEX_API_KEY
    CHATGPT_TOKEN
    ZAI_API_KEY
    LEMON_SECRETS_MASTER_KEY
    LEMON_DEFAULT_PROVIDER
    LEMON_DEFAULT_MODEL
    LEMON_PROVIDER_ROUTING_ENABLED
    LEMON_PROVIDER_FALLBACK_PROVIDERS
    LEMON_PROVIDER_ROUTING_DEFAULT_POOL
    LEMON_PROVIDER_ROUTING_DEFAULT_PROFILE
    LEMON_PROVIDER_ROUTING_REQUIRE_CREDENTIALS
  )

  setup do
    clear_secrets_table()
    saved_env = Map.new(@env_keys, fn key -> {key, System.get_env(key)} end)
    Enum.each(@env_keys, &System.delete_env/1)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon_provider_status_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(tmp_dir, ".lemon"))
    System.put_env("LEMON_SECRETS_MASTER_KEY", :crypto.strong_rand_bytes(32) |> Base.encode64())

    on_exit(fn ->
      clear_secrets_table()

      Enum.each(saved_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf!(tmp_dir)
    end)

    %{cwd: tmp_dir}
  end

  test "snapshot uses defaults and selects a ready fallback provider", %{cwd: cwd} do
    write_config!(cwd, """
    [defaults]
    provider = "openai"
    model = "gpt-5-mini"

    [runtime.provider_routing]
    fallback_providers = ["zai", "anthropic"]
    """)

    System.put_env("ZAI_API_KEY", "zai-secret-value")

    status =
      LemonAiRuntime.ProviderStatus.snapshot(%{
        "projectDir" => cwd,
        "provider" => "openai"
      })

    assert status["defaultProvider"] == "openai"
    assert status["defaultModel"] == "gpt-5-mini"
    assert status["routing"]["requestedProvider"] == "openai"
    assert status["routing"]["selectedProvider"] == "zai"
    assert status["routing"]["selectedModel"] == "gpt-5-mini"
    assert status["routing"]["decision"] == "selected_fallback"
    assert "zai" in status["routing"]["fallbackProviders"]

    candidates = status["routing"]["candidateProviders"]
    assert Enum.any?(candidates, &match?(%{"provider" => "openai", "selected" => false}, &1))
    assert Enum.any?(candidates, &match?(%{"provider" => "zai", "selected" => true}, &1))

    rendered = inspect(status)
    refute rendered =~ "zai-secret-value"
    refute rendered =~ "ZAI_API_KEY"
  end

  test "snapshot selects primary provider when credentials are ready", %{cwd: cwd} do
    write_config!(cwd, """
    [defaults]
    provider = "openai"
    model = "gpt-5-mini"

    [runtime.provider_routing]
    fallback_providers = ["zai"]
    """)

    System.put_env("OPENAI_API_KEY", "openai-secret-value")
    System.put_env("ZAI_API_KEY", "zai-secret-value")

    status =
      LemonAiRuntime.ProviderStatus.snapshot(%{
        "projectDir" => cwd,
        "provider" => "openai"
      })

    assert status["routing"]["selectedProvider"] == "openai"
    assert status["routing"]["decision"] == "selected_primary"
    assert status["routing"]["cleanup"]["includesRawApiKeys"] == false
    assert status["routing"]["cleanup"]["includesSecretNames"] == false
    assert status["routing"]["cleanup"]["includesRawBaseUrls"] == false
    assert status["routing"]["cleanup"]["includesEnvVarNames"] == false

    rendered = inspect(status)
    refute rendered =~ "openai-secret-value"
    refute rendered =~ "OPENAI_API_KEY"
  end

  test "snapshot exposes redacted credential pools and routing profile distribution", %{cwd: cwd} do
    write_config!(cwd, """
    [defaults]
    provider = "openai"
    model = "gpt-5-mini"

    [runtime.provider_routing]
    default_pool = "burst"
    default_profile = "ops"
    fallback_providers = ["anthropic"]

    [runtime.provider_routing.credential_pools.burst]
    providers = ["openai", "zai"]
    strategy = "round_robin"

    [runtime.provider_routing.profiles.ops]
    credential_pool = "burst"
    fallback_providers = ["anthropic"]
    distribution = { openai = 70, zai = 30 }
    """)

    System.put_env("ZAI_API_KEY", "zai-secret-value")

    status = LemonAiRuntime.ProviderStatus.snapshot(%{"projectDir" => cwd})
    routing = status["routing"]

    assert routing["selectedProfile"] == "ops"
    assert routing["selectedCredentialPool"] == "burst"
    assert routing["credentialPool"]["strategy"] == "round_robin"
    assert routing["credentialPool"]["configuredProviders"] == ["openai", "zai"]

    assert routing["profileDistribution"] == [
             %{"provider" => "openai", "weight" => 70},
             %{"provider" => "zai", "weight" => 30}
           ]

    assert routing["selectedProvider"] == "zai"
    assert "zai" in routing["fallbackProviders"]
    refute inspect(status) =~ "zai-secret-value"
    refute inspect(status) =~ "ZAI_API_KEY"
  end

  test "openai-codex oauth readiness ignores ambient raw token env", %{cwd: cwd} do
    write_config!(cwd, """
    [providers.openai-codex]
    auth_source = "oauth"
    """)

    System.put_env("OPENAI_CODEX_API_KEY", "codex-raw-token")

    status =
      LemonAiRuntime.ProviderStatus.snapshot(%{
        "projectDir" => cwd,
        "provider" => "openai-codex"
      })

    provider = only_provider(status)

    assert provider["provider"] == "openai_codex"
    refute provider["credentialReady"]
    refute inspect(status) =~ "codex-raw-token"
  end

  test "anthropic oauth readiness requires a resolvable oauth payload", %{cwd: cwd} do
    assert {:ok, _} = Secrets.set("llm_anthropic_bad_oauth", "not-json")

    write_config!(cwd, """
    [providers.anthropic]
    auth_source = "oauth"
    oauth_secret = "llm_anthropic_bad_oauth"
    """)

    status =
      LemonAiRuntime.ProviderStatus.snapshot(%{
        "projectDir" => cwd,
        "provider" => "anthropic"
      })

    provider = only_provider(status)

    assert provider["provider"] == "anthropic"
    refute provider["credentialReady"]
    refute inspect(status) =~ "llm_anthropic_bad_oauth"
  end

  defp write_config!(cwd, body) do
    cwd
    |> Path.join(".lemon/config.toml")
    |> File.write!(body)
  end

  defp only_provider(status), do: status["providers"] |> Enum.find(& &1["configured"])

  defp clear_secrets_table do
    Secrets.table()
    |> LemonCore.Store.list()
    |> Enum.each(fn {key, _} -> LemonCore.Store.delete(Secrets.table(), key) end)
  end
end
