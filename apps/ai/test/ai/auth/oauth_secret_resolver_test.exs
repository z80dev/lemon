defmodule Ai.Auth.OAuthSecretResolverTest do
  use ExUnit.Case, async: false

  alias Ai.Auth.OAuthSecretResolver

  test "returns :ignore for non-oauth values" do
    assert :ignore =
             OAuthSecretResolver.resolve_api_key_from_secret("llm_openai_api_key", "plain-token")
  end

  test "dispatches to codex resolver for openai_codex_oauth payloads" do
    payload =
      Jason.encode!(%{
        "type" => "openai_codex_oauth",
        "refresh_token" => "refresh-token",
        "access_token" => "header.payload.signature",
        "expires_at_ms" => System.system_time(:millisecond) + 3_600_000,
        "created_at_ms" => System.system_time(:millisecond),
        "updated_at_ms" => System.system_time(:millisecond)
      })

    assert {:ok, "header.payload.signature"} =
             OAuthSecretResolver.resolve_api_key_from_secret("llm_openai_codex_api_key", payload)
  end

  test "dispatches to anthropic resolver for anthropic_oauth payloads" do
    payload =
      Jason.encode!(%{
        "type" => "anthropic_oauth",
        "refresh_token" => "refresh-token",
        "access_token" => "sk-ant-oat01-test-token",
        "expires_at_ms" => System.system_time(:millisecond) + 3_600_000,
        "created_at_ms" => System.system_time(:millisecond),
        "updated_at_ms" => System.system_time(:millisecond)
      })

    assert {:ok, "sk-ant-oat01-test-token"} =
             OAuthSecretResolver.resolve_api_key_from_secret("llm_anthropic_api_key", payload)
  end

  test "dispatches to Gemini CLI resolver for google_gemini_cli_oauth payloads" do
    payload =
      Jason.encode!(%{
        "type" => "google_gemini_cli_oauth",
        "refresh_token" => "refresh-token",
        "access_token" => "gemini-access-token",
        "expires_at_ms" => System.system_time(:millisecond) + 3_600_000,
        "managed_project_id" => "managed-project-123",
        "project_id" => "managed-project-123",
        "projectId" => "managed-project-123",
        "created_at_ms" => System.system_time(:millisecond),
        "updated_at_ms" => System.system_time(:millisecond)
      })

    assert {:ok, api_key_json} =
             OAuthSecretResolver.resolve_api_key_from_secret(
               "llm_google_gemini_cli_api_key",
               payload
             )

    assert {:ok, decoded} = Jason.decode(api_key_json)
    assert decoded["token"] == "gemini-access-token"
    assert decoded["projectId"] == "managed-project-123"
  end
end
