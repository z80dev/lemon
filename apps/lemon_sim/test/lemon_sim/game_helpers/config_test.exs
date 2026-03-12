defmodule LemonSim.GameHelpers.ConfigTest do
  use ExUnit.Case, async: false

  alias LemonSim.GameHelpers.Config
  alias LemonCore.Secrets

  setup do
    master_key = :crypto.strong_rand_bytes(32) |> Base.encode64()
    System.put_env("LEMON_SECRETS_MASTER_KEY", master_key)
    System.delete_env("GOOGLE_GEMINI_CLI_API_KEY")
    System.delete_env("LEMON_GEMINI_PROJECT_ID")
    System.delete_env("GOOGLE_CLOUD_PROJECT")
    System.delete_env("GOOGLE_CLOUD_PROJECT_ID")
    System.delete_env("GCLOUD_PROJECT")

    on_exit(fn ->
      System.delete_env("LEMON_SECRETS_MASTER_KEY")
      System.delete_env("GOOGLE_GEMINI_CLI_API_KEY")
      System.delete_env("LEMON_GEMINI_PROJECT_ID")
      System.delete_env("GOOGLE_CLOUD_PROJECT")
      System.delete_env("GOOGLE_CLOUD_PROJECT_ID")
      System.delete_env("GCLOUD_PROJECT")
    end)

    :ok
  end

  test "gemini provider alias resolves to google_gemini_cli models" do
    model = Config.resolve_model_spec("gemini", "gemini-2.5-pro")

    assert model.provider == :google_gemini_cli
    assert model.id == "gemini-2.5-pro"
  end

  test "provider_name canonicalizes gemini aliases to google_gemini_cli" do
    assert Config.provider_name(:gemini) == "google_gemini_cli"
    assert Config.provider_name("gemini-cli") == "google_gemini_cli"
    assert Config.normalize_provider("gemini") == :google_gemini_cli
  end

  test "codex provider aliases canonicalize to openai-codex" do
    assert Config.provider_name(:"openai-codex") == "openai-codex"
    assert Config.provider_name("openai_codex") == "openai-codex"
    assert Config.normalize_provider("openai-codex") == :"openai-codex"
    assert Config.normalize_provider("openai_codex") == :"openai-codex"
  end

  test "gemini oauth secret resolves to provider-ready json credentials" do
    secret_name = "llm_google_gemini_cli_api_key_#{System.unique_integer([:positive])}"

    oauth_secret =
      Jason.encode!(%{
        "type" => "google_gemini_cli_oauth",
        "refresh_token" => "gemini-refresh-token",
        "access_token" => "gemini-access-token",
        "expires_at_ms" => System.system_time(:millisecond) + 3_600_000,
        "managed_project_id" => "managed-proj-123",
        "project_id" => "managed-proj-123",
        "projectId" => "managed-proj-123",
        "created_at_ms" => System.system_time(:millisecond),
        "updated_at_ms" => System.system_time(:millisecond)
      })

    assert {:ok, _} = Secrets.set(secret_name, oauth_secret)

    config = %{
      providers:
        LemonCore.Config.Providers.resolve(%{
          "providers" => %{"google_gemini_cli" => %{"api_key_secret" => secret_name}}
        })
    }

    resolved = Config.resolve_provider_api_key!(:google_gemini_cli, config, "werewolf")

    assert {:ok, decoded} = Jason.decode(resolved)
    assert decoded["token"] == "gemini-access-token"
    assert decoded["projectId"] == "managed-proj-123"
  end
end
