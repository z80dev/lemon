defmodule LemonAgent.ModelRuntime.ProviderConfigurationTest do
  use ExUnit.Case, async: false

  alias LemonAgent.ModelRuntime.ProviderConfiguration

  @env_keys ~w(
    LEMON_DEFAULT_THINKING_LEVEL
    HOME
    LEMON_DEFAULT_PROVIDER
    LEMON_DEFAULT_MODEL
    LEMON_PROVIDER_ROUTING_ENABLED
    LEMON_PROVIDER_FALLBACK_PROVIDERS
    LEMON_PROVIDER_ROUTING_DEFAULT_POOL
    LEMON_PROVIDER_ROUTING_DEFAULT_PROFILE
    LEMON_PROVIDER_ROUTING_REQUIRE_CREDENTIALS
  )

  setup do
    saved_env = Map.new(@env_keys, &{&1, System.get_env(&1)})
    Enum.each(@env_keys, &System.delete_env/1)

    root =
      Path.join(
        System.tmp_dir!(),
        "provider_configuration_test_#{System.unique_integer([:positive])}"
      )

    home = Path.join(root, "home")
    project = Path.join(root, "project")
    File.mkdir_p!(Path.join(project, ".lemon"))
    File.mkdir_p!(Path.join(home, ".lemon"))
    System.put_env("HOME", home)

    on_exit(fn ->
      Enum.each(saved_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf!(root)
    end)

    %{project: project, config_path: Path.join(project, ".lemon/config.toml")}
  end

  test "adds and removes fallbacks while preserving unrelated comments", ctx do
    File.write!(ctx.config_path, """
    # keep this operator note
    [defaults]
    provider = "openai"
    model = "gpt-5-mini"

    [runtime.provider_routing]
    fallback_providers = ["zai", "custom-proxy"]

    [tui]
    theme = "lemon"
    """)

    assert {:ok, added} =
             ProviderConfiguration.configure(%{
               "action" => "fallback.add",
               "provider" => "anthropic",
               "apply" => true,
               "scope" => "project",
               "projectDir" => ctx.project
             })

    assert added["applied"]

    assert added["proposedRoutingConfig"]["fallbackProviders"] == [
             "zai",
             "custom-proxy",
             "anthropic"
           ]

    content = File.read!(ctx.config_path)
    assert content =~ "# keep this operator note"
    assert content =~ ~s(theme = "lemon")

    assert {:ok, preview} =
             ProviderConfiguration.configure(%{
               "action" => "fallback.remove",
               "provider" => "zai",
               "scope" => "project",
               "projectDir" => ctx.project
             })

    refute preview["applied"]
    assert preview["confirmation"] == %{"required" => true, "value" => "zai"}
    assert File.read!(ctx.config_path) == content

    assert {:error, :confirmation_required, _} =
             ProviderConfiguration.configure(%{
               "action" => "fallback.remove",
               "provider" => "zai",
               "apply" => true,
               "scope" => "project",
               "projectDir" => ctx.project
             })

    assert File.read!(ctx.config_path) == content

    assert {:ok, removed} =
             ProviderConfiguration.configure(%{
               "action" => "fallback.remove",
               "provider" => "zai",
               "apply" => true,
               "confirm" => "zai",
               "scope" => "project",
               "projectDir" => ctx.project
             })

    assert removed["applied"]

    assert removed["proposedRoutingConfig"]["fallbackProviders"] == [
             "custom-proxy",
             "anthropic"
           ]
  end

  test "manages a redacted credential pool without copying credential values", ctx do
    File.write!(ctx.config_path, "# retained\n")

    assert {:ok, pool} =
             ProviderConfiguration.configure(%{
               "action" => "pool.upsert",
               "pool" => "burst",
               "providers" => ["openai", "zai"],
               "strategy" => "round_robin",
               "activate" => true,
               "apply" => true,
               "scope" => "project",
               "projectDir" => ctx.project
             })

    assert pool["applied"]
    assert pool["proposedRoutingConfig"]["defaultPool"] == "burst"

    assert {:ok, credential} =
             ProviderConfiguration.configure(%{
               "action" => "pool.credential.add",
               "pool" => "burst",
               "provider" => "openai",
               "credentialRef" => "secret:llm_openai_secondary",
               "apply" => true,
               "scope" => "project",
               "projectDir" => ctx.project
             })

    proposed = credential["proposedRoutingConfig"]
    assert proposed["credentialReferenceCount"] == 1
    assert get_in(proposed, ["credentialPools", Access.at(0), "credentialCounts", "openai"]) == 1
    assert credential["cleanup"]["includesCredentialReferences"] == false
    refute inspect(credential) =~ "llm_openai_secondary"

    content = File.read!(ctx.config_path)
    assert content =~ "secret:llm_openai_secondary"
    assert content =~ "# retained"

    assert {:ok, preview} =
             ProviderConfiguration.configure(%{
               "action" => "pool.credential.remove",
               "pool" => "burst",
               "provider" => "openai",
               "credentialRef" => "secret:llm_openai_secondary",
               "scope" => "project",
               "projectDir" => ctx.project
             })

    assert preview["confirmation"] == %{"required" => true, "value" => "burst"}
    assert File.read!(ctx.config_path) == content
  end

  test "rejects raw or malformed credential references before writing", ctx do
    File.write!(ctx.config_path, "# unchanged\n")

    assert {:error, :invalid_credential_reference, message} =
             ProviderConfiguration.configure(%{
               "action" => "pool.credential.add",
               "pool" => "burst",
               "provider" => "openai",
               "credentialRef" => "sk-raw-value",
               "apply" => true,
               "scope" => "project",
               "projectDir" => ctx.project
             })

    refute message =~ "sk-raw-value"
    assert File.read!(ctx.config_path) == "# unchanged\n"
  end

  test "rejects an apply when the target changed after preview", ctx do
    File.write!(ctx.config_path, "# original\n")

    assert {:ok, preview} =
             ProviderConfiguration.configure(%{
               "action" => "fallback.add",
               "provider" => "zai",
               "scope" => "project",
               "projectDir" => ctx.project
             })

    assert is_binary(preview["configRevision"])
    assert preview["configRevision"] != preview["proposedConfigRevision"]

    File.write!(ctx.config_path, "# changed elsewhere\n")

    assert {:error, :stale_configuration, message} =
             ProviderConfiguration.configure(%{
               "action" => "fallback.add",
               "provider" => "zai",
               "apply" => true,
               "expectedRevision" => preview["configRevision"],
               "scope" => "project",
               "projectDir" => ctx.project
             })

    assert message == "Provider configuration changed after the preview; preview again"
    assert File.read!(ctx.config_path) == "# changed elsewhere\n"
  end

  test "validates Lemon config before replacing the target file", ctx do
    original = """
    # removed sections must remain untouched on failure
    [agents.default]
    name = "Default"
    """

    File.write!(ctx.config_path, original)

    assert {:error, :invalid_config, message} =
             ProviderConfiguration.configure(%{
               "action" => "fallback.add",
               "provider" => "zai",
               "apply" => true,
               "scope" => "project",
               "projectDir" => ctx.project
             })

    assert message == "Provider configuration is not valid Lemon config"
    assert File.read!(ctx.config_path) == original
  end

  test "previews then applies the default model and thinking level under [defaults]", ctx do
    File.write!(ctx.config_path, """
    # defaults note
    [defaults]
    provider = "openai"
    model = "gpt-5-mini"
    """)

    params = %{
      "action" => "defaults.model",
      "provider" => "anthropic",
      "model" => "claude-sonnet-4-20250514",
      "scope" => "project",
      "projectDir" => ctx.project
    }

    assert {:ok, preview} = ProviderConfiguration.configure(params)
    assert preview["changed"] == true
    assert preview["destructive"] == false
    assert preview["applied"] == false
    assert preview["defaults"]["model"] == "gpt-5-mini"
    assert preview["proposedDefaults"]["provider"] == "anthropic"
    assert preview["proposedDefaults"]["model"] == "anthropic:claude-sonnet-4-20250514"
    refute File.read!(ctx.config_path) =~ "anthropic"

    assert {:ok, applied} =
             ProviderConfiguration.configure(
               Map.merge(params, %{
                 "apply" => true,
                 "expectedRevision" => preview["configRevision"]
               })
             )

    assert applied["applied"] == true
    content = File.read!(ctx.config_path)
    assert content =~ "# defaults note"
    assert content =~ ~s(provider = "anthropic")
    assert content =~ ~s(model = "anthropic:claude-sonnet-4-20250514")

    thinking = %{
      "action" => "defaults.thinking_level",
      "thinkingLevel" => "high",
      "scope" => "project",
      "projectDir" => ctx.project
    }

    assert {:ok, preview} = ProviderConfiguration.configure(thinking)
    assert preview["proposedDefaults"]["thinkingLevel"] == "high"

    assert {:ok, _} =
             ProviderConfiguration.configure(
               Map.merge(thinking, %{
                 "apply" => true,
                 "expectedRevision" => preview["configRevision"]
               })
             )

    assert File.read!(ctx.config_path) =~ ~s(thinking_level = "high")

    auto = Map.put(thinking, "thinkingLevel", "auto")
    assert {:ok, preview} = ProviderConfiguration.configure(auto)
    assert {:ok, _} =
             ProviderConfiguration.configure(
               Map.merge(auto, %{
                 "apply" => true,
                 "expectedRevision" => preview["configRevision"]
               })
             )
    assert LemonCore.Config.load(ctx.project).agent.default_thinking_level == :auto
  end

  test "rejects unknown providers, malformed models and unsupported thinking levels", ctx do
    File.write!(ctx.config_path, "# untouched\n")
    base = %{"scope" => "project", "projectDir" => ctx.project, "apply" => true}

    assert {:error, :invalid_provider, _} =
             ProviderConfiguration.configure(
               Map.merge(base, %{
                 "action" => "defaults.model",
                 "provider" => "nope",
                 "model" => "x"
               })
             )

    assert {:error, :invalid_model, _} =
             ProviderConfiguration.configure(
               Map.merge(base, %{
                 "action" => "defaults.model",
                 "provider" => "openai",
                 "model" => "gpt 5\"\n[x]"
               })
             )

    assert {:error, :invalid_thinking_level, _} =
             ProviderConfiguration.configure(
               Map.merge(base, %{"action" => "defaults.thinking_level", "thinkingLevel" => "max"})
             )

    assert File.read!(ctx.config_path) == "# untouched\n"
  end
end
