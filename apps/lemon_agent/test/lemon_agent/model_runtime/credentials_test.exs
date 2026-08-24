defmodule LemonAgent.ModelRuntime.CredentialsTest do
  use ExUnit.Case, async: false

  alias LemonCore.Secrets

  @env_keys ~w(
    OPENAI_API_KEY
    OPENAI_CODEX_API_KEY
    CHATGPT_TOKEN
    ANTHROPIC_API_KEY
    ANTHROPIC_TOKEN
    CLAUDE_CODE_OAUTH_TOKEN
    OPENCODE_API_KEY
    GITHUB_COPILOT_API_KEY
    GOOGLE_GEMINI_CLI_API_KEY
    GOOGLE_GENERATIVE_AI_API_KEY
    GOOGLE_API_KEY
    GEMINI_API_KEY
    GOOGLE_APPLICATION_CREDENTIALS
    LEMON_GEMINI_PROJECT_ID
    GOOGLE_CLOUD_PROJECT
    GOOGLE_CLOUD_PROJECT_ID
    GCLOUD_PROJECT
    GOOGLE_CLOUD_LOCATION
    AZURE_OPENAI_API_KEY
    AZURE_OPENAI_API_VERSION
    AZURE_OPENAI_BASE_URL
    AZURE_OPENAI_RESOURCE_NAME
    AWS_REGION
    AWS_DEFAULT_REGION
    AWS_ACCESS_KEY_ID
    AWS_SECRET_ACCESS_KEY
    AWS_SESSION_TOKEN
    AWS_PROFILE
  )

  setup do
    clear_secrets_table()

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "agent_core_model_runtime_credentials_test_#{System.unique_integer([:positive])}"
      )

    home_dir = Path.join(tmp_dir, "home")
    File.mkdir_p!(home_dir)

    master_key = :crypto.strong_rand_bytes(32) |> Base.encode64()
    original_home = System.get_env("HOME")
    System.put_env("LEMON_SECRETS_MASTER_KEY", master_key)
    System.put_env("HOME", home_dir)
    Enum.each(@env_keys, &System.delete_env/1)
    Application.delete_env(:lemon_agent, :oauth_secret_resolver_module)

    on_exit(fn ->
      clear_secrets_table()
      System.delete_env("LEMON_SECRETS_MASTER_KEY")
      if original_home, do: System.put_env("HOME", original_home), else: System.delete_env("HOME")
      Enum.each(@env_keys, &System.delete_env/1)
      Application.delete_env(:lemon_agent, :oauth_secret_resolver_module)
      File.rm_rf!(tmp_dir)
    end)

    :ok
  end

  test "generic provider precedence is env, then plain config, then secret, then default secret" do
    assert {:ok, _} = Secrets.set("llm_openai_api_key", "from-secret")
    System.put_env("OPENAI_API_KEY", "from-env")

    providers = %{"openai" => %{api_key: "from-plain", api_key_secret: "llm_openai_api_key"}}
    get_api_key = LemonAgent.ModelRuntime.Credentials.build_get_api_key(providers)

    assert get_api_key.(:openai) == "from-env"

    System.delete_env("OPENAI_API_KEY")
    assert get_api_key.(:openai) == "from-plain"

    providers = %{"openai" => %{api_key_secret: "llm_openai_api_key"}}

    assert LemonAgent.ModelRuntime.Credentials.resolve_provider_api_key(:openai, providers) ==
             "from-secret"

    providers = %{"openai" => %{}}

    assert LemonAgent.ModelRuntime.Credentials.resolve_provider_api_key(:openai, providers) ==
             "from-secret"
  end

  test "openai codex oauth auth_source prefers oauth_secret payload and ignores env/plain key path" do
    oauth_secret =
      Jason.encode!(%{
        "type" => "onboarding_openai_codex_oauth",
        "access_token" => "codex-access-token",
        "refresh_token" => "codex-refresh-token",
        "expires_at_ms" => System.system_time(:millisecond) + 3_600_000
      })

    assert {:ok, _} = Secrets.set("llm_openai_codex_api_key", oauth_secret)
    System.put_env("OPENAI_CODEX_API_KEY", "codex-from-env")

    providers = %{
      "openai-codex" => %{
        auth_source: "oauth",
        api_key: "codex-from-plain",
        oauth_secret: "llm_openai_codex_api_key"
      }
    }

    assert LemonAgent.ModelRuntime.Credentials.resolve_provider_api_key(
             :"openai-codex",
             providers
           ) ==
             "codex-access-token"
  end

  test "openai codex api_key auth_source resolves env or plain key and does not use oauth payload by default" do
    oauth_secret =
      Jason.encode!(%{
        "type" => "openai_codex_oauth",
        "access_token" => "codex-oauth-token",
        "refresh_token" => "codex-refresh-token",
        "expires_at_ms" => System.system_time(:millisecond) + 3_600_000,
        "account_id" => "acct_test_123"
      })

    assert {:ok, _} = Secrets.set("llm_openai_codex_api_key", oauth_secret)
    System.put_env("OPENAI_CODEX_API_KEY", "codex-from-env")

    providers = %{
      "openai_codex" => %{auth_source: "api_key", api_key_secret: "llm_openai_codex_api_key"}
    }

    assert LemonAgent.ModelRuntime.Credentials.resolve_provider_api_key(
             :"openai-codex",
             providers
           ) ==
             "codex-from-env"
  end

  test "openai codex missing or invalid auth_source returns empty string sentinel" do
    assert LemonAgent.ModelRuntime.Credentials.resolve_provider_api_key(:"openai-codex", %{
             "openai-codex" => %{}
           }) ==
             ""

    assert LemonAgent.ModelRuntime.Credentials.resolve_provider_api_key(
             :"openai-codex",
             %{"openai-codex" => %{auth_source: "wrong"}}
           ) == ""
  end

  test "anthropic oauth auth_source resolves oauth payload secret" do
    oauth_secret =
      Jason.encode!(%{
        "type" => "anthropic_oauth",
        "access_token" => "anthropic-oauth-token",
        "refresh_token" => "anthropic-refresh-token",
        "expires_at_ms" => System.system_time(:millisecond) + 3_600_000
      })

    assert {:ok, _} = Secrets.set("llm_anthropic_api_key", oauth_secret)

    providers = %{"anthropic" => %{auth_source: "oauth", oauth_secret: "llm_anthropic_api_key"}}

    assert LemonAgent.ModelRuntime.Credentials.resolve_provider_api_key(:anthropic, providers) ==
             "anthropic-oauth-token"
  end

  test "anthropic oauth auth_source resolves ambient Claude token env" do
    System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-oat01-env-token")

    providers = %{"anthropic" => %{auth_source: "oauth"}}

    assert LemonAgent.ModelRuntime.Credentials.resolve_provider_api_key(:anthropic, providers) ==
             "sk-ant-oat01-env-token"
  end

  test "anthropic oauth auth_source prefers refreshable Claude credentials over static env token" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "agent_core_model_runtime_anthropic_oauth_#{System.unique_integer([:positive])}"
      )

    home_dir = Path.join(tmp_dir, "home")
    credentials_path = Path.join([home_dir, ".claude", ".credentials.json"])
    original_home = System.get_env("HOME")

    File.mkdir_p!(Path.dirname(credentials_path))

    File.write!(
      credentials_path,
      Jason.encode!(%{
        "claudeAiOauth" => %{
          "accessToken" => "sk-ant-oat01-refreshable-token",
          "refreshToken" => "refresh-token",
          "expiresAt" => System.system_time(:millisecond) + 3_600_000
        }
      })
    )

    System.put_env("HOME", home_dir)
    System.put_env("ANTHROPIC_TOKEN", "sk-ant-oat01-static-token")

    on_exit(fn ->
      if original_home, do: System.put_env("HOME", original_home), else: System.delete_env("HOME")
      File.rm_rf!(tmp_dir)
    end)

    providers = %{"anthropic" => %{auth_source: "oauth"}}

    assert LemonAgent.ModelRuntime.Credentials.resolve_provider_api_key(:anthropic, providers) ==
             "sk-ant-oat01-refreshable-token"
  end

  test "anthropic rejects oauth payload secret for raw api key resolution" do
    oauth_secret =
      Jason.encode!(%{
        "type" => "anthropic_oauth",
        "access_token" => "anthropic-oauth-token",
        "refresh_token" => "anthropic-refresh-token",
        "expires_at_ms" => System.system_time(:millisecond) + 3_600_000
      })

    assert {:ok, _} = Secrets.set("llm_anthropic_api_key", oauth_secret)

    providers = %{"anthropic" => %{api_key_secret: "llm_anthropic_api_key"}}

    assert LemonAgent.ModelRuntime.Credentials.resolve_provider_api_key(:anthropic, providers) ==
             ""
  end

  test "github copilot oauth payload resolves to access token" do
    secret_name = "llm_github_copilot_api_key"

    assert {:ok, _} =
             Secrets.set(
               secret_name,
               Jason.encode!(%{
                 "type" => "github_copilot_oauth",
                 "refresh_token" => "github-refresh-token",
                 "access_token" => "copilot-access-token",
                 "expires_at_ms" => System.system_time(:millisecond) + 3_600_000
               })
             )

    assert LemonAgent.ModelRuntime.Credentials.resolve_secret_api_key(secret_name) ==
             "copilot-access-token"
  end

  test "google antigravity oauth payload resolves to provider json" do
    secret_name = "llm_google_antigravity_api_key"

    assert {:ok, _} =
             Secrets.set(
               secret_name,
               Jason.encode!(%{
                 "type" => "google_antigravity_oauth",
                 "refresh_token" => "google-refresh-token",
                 "access_token" => "google-access-token",
                 "expires_at_ms" => System.system_time(:millisecond) + 3_600_000,
                 "project_id" => "proj-123"
               })
             )

    resolved = LemonAgent.ModelRuntime.Credentials.resolve_secret_api_key(secret_name)
    assert {:ok, decoded} = Jason.decode(resolved)
    assert decoded["token"] == "google-access-token"
    assert decoded["projectId"] == "proj-123"
  end

  test "google gemini cli oauth payload resolves to provider json" do
    secret_name = "llm_google_gemini_cli_api_key"

    assert {:ok, _} =
             Secrets.set(
               secret_name,
               Jason.encode!(%{
                 "type" => "google_gemini_cli_oauth",
                 "refresh_token" => "gemini-refresh-token",
                 "access_token" => "gemini-access-token",
                 "expires_at_ms" => System.system_time(:millisecond) + 3_600_000,
                 "managed_project_id" => "managed-proj-123",
                 "project_id" => "managed-proj-123",
                 "projectId" => "managed-proj-123"
               })
             )

    resolved = LemonAgent.ModelRuntime.Credentials.resolve_secret_api_key(secret_name)
    assert {:ok, decoded} = Jason.decode(resolved)
    assert decoded["token"] == "gemini-access-token"
    assert decoded["projectId"] == "managed-proj-123"
  end

  test "google vertex credential check resolves explicit provider config through shared resolver" do
    assert {:ok, _} = Secrets.set("vertex_sa", "{\"client_email\":\"svc@example.com\"}")

    providers = %{
      "google_vertex" => %{
        "project" => "vertex-project",
        "location" => "us-central1",
        "service_account_json_secret" => "vertex_sa"
      }
    }

    assert LemonAgent.ModelRuntime.Credentials.provider_has_credentials?(
             :google_vertex,
             providers
           )
  end

  test "oauth secret dispatcher resolves provider oauth payloads" do
    secret_name = "llm_github_copilot_api_key"

    assert {:ok, _} =
             Secrets.set(
               secret_name,
               Jason.encode!(%{
                 "type" => "github_copilot_oauth",
                 "refresh_token" => "github-refresh-token",
                 "access_token" => "copilot-access-token",
                 "expires_at_ms" => System.system_time(:millisecond) + 3_600_000
               })
             )

    assert LemonAgent.ModelRuntime.Credentials.resolve_secret_api_key(secret_name) ==
             "copilot-access-token"
  end

  test "opencode go shares the opencode environment credential" do
    System.put_env("OPENCODE_API_KEY", "opencode-go-token")

    assert LemonAgent.ModelRuntime.ProviderNames.canonical_name("opencode-go") == "opencode_go"

    assert LemonAgent.ModelRuntime.Credentials.resolve_provider_api_key("opencode-go", %{}) ==
             "opencode-go-token"
  end

  test "unknown providers do not raise during credential checks" do
    assert LemonAgent.ModelRuntime.Credentials.provider_has_credentials?("vercel-ai-gateway", %{}) ==
             false
  end

  test "provider names expose sorted canonical ids for diagnostics" do
    names = LemonAgent.ModelRuntime.ProviderNames.all_canonical_names()

    assert names == Enum.sort(names)
    assert "anthropic" in names
    assert "openai" in names
    assert "zai" in names
  end

  describe "credential pools" do
    setup do
      LemonAgent.ModelRuntime.CredentialHealth.reset()

      Enum.each(~w(POOL_KEY_TWO RAW_REF_KEY), &System.delete_env/1)

      on_exit(fn ->
        LemonAgent.ModelRuntime.CredentialHealth.reset()
        Enum.each(~w(POOL_KEY_TWO RAW_REF_KEY), &System.delete_env/1)
      end)

      :ok
    end

    test "list_provider_api_keys returns pool credentials first, then the default resolution" do
      assert {:ok, _} = Secrets.set("pool_key_one", "key-one")
      System.put_env("POOL_KEY_TWO", "key-two")

      config = pool_config(%{"openai" => %{api_key: "default-key"}})

      assert LemonAgent.ModelRuntime.Credentials.list_provider_api_keys(config, :openai) == [
               %{ref: "secret:pool_key_one", api_key: "key-one"},
               %{ref: "env:POOL_KEY_TWO", api_key: "key-two"},
               %{ref: "default", api_key: "default-key"}
             ]
    end

    test "list_provider_api_keys skips refs that fail to resolve" do
      # pool_key_one secret intentionally missing; POOL_KEY_TWO env unset.
      config = pool_config(%{"openai" => %{api_key: "default-key"}})

      assert LemonAgent.ModelRuntime.Credentials.list_provider_api_keys(config, :openai) == [
               %{ref: "default", api_key: "default-key"}
             ]
    end

    test "list_provider_api_keys selects the pool through the default profile" do
      System.put_env("POOL_KEY_TWO", "key-two")

      config = %{
        providers: %{},
        provider_routing: %{
          default_profile: "ops",
          profiles: %{"ops" => %{credential_pool: "burst"}},
          credential_pools: %{
            "burst" => %{
              providers: ["openai"],
              strategy: "priority",
              credentials: %{"openai" => [%{source: :env, name: "POOL_KEY_TWO"}]}
            }
          }
        }
      }

      assert LemonAgent.ModelRuntime.Credentials.list_provider_api_keys(config, :openai) == [
               %{ref: "env:POOL_KEY_TWO", api_key: "key-two"}
             ]
    end

    test "list_provider_api_keys accepts raw string refs from hand-built settings" do
      assert {:ok, _} = Secrets.set("bare_secret_name", "bare-secret-key")
      System.put_env("RAW_REF_KEY", "raw-env-key")

      config = %{
        providers: %{},
        provider_routing: %{
          default_pool: "burst",
          credential_pools: %{
            "burst" => %{
              providers: ["openai"],
              strategy: "priority",
              credentials: %{"openai" => ["env:RAW_REF_KEY", "bare_secret_name"]}
            }
          }
        }
      }

      assert LemonAgent.ModelRuntime.Credentials.list_provider_api_keys(config, :openai) == [
               %{ref: "env:RAW_REF_KEY", api_key: "raw-env-key"},
               %{ref: "secret:bare_secret_name", api_key: "bare-secret-key"}
             ]
    end

    test "build_get_api_key skips credentials in cooldown" do
      assert {:ok, _} = Secrets.set("pool_key_one", "key-one")
      System.put_env("POOL_KEY_TWO", "key-two")

      config = pool_config(%{"openai" => %{api_key: "default-key"}})
      get_api_key = LemonAgent.ModelRuntime.Credentials.build_get_api_key(config)

      assert get_api_key.(:openai) == "key-one"

      LemonAgent.ModelRuntime.CredentialHealth.record_failure(
        :openai,
        "secret:pool_key_one",
        :auth
      )

      assert get_api_key.(:openai) == "key-two"

      LemonAgent.ModelRuntime.CredentialHealth.record_failure(:openai, "env:POOL_KEY_TWO", :auth)
      assert get_api_key.(:openai) == "default-key"
    end

    test "build_get_api_key falls back to the first credential when all are cooling down" do
      assert {:ok, _} = Secrets.set("pool_key_one", "key-one")

      config = pool_config(%{})
      get_api_key = LemonAgent.ModelRuntime.Credentials.build_get_api_key(config)

      LemonAgent.ModelRuntime.CredentialHealth.record_failure(
        :openai,
        "secret:pool_key_one",
        :auth
      )

      assert get_api_key.(:openai) == "key-one"
    end

    test "build_get_api_key with a bare providers map matches single-credential resolution" do
      providers = %{"openai" => %{api_key: "plain-key"}}
      get_api_key = LemonAgent.ModelRuntime.Credentials.build_get_api_key(providers)

      assert get_api_key.(:openai) ==
               LemonAgent.ModelRuntime.Credentials.resolve_provider_api_key(:openai, providers)

      assert get_api_key.(:openai) == "plain-key"
    end

    test "provider_has_credentials? counts resolvable pool credentials" do
      System.put_env("POOL_KEY_TWO", "key-two")
      routing = pool_config(%{}).provider_routing

      assert LemonAgent.ModelRuntime.Credentials.provider_has_credentials?(:openai, %{},
               provider_routing: routing
             )

      refute LemonAgent.ModelRuntime.Credentials.provider_has_credentials?(:zai, %{},
               provider_routing: routing
             )
    end

    defp pool_config(providers) do
      %{
        providers: providers,
        provider_routing: %{
          default_pool: "burst",
          credential_pools: %{
            "burst" => %{
              providers: ["openai"],
              strategy: "priority",
              credentials: %{
                "openai" => [
                  %{source: :secret, name: "pool_key_one"},
                  %{source: :env, name: "POOL_KEY_TWO"}
                ]
              }
            }
          }
        }
      }
    end
  end

  defp clear_secrets_table do
    Secrets.table()
    |> LemonCore.Store.list()
    |> Enum.each(fn {key, _} -> LemonCore.Store.delete(Secrets.table(), key) end)
  end
end
