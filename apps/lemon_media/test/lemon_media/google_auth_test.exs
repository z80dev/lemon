defmodule LemonMedia.GoogleAuthTest do
  use ExUnit.Case, async: false

  alias LemonMedia.GoogleAuth

  setup do
    GoogleAuth.clear()
    on_exit(&GoogleAuth.clear/0)

    key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

    json =
      Jason.encode!(%{
        "client_email" => "media@test.iam.gserviceaccount.com",
        "private_key" => pem,
        "token_uri" => "https://oauth2.test/token"
      })

    {:ok, json: json}
  end

  defp token_post(parent, response) do
    fn url, opts ->
      send(parent, {:token_exchange, url, opts})
      response
    end
  end

  test "a second call reuses the cached service-account token", %{json: json} do
    post =
      token_post(
        self(),
        {:ok, %{status: 200, body: %{"access_token" => "tok-1", "expires_in" => 3600}}}
      )

    runtime = %{service_account_json: json, token_http_post: post}

    assert {:ok, "tok-1"} = GoogleAuth.access_token(runtime, :vertex_imagen)
    assert_received {:token_exchange, "https://oauth2.test/token", opts}
    assert opts[:body] =~ "grant_type=urn"

    assert {:ok, "tok-1"} = GoogleAuth.access_token(runtime, :google_tts)
    refute_received {:token_exchange, _, _}
  end

  test "a token inside the refresh margin is exchanged again", %{json: json} do
    post =
      token_post(
        self(),
        {:ok, %{status: 200, body: %{"access_token" => "short", "expires_in" => 30}}}
      )

    runtime = %{service_account_json: json, token_http_post: post}

    assert {:ok, "short"} = GoogleAuth.access_token(runtime, :vertex_veo)
    assert {:ok, "short"} = GoogleAuth.access_token(runtime, :vertex_veo)
    assert_received {:token_exchange, _, _}
    assert_received {:token_exchange, _, _}
  end

  test "failures are labelled per provider and never cached", %{json: json} do
    post =
      token_post(
        self(),
        {:ok,
         %{
           status: 403,
           body: %{"error" => %{"status" => "PERMISSION_DENIED", "message" => "secret"}}
         }}
      )

    runtime = %{service_account_json: json, token_http_post: post}

    assert {:error,
            {:vertex_imagen_token_http_error, 403, {:safe_error_kind, "PERMISSION_DENIED"}}} =
             GoogleAuth.access_token(runtime, :vertex_imagen)

    assert {:error, _} = GoogleAuth.access_token(runtime, :vertex_imagen)
    assert_received {:token_exchange, _, _}
    assert_received {:token_exchange, _, _}

    assert {:error, :invalid_google_tts_service_account_json} =
             GoogleAuth.access_token(%{service_account_json: "{"}, :google_tts)

    assert {:error, :missing_vertex_veo_credentials} = GoogleAuth.access_token(%{}, :vertex_veo)
    assert {:ok, "explicit"} = GoogleAuth.access_token(%{access_token: "explicit"}, :vertex_veo)
  end
end
