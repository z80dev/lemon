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
end
