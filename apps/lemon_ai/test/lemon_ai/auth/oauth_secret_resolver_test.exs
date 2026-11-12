defmodule LemonAi.Auth.OAuthSecretResolverTest do
  use ExUnit.Case, async: false

  alias LemonAi.Auth.OAuthSecretResolver

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

  describe "a refresh that loses the revision check to another writer" do
    # The store holds {encoded login, revision}; persist is a compare-and-set.
    setup do
      now = System.system_time(:millisecond)

      login = fn access, expires_at_ms ->
        Jason.encode!(%{
          "type" => "kimi_code_oauth",
          "access_token" => access,
          "refresh_token" => "rt-" <> access,
          "expires_at_ms" => expires_at_ms
        })
      end

      stale = login.("near-expiry", now + 60_000)
      {:ok, store} = Agent.start_link(fn -> {stale, 1} end)

      opts = [
        req_options: [plug: {Req.Test, __MODULE__}],
        reload_secret: fn _name ->
          {encoded, revision} = Agent.get(store, & &1)
          {:ok, encoded, revision}
        end,
        persist_secret: fn _name, encoded, expected ->
          Agent.get_and_update(store, fn
            {_, ^expected} -> {:ok, {encoded, expected + 1}}
            current -> {{:error, :stale_revision}, current}
          end)
        end
      ]

      {:ok, now: now, login: login, stale: stale, store: store, opts: opts}
    end

    # The token endpoint answers only after a concurrent writer (another Lemon
    # process) stored its own refresh of the same login.
    defp refresh_racing(store, peer_login) do
      Req.Test.stub(__MODULE__, fn conn ->
        Agent.update(store, fn {_, revision} -> {peer_login, revision + 1} end)

        Req.Test.json(conn, %{
          "access_token" => "losing-refresh",
          "refresh_token" => "losing-rt",
          "expires_in" => 900
        })
      end)
    end

    test "adopts the stored login when its access token is fresh", ctx do
      peer = ctx.login.("peer-refresh", ctx.now + 900_000)
      refresh_racing(ctx.store, peer)

      assert {:ok, "peer-refresh"} =
               OAuthSecretResolver.resolve_api_key_from_secret("kimi", ctx.stale, ctx.opts)

      assert {^peer, _} = Agent.get(ctx.store, & &1)
    end

    test "fails when the stored login is expired or still the token this caller held", ctx do
      for peer <- [
            ctx.login.("peer-expired", ctx.now - 1_000),
            ctx.login.("near-expiry", ctx.now + 60_000)
          ] do
        Agent.update(ctx.store, fn _ -> {ctx.stale, 1} end)
        refresh_racing(ctx.store, peer)

        assert {:error, :oauth_secret_changed} =
                 OAuthSecretResolver.resolve_api_key_from_secret("kimi", ctx.stale, ctx.opts)

        assert {^peer, _} = Agent.get(ctx.store, & &1)
      end
    end
  end
end
