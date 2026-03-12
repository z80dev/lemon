defmodule Ai.Auth.GoogleGeminiCliOAuthTest do
  use ExUnit.Case, async: false

  alias Ai.Auth.GoogleGeminiCliOAuth
  alias LemonCore.{Secrets, Store}

  setup do
    {:ok, _} = Application.ensure_all_started(:ai)
    {:ok, _} = Application.ensure_all_started(:lemon_core)
    :inets.start()
    :ssl.start()

    previous_defaults = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})

    clear_secrets_table()

    master_key = :crypto.strong_rand_bytes(32) |> Base.encode64()
    System.put_env("LEMON_SECRETS_MASTER_KEY", master_key)
    System.delete_env("LEMON_GEMINI_PROJECT_ID")
    System.delete_env("GOOGLE_CLOUD_PROJECT")
    System.delete_env("GOOGLE_CLOUD_PROJECT_ID")
    System.delete_env("GCLOUD_PROJECT")

    on_exit(fn ->
      Req.default_options(previous_defaults)
      Req.Test.set_req_test_to_private(%{})
      clear_secrets_table()
      System.delete_env("LEMON_SECRETS_MASTER_KEY")
      System.delete_env("LEMON_GEMINI_PROJECT_ID")
      System.delete_env("GOOGLE_CLOUD_PROJECT")
      System.delete_env("GOOGLE_CLOUD_PROJECT_ID")
      System.delete_env("GCLOUD_PROJECT")
    end)

    :ok
  end

  test "parse_authorization_input handles callback URL" do
    input = "http://localhost:8085/oauth2callback?code=abc123&state=state456"

    assert {:ok, %{code: "abc123", state: "state456"}} =
             GoogleGeminiCliOAuth.parse_authorization_input(input)
  end

  test "resolve_api_key_from_secret returns Gemini CLI JSON credentials" do
    payload =
      Jason.encode!(%{
        "type" => "google_gemini_cli_oauth",
        "refresh_token" => "refresh-token",
        "access_token" => "google-access-token",
        "expires_at_ms" => System.system_time(:millisecond) + 3_600_000,
        "managed_project_id" => "managed-project-123",
        "project_id" => "managed-project-123",
        "projectId" => "managed-project-123",
        "created_at_ms" => System.system_time(:millisecond),
        "updated_at_ms" => System.system_time(:millisecond)
      })

    assert {:ok, api_key_json} =
             GoogleGeminiCliOAuth.resolve_api_key_from_secret(
               "llm_google_gemini_cli_api_key",
               payload
             )

    assert {:ok, decoded} = Jason.decode(api_key_json)
    assert decoded["token"] == "google-access-token"
    assert decoded["projectId"] == "managed-project-123"
  end

  test "resolve_api_key_from_secret refreshes near-expiry token and persists updated secret" do
    secret_name = "llm_google_gemini_cli_api_key"

    original_payload =
      Jason.encode!(%{
        "type" => "google_gemini_cli_oauth",
        "refresh_token" => "refresh-token",
        "access_token" => "stale-token",
        "expires_at_ms" => System.system_time(:millisecond) - 1_000,
        "managed_project_id" => "managed-project-123",
        "project_id" => "managed-project-123",
        "projectId" => "managed-project-123",
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
             GoogleGeminiCliOAuth.resolve_api_key_from_secret(secret_name, original_payload)

    assert {:ok, decoded_api_key} = Jason.decode(api_key_json)
    assert decoded_api_key["token"] == "fresh-token"
    assert decoded_api_key["projectId"] == "managed-project-123"

    assert {:ok, refreshed_payload} = Secrets.get(secret_name)
    assert {:ok, decoded_secret} = Jason.decode(refreshed_payload)
    assert decoded_secret["access_token"] == "fresh-token"
    assert decoded_secret["refresh_token"] == "fresh-refresh-token"
  end

  test "login_device_flow exchanges pasted callback URL and resolves a managed project" do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/token" ->
          Plug.Conn.send_resp(
            conn,
            200,
            Jason.encode!(%{
              "access_token" => "fresh-login-token",
              "refresh_token" => "fresh-refresh-token",
              "expires_in" => 3600
            })
          )

        "/oauth2/v1/userinfo" ->
          Plug.Conn.send_resp(conn, 200, Jason.encode!(%{"email" => "dev@example.com"}))

        "/v1internal:loadCodeAssist" ->
          Plug.Conn.send_resp(
            conn,
            200,
            Jason.encode!(%{
              "cloudaicompanionProject" => %{"id" => "managed-project-123"}
            })
          )

        _ ->
          flunk("unexpected request path #{conn.request_path}")
      end
    end)

    assert {:ok, secret} =
             GoogleGeminiCliOAuth.login_device_flow(
               listen_for_callback: false,
               on_auth: fn url, _instructions -> send(self(), {:auth_url, url}) end,
               on_prompt: fn _prompt ->
                 receive do
                   {:auth_url, url} ->
                     state = extract_query_param(url, "state")

                     "http://localhost:8085/oauth2callback?code=authorization-code-123&state=#{state}"
                 after
                   1_000 -> ""
                 end
               end
             )

    assert secret["type"] == "google_gemini_cli_oauth"
    assert secret["access_token"] == "fresh-login-token"
    assert secret["refresh_token"] == "fresh-refresh-token"
    assert secret["managed_project_id"] == "managed-project-123"
    assert secret["project_id"] == "managed-project-123"
    assert secret["email"] == "dev@example.com"
  end

  test "exchange_code_for_secret onboards free-tier users when no project is preconfigured" do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/token" ->
          Plug.Conn.send_resp(
            conn,
            200,
            Jason.encode!(%{
              "access_token" => "fresh-login-token",
              "refresh_token" => "fresh-refresh-token",
              "expires_in" => 3600
            })
          )

        "/oauth2/v1/userinfo" ->
          Plug.Conn.send_resp(conn, 200, Jason.encode!(%{"email" => "dev@example.com"}))

        "/v1internal:loadCodeAssist" ->
          Plug.Conn.send_resp(
            conn,
            200,
            Jason.encode!(%{
              "allowedTiers" => [%{"id" => "free-tier", "isDefault" => true}]
            })
          )

        "/v1internal:onboardUser" ->
          Plug.Conn.send_resp(
            conn,
            200,
            Jason.encode!(%{
              "done" => true,
              "response" => %{
                "cloudaicompanionProject" => %{"id" => "managed-free-project"}
              }
            })
          )

        _ ->
          flunk("unexpected request path #{conn.request_path}")
      end
    end)

    assert {:ok, secret} =
             GoogleGeminiCliOAuth.exchange_code_for_secret("authorization-code", "pkce-verifier")

    assert secret["managed_project_id"] == "managed-free-project"
    assert secret["project_id"] == "managed-free-project"
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
