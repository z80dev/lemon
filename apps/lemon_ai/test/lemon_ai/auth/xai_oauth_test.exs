defmodule LemonAi.Auth.XAIOAuthTest do
  use ExUnit.Case, async: true

  alias LemonAi.Auth.{OAuthSecretResolver, XAIOAuth}

  @token_endpoint "https://auth.x.ai/oauth2/token"

  setup do
    {:ok, opts: [req_options: [plug: {Req.Test, __MODULE__}], sleep: fn _ -> :ok end]}
  end

  defp stub(fun) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(raw)
      send(test_pid, {:request, conn.method, conn.request_path, params})
      fun.(conn, conn.request_path, params)
    end)
  end

  defp jwt(claims) do
    payload = claims |> Jason.encode!() |> Base.url_encode64(padding: false)
    "eyJhbGciOiJub25lIn0.#{payload}.sig"
  end

  defp json(conn, status \\ 200, body),
    do: conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)

  describe "login_device_flow/1" do
    test "discovers the token endpoint, polls through pending and slow_down, stores a payload",
         %{opts: opts} do
      {:ok, polls} = Agent.start_link(fn -> [:pending, :slow_down] end)
      access_token = jwt(%{"sub" => "user-123"})
      test_pid = self()

      stub(fn conn, path, params ->
        case path do
          "/.well-known/openid-configuration" ->
            json(conn, %{"token_endpoint" => @token_endpoint})

          "/oauth2/device/code" ->
            assert params["client_id"] == "b1a00492-073a-47ea-816f-4c329264a828"
            assert params["scope"] =~ "grok-cli:access"

            json(conn, %{
              "device_code" => "dev-code",
              "user_code" => "ABCD-1234",
              "verification_uri" => "https://accounts.x.ai/device",
              "verification_uri_complete" => "https://accounts.x.ai/device?code=ABCD-1234",
              "interval" => 2,
              "expires_in" => 600
            })

          "/oauth2/token" ->
            assert params["grant_type"] == "urn:ietf:params:oauth:grant-type:device_code"
            assert params["device_code"] == "dev-code"

            case Agent.get_and_update(polls, fn
                   [next | rest] -> {next, rest}
                   [] -> {:done, []}
                 end) do
              :pending ->
                json(conn, 400, %{"error" => "authorization_pending"})

              :slow_down ->
                json(conn, 400, %{"error" => "slow_down"})

              :done ->
                json(conn, %{
                  "access_token" => access_token,
                  "refresh_token" => "rt-1",
                  "expires_in" => 3600
                })
            end

          "/oauth2/userinfo" ->
            assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{access_token}"]
            json(conn, %{"sub" => "user-123", "email" => "Grok@Example.com"})
        end
      end)

      opts =
        Keyword.merge(opts,
          on_auth: fn url, instructions -> send(test_pid, {:auth, url, instructions}) end,
          sleep: fn ms -> send(test_pid, {:slept, ms}) end
        )

      assert {:ok, secret} = XAIOAuth.login_device_flow(opts)

      assert_received {:auth, "https://accounts.x.ai/device?code=ABCD-1234",
                       "Enter code: ABCD-1234"}

      assert_received {:slept, 2000}
      # slow_down adds five seconds to the interval.
      assert_received {:slept, 7000}

      assert %{
               "type" => "xai_oauth",
               "access_token" => ^access_token,
               "refresh_token" => "rt-1",
               "token_endpoint" => @token_endpoint,
               "account_id" => "user-123",
               "account_email" => "grok@example.com"
             } = secret

      assert secret["expires_at_ms"] > System.system_time(:millisecond) + 3_500_000
    end

    test "rejects a discovered token endpoint outside x.ai", %{opts: opts} do
      stub(fn conn, "/.well-known/openid-configuration", _ ->
        json(conn, %{"token_endpoint" => "https://evil.example/token"})
      end)

      assert {:error, :invalid_xai_endpoint} =
               XAIOAuth.login_device_flow(Keyword.put(opts, :on_auth, fn _, _ -> :ok end))

      refute_received {:request, _, "/oauth2/device/code", _}
    end

    test "stops on expired_token and access_denied", %{opts: opts} do
      for {error, reason} <- [
            {"expired_token", :device_code_expired},
            {"access_denied", :access_denied}
          ] do
        stub(fn conn, path, _ ->
          case path do
            "/oauth2/device/code" ->
              json(conn, %{
                "device_code" => "d",
                "user_code" => "U",
                "verification_uri" => "https://x.ai/d"
              })

            "/oauth2/token" ->
              json(conn, 400, %{"error" => error})
          end
        end)

        opts =
          Keyword.merge(opts,
            token_url: "https://auth.x.ai/oauth2/token",
            on_auth: fn _, _ -> :ok end
          )

        assert {:error, ^reason} = XAIOAuth.login_device_flow(opts)
      end
    end
  end

  describe "resolve_api_key_from_secret/3" do
    test "returns an unexpired token without a request", %{opts: opts} do
      stub(fn _, _, _ -> flunk("must not refresh") end)
      secret = payload(expires_in_ms: 60 * 60 * 1000)

      assert {:ok, "old-access"} =
               XAIOAuth.resolve_api_key_from_secret("llm_xai_api_key", secret, opts)
    end

    test "refreshes near expiry at the stored endpoint and persists the rotated token",
         %{opts: opts} do
      test_pid = self()

      stub(fn conn, "/oauth2/token", params ->
        assert params["grant_type"] == "refresh_token"
        assert params["refresh_token"] == "old-refresh"

        json(conn, %{
          "access_token" => "new-access",
          "refresh_token" => "new-refresh",
          "expires_in" => 3600
        })
      end)

      opts =
        Keyword.put(opts, :persist_secret, fn name, value ->
          send(test_pid, {:persisted, name, value})
        end)

      assert {:ok, "new-access"} =
               XAIOAuth.resolve_api_key_from_secret(
                 "llm_xai_api_key",
                 payload(expires_in_ms: 60_000),
                 opts
               )

      assert_received {:persisted, "llm_xai_api_key", stored}

      assert %{"access_token" => "new-access", "refresh_token" => "new-refresh"} =
               Jason.decode!(stored)
    end

    test "force_refresh refreshes an unexpired token and never falls back to it", %{opts: opts} do
      stub(fn conn, "/oauth2/token", _ ->
        json(conn, %{"access_token" => "forced-access", "expires_in" => 3600})
      end)

      secret = payload(expires_in_ms: 60 * 60 * 1000)

      assert {:ok, "forced-access"} =
               OAuthSecretResolver.resolve_api_key_from_secret(
                 "llm_xai_api_key",
                 secret,
                 Keyword.merge(opts, force_refresh: true, persist_secret: fn _, _ -> :ok end)
               )

      stub(fn conn, "/oauth2/token", _ -> json(conn, 503, %{"error" => "unavailable"}) end)

      assert {:error, {:http_error, 503}} =
               XAIOAuth.resolve_api_key_from_secret(
                 "llm_xai_api_key",
                 secret,
                 Keyword.put(opts, :force_refresh, true)
               )
    end

    test "invalid_grant requires a new sign-in; a failed persist fails closed", %{opts: opts} do
      stub(fn conn, "/oauth2/token", _ -> json(conn, 400, %{"error" => "invalid_grant"}) end)
      expiring = payload(expires_in_ms: 60_000)

      assert {:error, :reauth_required} =
               XAIOAuth.resolve_api_key_from_secret("llm_xai_api_key", expiring, opts)

      stub(fn conn, "/oauth2/token", _ ->
        json(conn, %{
          "access_token" => "new-access",
          "refresh_token" => "rotated",
          "expires_in" => 3600
        })
      end)

      assert {:error, :oauth_secret_persistence_failed} =
               XAIOAuth.resolve_api_key_from_secret(
                 "llm_xai_api_key",
                 expiring,
                 Keyword.put(opts, :persist_secret, fn _, _ -> {:error, :disk_full} end)
               )
    end

    test "a queued caller reuses the token another caller stored", %{opts: opts} do
      stub(fn _, _, _ -> flunk("must not refresh") end)
      stale = payload(expires_in_ms: 60_000)

      rotated =
        stale
        |> Jason.decode!()
        |> Map.merge(%{"access_token" => "rotated", "expires_at_ms" => future(3_600_000)})

      assert {:ok, "rotated"} =
               XAIOAuth.resolve_api_key_from_secret(
                 "llm_xai_api_key",
                 stale,
                 Keyword.put(opts, :reload_secret, fn _ -> {:ok, Jason.encode!(rotated)} end)
               )
    end

    test "a tampered stored endpoint is rediscovered before refresh", %{opts: opts} do
      stub(fn conn, path, _ ->
        case path do
          "/.well-known/openid-configuration" ->
            json(conn, %{"token_endpoint" => @token_endpoint})

          "/oauth2/token" ->
            json(conn, %{"access_token" => "new-access", "expires_in" => 3600})
        end
      end)

      secret =
        payload(expires_in_ms: 60_000)
        |> Jason.decode!()
        |> Map.put("token_endpoint", "http://attacker.test/token")
        |> Jason.encode!()

      assert {:ok, "new-access"} =
               XAIOAuth.resolve_api_key_from_secret("llm_xai_api_key", secret, opts)

      assert_received {:request, "GET", "/.well-known/openid-configuration", _}
    end

    test "a trusted refresh endpoint cannot redirect the refresh token off-domain", %{opts: opts} do
      stub(fn conn, "/oauth2/token", params ->
        assert conn.host == "auth.x.ai"
        assert params["refresh_token"] == "old-refresh"

        conn
        |> Plug.Conn.put_resp_header("location", "https://attacker.test/token")
        |> Plug.Conn.send_resp(307, "")
      end)

      assert {:error, {:http_error, 307}} =
               XAIOAuth.resolve_api_key_from_secret(
                 "custom-xai-login",
                 payload(expires_in_ms: -1_000),
                 opts
               )
    end
  end

  test "validate_endpoint pins HTTPS x.ai hosts" do
    assert {:ok, _} = XAIOAuth.validate_endpoint("https://auth.x.ai/oauth2/token")
    assert {:ok, _} = XAIOAuth.validate_endpoint("https://x.ai/token")
    assert {:error, _} = XAIOAuth.validate_endpoint("http://auth.x.ai/token")
    assert {:error, _} = XAIOAuth.validate_endpoint("https://auth.x.ai.evil.test/token")
    assert {:error, _} = XAIOAuth.validate_endpoint(nil)
    assert {:error, _} = XAIOAuth.validate_endpoint("https://user:secret@auth.x.ai/token")
    assert {:error, _} = XAIOAuth.validate_endpoint("https://auth.x.ai:8443/token")
    assert {:error, _} = XAIOAuth.validate_endpoint("https://auth.x.ai/token#secret")
    assert {:error, _} = XAIOAuth.validate_endpoint("https://auth.x.ai:bad/token")
    assert {:error, _} = XAIOAuth.validate_endpoint("https://attacker.test%2F.x.ai/token")
    assert {:error, _} = XAIOAuth.validate_endpoint("https://attacker.test\\foo.x.ai/token")
    assert {:error, _} = XAIOAuth.validate_endpoint("https://bad..x.ai/token")
  end

  test "validate_endpoint accepts explicit HTTPS ports and preserves valid endpoints" do
    for url <- [
          "https://x.ai:443/token",
          "https://AUTH.X.AI:443/oauth2/token",
          "https://auth.x.ai:0443/token",
          "https://login.auth.x.ai/token?audience=https%3A%2F%2Fapi.x.ai"
        ] do
      assert {:ok, ^url} = XAIOAuth.validate_endpoint(url)
    end
  end

  test "validate_endpoint rejects malformed and non-HTTPS authority ports" do
    for port <- ["", "bad", "443junk", "443:443", "+443", "-443", "443 ", "444", "65536"] do
      url = "https://auth.x.ai:#{port}/token"

      assert {:error, :invalid_xai_endpoint} = XAIOAuth.validate_endpoint(url),
             "accepted invalid endpoint: #{inspect(url)}"
    end
  end

  defp payload(expires_in_ms: expires_in_ms) do
    Jason.encode!(%{
      "type" => "xai_oauth",
      "access_token" => "old-access",
      "refresh_token" => "old-refresh",
      "expires_at_ms" => future(expires_in_ms),
      "token_endpoint" => @token_endpoint
    })
  end

  defp future(ms), do: System.system_time(:millisecond) + ms
end
