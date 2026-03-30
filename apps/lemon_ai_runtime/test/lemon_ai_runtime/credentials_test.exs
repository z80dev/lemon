defmodule LemonAiRuntime.CredentialsTest do
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
        "lemon_ai_runtime_credentials_test_#{System.unique_integer([:positive])}"
      )

    home_dir = Path.join(tmp_dir, "home")
    File.mkdir_p!(home_dir)

    master_key = :crypto.strong_rand_bytes(32) |> Base.encode64()
    original_home = System.get_env("HOME")
    System.put_env("LEMON_SECRETS_MASTER_KEY", master_key)
    System.put_env("HOME", home_dir)
    Enum.each(@env_keys, &System.delete_env/1)
    Application.delete_env(:lemon_ai_runtime, :oauth_secret_resolver_module)

    on_exit(fn ->
      clear_secrets_table()
      System.delete_env("LEMON_SECRETS_MASTER_KEY")
      if original_home, do: System.put_env("HOME", original_home), else: System.delete_env("HOME")
      Enum.each(@env_keys, &System.delete_env/1)
      Application.delete_env(:lemon_ai_runtime, :oauth_secret_resolver_module)
      File.rm_rf!(tmp_dir)
    end)

    :ok
  end

  test "generic provider precedence is env, then plain config, then secret, then default secret" do
    assert {:ok, _} = Secrets.set("llm_openai_api_key", "from-secret")
    System.put_env("OPENAI_API_KEY", "from-env")

    providers = %{"openai" => %{api_key: "from-plain", api_key_secret: "llm_openai_api_key"}}
    get_api_key = LemonAiRuntime.build_get_api_key(providers)

    assert get_api_key.(:openai) == "from-env"

    System.delete_env("OPENAI_API_KEY")
    assert get_api_key.(:openai) == "from-plain"

    providers = %{"openai" => %{api_key_secret: "llm_openai_api_key"}}
    assert LemonAiRuntime.resolve_provider_api_key(:openai, providers) == "from-secret"

    providers = %{"openai" => %{}}
    assert LemonAiRuntime.resolve_provider_api_key(:openai, providers) == "from-secret"
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

    assert LemonAiRuntime.resolve_provider_api_key(:"openai-codex", providers) ==
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

    assert LemonAiRuntime.resolve_provider_api_key(:"openai-codex", providers) ==
             "codex-from-env"
  end

  test "openai codex missing or invalid auth_source returns empty string sentinel" do
    assert LemonAiRuntime.resolve_provider_api_key(:"openai-codex", %{"openai-codex" => %{}}) ==
             ""

    assert LemonAiRuntime.resolve_provider_api_key(
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

    assert LemonAiRuntime.resolve_provider_api_key(:anthropic, providers) ==
             "anthropic-oauth-token"
  end

  test "anthropic oauth auth_source resolves ambient Claude token env" do
    System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-oat01-env-token")

    providers = %{"anthropic" => %{auth_source: "oauth"}}

    assert LemonAiRuntime.resolve_provider_api_key(:anthropic, providers) ==
             "sk-ant-oat01-env-token"
  end

  test "anthropic oauth auth_source prefers refreshable Claude credentials over static env token" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon_ai_runtime_anthropic_oauth_#{System.unique_integer([:positive])}"
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

    assert LemonAiRuntime.resolve_provider_api_key(:anthropic, providers) ==
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

    assert LemonAiRuntime.resolve_provider_api_key(:anthropic, providers) == ""
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

    assert LemonAiRuntime.resolve_secret_api_key(secret_name) == "copilot-access-token"
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

    resolved = LemonAiRuntime.resolve_secret_api_key(secret_name)
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

    resolved = LemonAiRuntime.resolve_secret_api_key(secret_name)
    assert {:ok, decoded} = Jason.decode(resolved)
    assert decoded["token"] == "gemini-access-token"
    assert decoded["projectId"] == "managed-proj-123"
  end

  test "oauth secret dispatcher falls back to runtime resolvers when configured module is unavailable" do
    Application.put_env(
      :lemon_ai_runtime,
      :oauth_secret_resolver_module,
      LemonAiRuntime.Auth.MissingOAuthSecretResolver
    )

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

    assert LemonAiRuntime.resolve_secret_api_key(secret_name) == "copilot-access-token"
  end

  test "unknown providers do not raise during credential checks" do
    assert LemonAiRuntime.ProviderNames.canonical_name("opencode-go") == nil
    assert LemonAiRuntime.provider_has_credentials?("opencode-go", %{}) == false
    assert LemonAiRuntime.provider_has_credentials?("vercel-ai-gateway", %{}) == false
  end

  defp clear_secrets_table do
    Secrets.table()
    |> LemonCore.Store.list()
    |> Enum.each(fn {key, _} -> LemonCore.Store.delete(Secrets.table(), key) end)
  end
end
