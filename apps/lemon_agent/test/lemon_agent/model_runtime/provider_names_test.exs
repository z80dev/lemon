defmodule LemonAgent.ModelRuntime.ProviderNamesTest do
  use ExUnit.Case, async: true

  alias LemonAgent.ModelRuntime.{Credentials, CustomProviders, ProviderNames}

  @onboarding_only %{
    "chatgpt" => "openai-codex",
    "opencode-zen" => "opencode",
    "google-ai-studio" => "google",
    "gemini-api" => "google",
    "kimi-k2" => "kimi",
    "kimi-code" => "kimi_coding",
    "zhipu" => "zai",
    "open-router" => "openrouter"
  }

  test "onboarding-only inputs do not claim runtime provider identities" do
    for {name, canonical} <- @onboarding_only do
      assert ProviderNames.canonical_name(name) == nil
      assert ProviderNames.provider_atom(name) == nil
      assert ProviderNames.env_vars(name) == []
      assert ProviderNames.default_secret_name(name) == nil
      refute CustomProviders.builtin?(name)
      assert ProviderNames.canonical_name(canonical)
    end
  end

  test "custom identities retain endpoints and credentials alongside canonical tables" do
    for {name, canonical} <- @onboarding_only do
      custom = %{
        base_url: "https://private.invalid/v1",
        api: "openai_completions",
        api_key: "private-key",
        models: [%{id: "private-model"}]
      }

      builtin = %{
        base_url: "https://builtin.invalid/v1",
        auth_source: "api_key",
        api_key: "builtin-key"
      }

      providers = %{name => custom, canonical => builtin}

      assert ProviderNames.provider_config(providers, canonical) == builtin
      assert {^name, ^custom} = CustomProviders.custom_provider(providers, name)
      assert [%{provider: ^name, id: "private-model"}] = CustomProviders.models(providers)

      assert %{provider: ^name, base_url: "https://private.invalid/v1"} =
               CustomProviders.lookup(providers, name, "private-model")

      assert Credentials.resolve_provider_api_key(name, providers) == "private-key"
      assert Credentials.resolve_provider_api_key(canonical, providers) == "builtin-key"
      assert ProviderNames.provider_config(%{name => custom}, canonical) == nil
    end
  end

  test "existing runtime aliases retain canonical identities" do
    for {name, canonical} <- [
          {"glm", "zai"},
          {"z.ai", "zai"},
          {"z-ai", "zai"},
          {"moonshot", "kimi"},
          {"gemini_cli", "google_gemini_cli"},
          {"gemini-cli", "google_gemini_cli"},
          {"codex", "openai-codex"}
        ] do
      assert ProviderNames.canonical_name(name) == ProviderNames.canonical_name(canonical)
      assert ProviderNames.provider_atom(name) == ProviderNames.provider_atom(canonical)
      assert ProviderNames.config_name(name) == canonical
    end
  end

  test "qualified and custom model selectors are not provider aliases" do
    for name <- ["zhipu/glm-5", "zhipu:glm-5", "gemini-api:custom:model", "kimi-k2.7-code"] do
      assert ProviderNames.canonical_name(name) == nil
    end
  end
end
