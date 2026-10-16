defmodule LemonCli.Onboarding.ProviderIdentityTest do
  use ExUnit.Case, async: false

  alias LemonAgent.ModelRuntime.{CustomProviders, ProviderNames}
  alias LemonCli.Onboarding.{Providers, Runner}
  alias LemonCore.Secrets

  # Historical CLI inputs remain onboarding-only when runtime does not know them.
  @legacy_aliases %{
    "anthropic" => ~w(claude),
    "openai-codex" => ~w(chatgpt codex openai_codex),
    "github_copilot" => ~w(copilot github-copilot),
    "google_antigravity" => ~w(antigravity google-antigravity),
    "zai" => ~w(glm zhipu z-ai z.ai),
    "kimi" => ~w(kimi-k2 moonshot),
    "minimax" => ~w(mini-max minimax-m2),
    "fireworks" => ~w(fireworks-ai fireworks_ai),
    "google" => ~w(google-ai-studio gemini-api),
    "deepseek" => ~w(deep-seek),
    "huggingface" => ~w(hugging-face hf),
    "qwen" => ~w(dashscope),
    "vercel_ai_gateway" => ~w(vercel-ai-gateway vercel),
    "opencode" => ~w(opencode-zen),
    "opencode_go" => ~w(opencode-go),
    "minimax_cn" => ~w(minimax-cn),
    "google_gemini_cli" => ~w(gemini gemini-cli gemini_cli google-gemini-cli),
    "openrouter" => ~w(open-router),
    "xai" => ~w(grok x-ai),
    "kimi_coding" => ~w(kimi-code kimi-for-coding)
  }

  @onboarding_only ~w(chatgpt opencode-zen google-ai-studio gemini-api kimi-k2 kimi-code zhipu open-router)

  test "every legacy onboarding spelling returns a runtime-resolvable canonical id" do
    for {id, aliases} <- @legacy_aliases, alias_name <- [id | aliases] do
      provider = Providers.find(alias_name)
      assert provider, "onboarding does not resolve #{alias_name}"
      assert provider.id == id, "#{alias_name} -> #{provider.id}, expected #{id}"

      assert ProviderNames.canonical_name(provider.id)
      assert ProviderNames.config_name(provider.id) == id

      for spelling <- [String.upcase(alias_name), "  #{alias_name}  "] do
        assert Providers.find(spelling) == provider
      end
    end
  end

  test "compatibility inputs do not become global runtime aliases" do
    for spelling <- @onboarding_only do
      assert Providers.find(spelling)
      assert ProviderNames.canonical_name(spelling) == nil
    end

    assert Providers.find("zhipu").id == "zai"
    assert Providers.find("kimi-k2").id == "kimi"
    assert Providers.find("gemini_cli").id == "google_gemini_cli"
  end

  test "every runtime alias of a menu provider is accepted by onboarding" do
    for provider <- Providers.list(),
        provider.id != "custom",
        name <- ProviderNames.all_names(provider.id) do
      assert Providers.find(name) == provider
      assert Providers.find(String.replace(name, "_", "-")) == provider
    end
  end

  test "every onboarding provider id keeps its config name and secret in the runtime table" do
    for provider <- Providers.list(), provider.id != "custom" do
      assert ProviderNames.canonical_name(provider.id), "runtime does not know #{provider.id}"
      assert ProviderNames.config_name(provider.id) == provider.id
      assert Providers.find(provider.id) == provider
    end
  end

  test "no alias is claimed by two canonical providers" do
    claims =
      for canonical <- ProviderNames.all_canonical_names(),
          name <- ProviderNames.all_names(canonical),
          do: {name, canonical}

    collisions =
      claims
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn {name, owners} -> {name, Enum.uniq(owners)} end)
      |> Enum.filter(fn {_name, owners} -> length(owners) > 1 end)

    # Only these two runtime identities intentionally share a config table.
    assert collisions == [
             {"amazon_bedrock", ["amazon_bedrock", "bedrock_converse_stream"]}
           ]

    onboarding_claims =
      for {id, names} <- @legacy_aliases, name <- [id | names] do
        {String.replace(name, "-", "_"), id}
      end

    for {_name, claims} <- Enum.group_by(onboarding_claims, &elem(&1, 0)) do
      assert claims |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == 1
    end

    for spelling <- @onboarding_only do
      normalized = String.replace(spelling, "-", "_")
      refute Enum.any?(claims, fn {name, _owner} -> name == normalized end)
    end
  end

  test "custom and qualified or unknown selectors are not rerouted" do
    assert Providers.find("custom").custom
    assert Providers.find("kimi-k2.7-code") == nil
    assert Providers.find("zhipu/glm-5") == nil
    assert Providers.find("my-private-endpoint") == nil
    assert ProviderNames.canonical_name("zhipu/glm-5") == nil
    assert ProviderNames.canonical_name("kimi-k2.7-code") == nil
  end

  describe "canonical config persistence" do
    setup do
      tmp_dir =
        Path.join(System.tmp_dir!(), "onboarding_identity_#{System.unique_integer([:positive])}")

      home = Path.join(tmp_dir, "home")
      File.mkdir_p!(home)
      Runner.ensure_required_apps!()

      saved = Map.new(["HOME", "LEMON_SECRETS_MASTER_KEY"], &{&1, System.get_env(&1)})
      secrets_config = Application.get_env(:lemon_core, Secrets)
      Application.put_env(:lemon_core, Secrets, key_providers: [:env, :file])
      System.put_env("HOME", home)
      System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))
      clear_secrets_table()

      on_exit(fn ->
        clear_secrets_table()

        if secrets_config,
          do: Application.put_env(:lemon_core, Secrets, secrets_config),
          else: Application.delete_env(:lemon_core, Secrets)

        Enum.each(saved, fn {key, value} ->
          if value, do: System.put_env(key, value), else: System.delete_env(key)
        end)

        File.rm_rf!(tmp_dir)
      end)

      {:ok, tmp_dir: tmp_dir}
    end

    test "compatibility inputs write canonical tables and default selections consumed by runtime",
         %{
           tmp_dir: tmp_dir
         } do
      io = %{
        info: fn _ -> :ok end,
        error: fn message -> flunk(message) end,
        prompt: fn _ -> flunk("unexpected prompt") end,
        secret: fn _ -> flunk("unexpected secret prompt") end
      }

      for spelling <- ["gemini_cli" | @onboarding_only] do
        provider = Providers.find(spelling)
        path = Path.join(tmp_dir, "#{spelling}.toml")
        runtime_provider = ProviderNames.provider_atom(provider.id)
        catalog_model = List.first(LemonAi.Models.get_models(runtime_provider))
        model_id = if catalog_model, do: catalog_model.id, else: "identity-test-model"

        assert :ok =
                 Runner.run(
                   [
                     "--non-interactive",
                     "--auth",
                     "api-key",
                     "--token",
                     "synthetic-identity-test-token",
                     "--set-default",
                     "--model",
                     model_id,
                     "--config-path",
                     path
                   ],
                   provider,
                   io: io
                 )

        assert {:ok, config} = Toml.decode_file(path)
        assert Map.keys(config["providers"]) == [provider.id]
        assert config["providers"][provider.id]["api_key_secret"] == provider.default_secret_name
        assert config["defaults"]["provider"] == provider.id
        assert config["defaults"]["model"] == "#{provider.id}:#{model_id}"

        assert [saved_provider, saved_model] =
                 String.split(config["defaults"]["model"], ":", parts: 2)

        assert ProviderNames.config_name(saved_provider) == provider.id

        assert ProviderNames.provider_config(config, saved_provider) ==
                 config["providers"][provider.id]

        assert CustomProviders.config_for(config["providers"], saved_provider) ==
                 config["providers"][provider.id]

        model =
          CustomProviders.lookup(config["providers"], saved_provider, saved_model) ||
            LemonAi.Models.get_model(runtime_provider, saved_model)

        assert model
        assert model.id == model_id
        assert model.provider == ProviderNames.provider_atom(provider.id)
      end
    end
  end

  defp clear_secrets_table do
    Secrets.table()
    |> LemonCore.Store.list()
    |> Enum.each(fn {key, _} -> LemonCore.Store.delete(Secrets.table(), key) end)
  end
end
