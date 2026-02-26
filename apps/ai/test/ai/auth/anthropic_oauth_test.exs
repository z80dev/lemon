defmodule Ai.Auth.AnthropicOAuthTest do
  use ExUnit.Case, async: false

  alias Ai.Auth.AnthropicOAuth
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

    on_exit(fn ->
      Req.default_options(previous_defaults)
      Req.Test.set_req_test_to_private(%{})
      clear_secrets_table()
      System.delete_env("LEMON_SECRETS_MASTER_KEY")
    end)

    :ok
  end

  test "parse_authorization_input handles code#state" do
    assert {:ok, %{code: "abc", state: "state123"}} =
             AnthropicOAuth.parse_authorization_input("abc#state123")
  end

  test "resolve_api_key_from_secret returns stored access token" do
    payload =
      Jason.encode!(%{
        "type" => "anthropic_oauth",
        "refresh_token" => "refresh-token",
        "access_token" => "anthropic-access-token",
        "expires_at_ms" => System.system_time(:millisecond) + 3_600_000,
        "created_at_ms" => System.system_time(:millisecond),
        "updated_at_ms" => System.system_time(:millisecond)
      })

    assert {:ok, "anthropic-access-token"} =
             AnthropicOAuth.resolve_api_key_from_secret("llm_anthropic_api_key", payload)
  end

  test "resolve_api_key_from_secret refreshes near-expiry token and persists updated secret" do
    secret_name = "llm_anthropic_api_key"

    original_payload =
      Jason.encode!(%{
        "type" => "anthropic_oauth",
        "refresh_token" => "refresh-token",
        "access_token" => "stale-token",
        "expires_at_ms" => System.system_time(:millisecond) - 1_000,
        "created_at_ms" => System.system_time(:millisecond),
        "updated_at_ms" => System.system_time(:millisecond)
      })

    assert {:ok, _} = Secrets.set(secret_name, original_payload)

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/oauth/token"

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

    assert {:ok, "fresh-token"} =
             AnthropicOAuth.resolve_api_key_from_secret(secret_name, original_payload)

    assert {:ok, refreshed_payload} = Secrets.get(secret_name)
    assert {:ok, decoded} = Jason.decode(refreshed_payload)
    assert decoded["access_token"] == "fresh-token"
    assert decoded["refresh_token"] == "fresh-refresh-token"
    assert is_integer(decoded["updated_at_ms"])
  end

  test "login_device_flow exchanges pasted code and returns oauth secret" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/oauth/token"

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
             AnthropicOAuth.login_device_flow(
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

    assert secret["type"] == "anthropic_oauth"
    assert secret["access_token"] == "fresh-login-token"
    assert secret["refresh_token"] == "fresh-refresh-token"
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
