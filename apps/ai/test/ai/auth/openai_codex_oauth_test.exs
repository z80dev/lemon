defmodule Ai.Auth.OpenAICodexOAuthTest do
  use ExUnit.Case, async: false

  alias Ai.Auth.OpenAICodexOAuth
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

    System.delete_env("OPENAI_CODEX_API_KEY")
    System.delete_env("CHATGPT_TOKEN")

    on_exit(fn ->
      Req.default_options(previous_defaults)
      Req.Test.set_req_test_to_private(%{})
      clear_secrets_table()
      System.delete_env("LEMON_SECRETS_MASTER_KEY")
      System.delete_env("OPENAI_CODEX_API_KEY")
      System.delete_env("CHATGPT_TOKEN")
    end)

    :ok
  end

  test "parse_authorization_input handles callback URL and code#state" do
    assert {:ok, %{code: "abc", state: "state1"}} =
             OpenAICodexOAuth.parse_authorization_input(
               "http://localhost:1455/auth/callback?code=abc&state=state1"
             )

    assert {:ok, %{code: "xyz", state: "state2"}} =
             OpenAICodexOAuth.parse_authorization_input("xyz#state2")
  end

  test "resolve_api_key_from_secret returns stored access token" do
    payload =
      Jason.encode!(%{
        "type" => "openai_codex_oauth",
        "refresh_token" => "refresh-token",
        "access_token" => make_jwt("acc_test", 3_600),
        "expires_at_ms" => System.system_time(:millisecond) + 3_600_000,
        "account_id" => "acc_test",
        "created_at_ms" => System.system_time(:millisecond),
        "updated_at_ms" => System.system_time(:millisecond)
      })

    assert {:ok, token} =
             OpenAICodexOAuth.resolve_api_key_from_secret("llm_openai_codex_api_key", payload)

    assert is_binary(token)
    assert String.split(token, ".") |> length() == 3
  end

  test "resolve_access_token prefers OPENAI_CODEX_API_KEY env over stored secrets" do
    oauth_secret =
      Jason.encode!(%{
        "type" => "openai_codex_oauth",
        "refresh_token" => "refresh-token",
        "access_token" => make_jwt("acc_secret", 3_600),
        "expires_at_ms" => System.system_time(:millisecond) + 3_600_000,
        "account_id" => "acc_secret",
        "created_at_ms" => System.system_time(:millisecond),
        "updated_at_ms" => System.system_time(:millisecond)
      })

    assert {:ok, _} = Secrets.set("llm_openai_codex_api_key", oauth_secret)

    System.put_env("OPENAI_CODEX_API_KEY", "env-token")
    assert OpenAICodexOAuth.resolve_access_token() == "env-token"
  end

  test "resolve_access_token reads default oauth secret when env vars are missing" do
    oauth_secret =
      Jason.encode!(%{
        "type" => "openai_codex_oauth",
        "refresh_token" => "refresh-token",
        "access_token" => make_jwt("acc_secret", 3_600),
        "expires_at_ms" => System.system_time(:millisecond) + 3_600_000,
        "account_id" => "acc_secret",
        "created_at_ms" => System.system_time(:millisecond),
        "updated_at_ms" => System.system_time(:millisecond)
      })

    assert {:ok, _} = Secrets.set("llm_openai_codex_api_key", oauth_secret)

    token = OpenAICodexOAuth.resolve_access_token()
    assert is_binary(token)
    assert String.starts_with?(token, "ey") or String.contains?(token, ".")
  end

  test "resolve_api_key_from_secret refreshes near-expiry token and persists updated secret" do
    secret_name = "llm_openai_codex_api_key"

    original_payload =
      Jason.encode!(%{
        "type" => "openai_codex_oauth",
        "refresh_token" => "refresh-token",
        "access_token" => make_jwt("acc_old", -60),
        "expires_at_ms" => System.system_time(:millisecond) - 1_000,
        "account_id" => "acc_old",
        "created_at_ms" => System.system_time(:millisecond),
        "updated_at_ms" => System.system_time(:millisecond)
      })

    assert {:ok, _} = Secrets.set(secret_name, original_payload)

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/oauth/token"

      Plug.Conn.send_resp(
        conn,
        200,
        Jason.encode!(%{
          "access_token" => make_jwt("acc_new", 3_600),
          "refresh_token" => "fresh-refresh-token",
          "expires_in" => 3600
        })
      )
    end)

    assert {:ok, refreshed_token} =
             OpenAICodexOAuth.resolve_api_key_from_secret(secret_name, original_payload)

    assert is_binary(refreshed_token)

    assert {:ok, refreshed_payload} = Secrets.get(secret_name)
    assert {:ok, decoded} = Jason.decode(refreshed_payload)
    assert decoded["refresh_token"] == "fresh-refresh-token"
    assert decoded["account_id"] == "acc_new"
  end

  test "login_device_flow exchanges pasted code and returns oauth secret" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/oauth/token"

      Plug.Conn.send_resp(
        conn,
        200,
        Jason.encode!(%{
          "access_token" => make_jwt("acc_login", 3_600),
          "refresh_token" => "fresh-refresh-token",
          "expires_in" => 3600
        })
      )
    end)

    assert {:ok, secret} =
             OpenAICodexOAuth.login_device_flow(
               on_auth: fn url, _instructions -> send(self(), {:auth_url, url}) end,
               on_prompt: fn _prompt ->
                 receive do
                   {:auth_url, url} ->
                     state = extract_query_param(url, "state")
                     "authorization-code-123##{state}"
                 after
                   1_000 -> ""
                 end
               end
             )

    assert secret["type"] == "openai_codex_oauth"
    assert secret["refresh_token"] == "fresh-refresh-token"
    assert secret["account_id"] == "acc_login"
    assert is_binary(secret["access_token"])
    assert is_integer(secret["expires_at_ms"])
  end

  defp make_jwt(account_id, expires_in_seconds) do
    exp = DateTime.utc_now() |> DateTime.add(expires_in_seconds, :second) |> DateTime.to_unix()

    payload =
      Jason.encode!(%{
        "exp" => exp,
        "https://api.openai.com/auth" => %{"chatgpt_account_id" => account_id}
      })

    "header." <> Base.url_encode64(payload, padding: false) <> ".signature"
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
