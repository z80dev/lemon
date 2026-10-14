defmodule LemonAi.Auth.OAuthSecretPersistenceTest do
  # Swaps Req's global default plug and OAuth client env vars.
  use ExUnit.Case, async: false

  alias LemonAi.Auth.{
    AnthropicOAuth,
    GitHubCopilotOAuth,
    GoogleAntigravityOAuth,
    GoogleGeminiCliOAuth,
    KimiCodeOAuth,
    OpenAICodexOAuth,
    XAIOAuth
  }

  @env ~w(GOOGLE_ANTIGRAVITY_OAUTH_CLIENT_ID GOOGLE_ANTIGRAVITY_OAUTH_CLIENT_SECRET)

  setup do
    previous_defaults = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})
    previous_env = Map.new(@env, &{&1, System.get_env(&1)})
    System.put_env("GOOGLE_ANTIGRAVITY_OAUTH_CLIENT_ID", "test-client-id")
    System.put_env("GOOGLE_ANTIGRAVITY_OAUTH_CLIENT_SECRET", "test-client-secret")

    # One body every provider's refresh endpoint accepts.
    Req.Test.stub(__MODULE__, fn conn ->
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

  for {module, type} <- [
        {AnthropicOAuth, "anthropic_oauth"},
        {GitHubCopilotOAuth, "github_copilot_oauth"},
        {GoogleAntigravityOAuth, "google_antigravity_oauth"},
        {GoogleGeminiCliOAuth, "google_gemini_cli_oauth"},
        {KimiCodeOAuth, "kimi_code_oauth"},
        {OpenAICodexOAuth, "openai_codex_oauth"},
        {XAIOAuth, "xai_oauth"}
      ] do
    test "#{inspect(module)} reports a refreshed secret it could not store" do
      secret = expired_secret(unquote(type))

      # The authoritative store can fail while a key rotation holds its lock.
      assert {:error, :oauth_secret_persistence_failed} =
               unquote(module).resolve_api_key_from_secret("llm_secret", secret,
                 reload_secret: fn _ -> {:ok, secret, :test_revision} end,
                 persist_secret: fn _name, _value, _revision -> {:error, :secrets_locked} end
               )

      assert {:ok, _api_key} =
               unquote(module).resolve_api_key_from_secret("llm_secret", secret,
                 reload_secret: fn _ -> {:ok, secret, :test_revision} end,
                 persist_secret: fn _name, _value, _revision -> {:ok, %{}} end
               )
    end

    test "#{inspect(module)} requires a meaningful persistence acknowledgement" do
      secret = expired_secret(unquote(type))

      for callback <- [
            fn _, _, _ -> nil end,
            fn _, _, _ -> true end,
            fn _, _, _ -> :unexpected end,
            fn _, _, _ -> {:error, :store_unavailable} end,
            fn _, _, _ -> raise "storage failed" end,
            fn _, _, _ -> throw(:storage_failed) end,
            fn _, _, _ -> exit(:storage_failed) end
          ] do
        assert {:error, :oauth_secret_persistence_failed} =
                 unquote(module).resolve_api_key_from_secret("llm_secret", secret,
                   reload_secret: fn _ -> {:ok, secret, :test_revision} end,
                   persist_secret: callback
                 )
      end
    end

    test "#{inspect(module)} passes the opaque loaded revision unchanged" do
      secret = expired_secret(unquote(type))
      revision = make_ref()
      test_pid = self()

      assert {:ok, _} =
               unquote(module).resolve_api_key_from_secret("llm_secret", secret,
                 reload_secret: fn "llm_secret" -> {:ok, secret, revision} end,
                 persist_secret: fn "llm_secret", _encoded, expected ->
                   send(test_pid, {:revision, expected})
                   :ok
                 end
               )

      assert_received {:revision, ^revision}
    end

    test "#{inspect(module)} rejects missing or value-only reload before requesting a refresh" do
      secret = expired_secret(unquote(type))
      test_pid = self()

      Req.Test.stub(__MODULE__, fn _ ->
        send(test_pid, :unexpected_request)
        flunk("unversioned storage must not refresh")
      end)

      for reload_opts <- [[], [reload_secret: fn _ -> {:ok, secret} end]] do
        opts =
          Keyword.put(reload_opts, :persist_secret, fn _, _, _ ->
            send(test_pid, :unexpected_persist)
            :ok
          end)

        assert {:error, :oauth_secret_reload_failed} =
                 unquote(module).resolve_api_key_from_secret("llm_secret", secret, opts)
      end

      refute_received :unexpected_persist
      refute_received :unexpected_request
    end

    test "#{inspect(module)} never exposes a refreshed key after stale persistence" do
      secret = expired_secret(unquote(type))

      assert {:error, :oauth_secret_changed} =
               unquote(module).resolve_api_key_from_secret("llm_secret", secret,
                 reload_secret: fn _ -> {:ok, secret, :test_revision} end,
                 persist_secret: fn _, _, _ -> {:error, :stale_revision} end
               )
    end
  end

  defp expired_secret(type) do
    now = System.system_time(:millisecond)

    Jason.encode!(%{
      "type" => type,
      "refresh_token" => "refresh-token",
      "access_token" => "stale-token",
      "expires_at_ms" => now - 1_000,
      "project_id" => "proj-123",
      "managed_project_id" => "proj-123",
      "projectId" => "proj-123",
      "token_endpoint" => "https://auth.x.ai/oauth2/token",
      "created_at_ms" => now,
      "updated_at_ms" => now
    })
  end
end
