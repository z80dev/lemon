defmodule LemonAi.Auth.OAuthForceRefreshTest do
  # Swaps Req's global default plug and OAuth client env vars.
  use ExUnit.Case, async: false

  alias LemonAi.Auth.{
    AnthropicOAuth,
    GitHubCopilotOAuth,
    GoogleAntigravityOAuth,
    GoogleGeminiCliOAuth,
    OpenAICodexOAuth
  }

  @env ~w(GOOGLE_ANTIGRAVITY_OAUTH_CLIENT_ID GOOGLE_ANTIGRAVITY_OAUTH_CLIENT_SECRET)

  @modules [
    {AnthropicOAuth, "anthropic_oauth", "fresh-token"},
    {GitHubCopilotOAuth, "github_copilot_oauth", "fresh-copilot-token"},
    {GoogleAntigravityOAuth, "google_antigravity_oauth", "fresh-token"},
    {GoogleGeminiCliOAuth, "google_gemini_cli_oauth", "fresh-token"},
    {OpenAICodexOAuth, "openai_codex_oauth", "fresh-token"}
  ]

  setup do
    previous_defaults = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})
    previous_env = Map.new(@env, &{&1, System.get_env(&1)})
    System.put_env("GOOGLE_ANTIGRAVITY_OAUTH_CLIENT_ID", "test-client-id")
    System.put_env("GOOGLE_ANTIGRAVITY_OAUTH_CLIENT_SECRET", "test-client-secret")

    test_pid = self()

    # One body every provider's refresh endpoint accepts.
    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, :token_request)

      Req.Test.json(conn, %{
        "access_token" => "fresh-token",
        "refresh_token" => "fresh-refresh-token",
        "expires_in" => 3600,
        "token" => "fresh-copilot-token",
        "expires_at" => div(System.system_time(:millisecond), 1000) + 3600
      })
    end)

    on_exit(fn ->
      Req.default_options(previous_defaults)
      Req.Test.set_req_test_to_private(%{})

      Enum.each(previous_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  for {module, type, fresh} <- @modules do
    describe "#{inspect(module)} force_refresh" do
      test "refreshes and persists an unexpired token the provider rejected" do
        secret = unexpired_secret(unquote(type))
        test_pid = self()

        assert {:ok, _current} =
                 unquote(module).resolve_api_key_from_secret("llm_secret", secret, [])

        refute_received :token_request

        assert {:ok, api_key} =
                 unquote(module).resolve_api_key_from_secret("llm_secret", secret,
                   force_refresh: true,
                   persist_secret: fn name, value ->
                     send(test_pid, {:persisted, name, value})
                     :ok
                   end
                 )

        assert_received :token_request
        assert api_key =~ unquote(fresh)
        assert_received {:persisted, "llm_secret", stored}
        assert Jason.decode!(stored)["access_token"] == unquote(fresh)
      end

      test "fails instead of returning the rejected token when refresh fails" do
        Req.Test.stub(__MODULE__, fn conn ->
          conn
          |> Plug.Conn.put_status(400)
          |> Req.Test.json(%{"error" => "invalid_grant"})
        end)

        assert {:error, _reason} =
                 unquote(module).resolve_api_key_from_secret(
                   "llm_secret",
                   unexpired_secret(unquote(type)),
                   force_refresh: true,
                   persist_secret: fn _name, _value -> :ok end
                 )
      end

      test "reports a payload without a refresh token as not refreshable" do
        secret =
          unquote(type)
          |> unexpired_secret()
          |> Jason.decode!()
          |> Map.delete("refresh_token")
          |> Jason.encode!()

        assert {:error, :not_refreshable} =
                 unquote(module).resolve_api_key_from_secret("llm_secret", secret,
                   force_refresh: true
                 )

        refute_received :token_request
      end
    end
  end

  test "a forced Codex refresh uses a token another caller already rotated" do
    stale = unexpired_secret("openai_codex_oauth")

    rotated =
      stale
      |> Jason.decode!()
      |> Map.put("access_token", "rotated-token")
      |> Jason.encode!()

    assert {:ok, "rotated-token"} =
             OpenAICodexOAuth.resolve_api_key_from_secret("llm_secret", stale,
               force_refresh: true,
               reload_secret: fn "llm_secret" -> {:ok, rotated} end,
               persist_secret: fn _name, _value -> flunk("must not persist") end
             )

    refute_received :token_request
  end

  defp unexpired_secret(type) do
    now = System.system_time(:millisecond)

    Jason.encode!(%{
      "type" => type,
      "refresh_token" => "refresh-token",
      "access_token" => "rejected-token",
      "expires_at_ms" => now + 60 * 60 * 1000,
      "project_id" => "proj-123",
      "managed_project_id" => "proj-123",
      "projectId" => "proj-123",
      "created_at_ms" => now,
      "updated_at_ms" => now
    })
  end
end
