defmodule Ai.Auth.GoogleAntigravityOAuthTest do
  use ExUnit.Case, async: false

  alias Ai.Auth.GoogleAntigravityOAuth
  alias LemonCore.{Secrets, Store}

  setup do
    {:ok, _} = Application.ensure_all_started(:ai)
    {:ok, _} = Application.ensure_all_started(:lemon_core)

    previous_defaults = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})

    clear_secrets_table()

    master_key = :crypto.strong_rand_bytes(32) |> Base.encode64()
    System.put_env("LEMON_SECRETS_MASTER_KEY", master_key)

    assert {:ok, _} =
             Secrets.set(
               "google_antigravity_oauth_client_id",
               "test-antigravity-client-id",
               provider: "test"
             )

    assert {:ok, _} =
             Secrets.set(
               "google_antigravity_oauth_client_secret",
               "test-antigravity-client-secret",
               provider: "test"
             )

    on_exit(fn ->
      Req.default_options(previous_defaults)
      Req.Test.set_req_test_to_private(%{})
      clear_secrets_table()
      System.delete_env("LEMON_SECRETS_MASTER_KEY")
    end)

    :ok
  end

  test "parse_authorization_input handles callback URL" do
    input = "http://localhost:51121/oauth-callback?code=abc123&state=state456"

    assert {:ok, %{code: "abc123", state: "state456"}} =
             GoogleAntigravityOAuth.parse_authorization_input(input)
  end

  test "resolve_api_key_from_secret returns antigravity JSON credentials" do
    payload =
      Jason.encode!(%{
        "type" => "google_antigravity_oauth",
        "refresh_token" => "refresh-token",
        "access_token" => "google-access-token",
        "expires_at_ms" => System.system_time(:millisecond) + 3_600_000,
        "project_id" => "proj-123",
        "created_at_ms" => System.system_time(:millisecond),
        "updated_at_ms" => System.system_time(:millisecond)
      })

    assert {:ok, api_key_json} =
             GoogleAntigravityOAuth.resolve_api_key_from_secret(
               "llm_google_antigravity_api_key",
               payload
             )

    assert {:ok, decoded} = Jason.decode(api_key_json)
    assert decoded["token"] == "google-access-token"
    assert decoded["projectId"] == "proj-123"
  end

  test "resolve_api_key_from_secret refreshes near-expiry token and persists updated secret" do
    secret_name = "llm_google_antigravity_api_key"

    original_payload =
      Jason.encode!(%{
        "type" => "google_antigravity_oauth",
        "refresh_token" => "refresh-token",
        "access_token" => "stale-token",
        "expires_at_ms" => System.system_time(:millisecond) - 1_000,
        "project_id" => "proj-123",
        "created_at_ms" => System.system_time(:millisecond),
        "updated_at_ms" => System.system_time(:millisecond)
      })

    assert {:ok, _} = Secrets.set(secret_name, original_payload)

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/token"

      Plug.Conn.send_resp(
        conn,
        200,
        Jason.encode!(%{
          "access_token" => "fresh-token",
          "refresh_token" => "fresh-refresh-token",
          "expires_in" => 3600
        })
      )
    end)

    assert {:ok, api_key_json} =
             GoogleAntigravityOAuth.resolve_api_key_from_secret(secret_name, original_payload)

    assert {:ok, decoded_api_key} = Jason.decode(api_key_json)
    assert decoded_api_key["token"] == "fresh-token"
    assert decoded_api_key["projectId"] == "proj-123"

    assert {:ok, refreshed_payload} = Secrets.get(secret_name)
    assert {:ok, decoded_secret} = Jason.decode(refreshed_payload)
    assert decoded_secret["access_token"] == "fresh-token"
    assert decoded_secret["refresh_token"] == "fresh-refresh-token"
    assert decoded_secret["project_id"] == "proj-123"
  end

  test "login_device_flow exchanges pasted callback URL and returns oauth secret" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/token"

      Plug.Conn.send_resp(
        conn,
        200,
        Jason.encode!(%{
          "access_token" => "fresh-login-token",
          "refresh_token" => "fresh-refresh-token",
          "expires_in" => 3600
        })
      )
    end)

    assert {:ok, secret} =
             GoogleAntigravityOAuth.login_device_flow(
               on_auth: fn url, _instructions -> send(self(), {:auth_url, url}) end,
               on_prompt: fn _prompt ->
                 receive do
                   {:auth_url, url} ->
                     state = extract_query_param(url, "state")

                     "http://localhost:51121/oauth-callback?code=authorization-code-123&state=#{state}"
                 after
                   1_000 -> ""
                 end
               end
             )

    assert secret["type"] == "google_antigravity_oauth"
    assert secret["access_token"] == "fresh-login-token"
    assert secret["refresh_token"] == "fresh-refresh-token"
    assert secret["project_id"] == "rising-fact-p41fc"
    assert is_integer(secret["expires_at_ms"])
  end

  defp clear_secrets_table do
    Store.list(Secrets.table())
    |> Enum.each(fn {key, _value} ->
      Store.delete(Secrets.table(), key)
    end)
  end

  defp extract_query_param(url, key) do
    with %URI{query: query} when is_binary(query) <- URI.parse(url),
         params <- URI.decode_query(query) do
      params[key]
    else
      _ -> nil
    end
  end
end
