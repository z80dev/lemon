defmodule Ai.Auth.GitHubCopilotOAuthTest do
  use ExUnit.Case, async: true

  alias Ai.Auth.GitHubCopilotOAuth

  test "normalize_domain parses host from URL or hostname input" do
    assert GitHubCopilotOAuth.normalize_domain("github.com") == "github.com"

    assert GitHubCopilotOAuth.normalize_domain("https://ghe.example.com/path") ==
             "ghe.example.com"

    assert GitHubCopilotOAuth.normalize_domain("") == nil
    assert GitHubCopilotOAuth.normalize_domain("://bad") == nil
  end

  test "resolve_api_key_from_secret ignores non-oauth values" do
    assert :ignore =
             GitHubCopilotOAuth.resolve_api_key_from_secret(
               "llm_github_copilot_api_key",
               "plain-token"
             )
  end

  test "resolve_api_key_from_secret returns stored access token when not near expiry" do
    payload =
      Jason.encode!(%{
        "type" => "github_copilot_oauth",
        "refresh_token" => "github-refresh-token",
        "access_token" => "copilot-access-token",
        "expires_at_ms" => System.system_time(:millisecond) + 3_600_000
      })

    assert {:ok, "copilot-access-token"} =
             GitHubCopilotOAuth.resolve_api_key_from_secret("llm_github_copilot_api_key", payload)
  end
end
