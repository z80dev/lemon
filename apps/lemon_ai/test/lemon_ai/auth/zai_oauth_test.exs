defmodule LemonAi.Auth.ZaiOAuthTest do
  use ExUnit.Case, async: true

  alias LemonAi.Auth.ZaiOAuth

  @keys_path "/api/biz/v1/organization/org-1/projects/proj-2/api_keys"

  setup do
    {:ok, opts: [req_options: [plug: {Req.Test, __MODULE__}], state: "state-123"]}
  end

  defp json(conn, body), do: Req.Test.json(conn, body)

  defp stub(existing_keys) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = if raw == "", do: %{}, else: Jason.decode!(raw)
      auth = Plug.Conn.get_req_header(conn, "authorization")
      send(test_pid, {:request, conn.method, conn.host, conn.request_path, body, auth})

      case {conn.method, conn.host, conn.request_path} do
        {"POST", "zcode.z.ai", "/api/v1/oauth/token"} ->
          json(conn, %{
            "code" => 0,
            "data" => %{"zai" => %{"access_token" => "oauth-at"}, "user" => %{"id" => "u1"}}
          })

        {"POST", "api.z.ai", "/api/auth/z/login"} ->
          json(conn, %{
            "code" => 200,
            "success" => true,
            "data" => %{"access_token" => "biz-token"}
          })

        {"GET", "api.z.ai", "/api/biz/customer/getCustomerInfo"} ->
          json(conn, %{
            "code" => 200,
            "data" => %{
              "organizations" => [
                %{"organizationId" => "org-0", "projects" => []},
                %{
                  "organizationId" => "org-1",
                  "isDefault" => true,
                  "projects" => [
                    %{"projectId" => "proj-1"},
                    %{"projectId" => "proj-2", "isDefault" => true}
                  ]
                }
              ]
            }
          })

        {"GET", "api.z.ai", @keys_path} ->
          json(conn, %{"code" => 200, "data" => %{"list" => existing_keys}})

        {"POST", "api.z.ai", @keys_path} ->
          json(conn, %{"code" => 200, "data" => %{"apiKey" => "new-id", "name" => "lemon"}})

        {"GET", "api.z.ai", @keys_path <> "/copy/" <> api_key} ->
          json(conn, %{"code" => 200, "data" => %{"secretKey" => "secret-for-#{api_key}"}})
      end
    end)
  end

  test "pasted redirect -> token exchange -> business login -> created key", %{opts: opts} do
    stub([%{"name" => "someone-else", "apiKey" => "other"}])

    opts =
      Keyword.merge(opts,
        on_auth: fn _, _ -> :ok end,
        on_prompt: fn _ -> "zcode://zai-auth/callback?code=the-code&state=state-123" end
      )

    assert {:ok, "new-id.secret-for-new-id"} = ZaiOAuth.login_device_flow(opts)

    assert_received {:request, "POST", "zcode.z.ai", "/api/v1/oauth/token", token_body, _}

    assert token_body == %{
             "provider" => "zai",
             "code" => "the-code",
             "redirect_uri" => "zcode://zai-auth/callback",
             "state" => "state-123"
           }

    assert_received {:request, "POST", "api.z.ai", "/api/auth/z/login", %{"token" => "oauth-at"},
                     []}

    assert_received {:request, "GET", "api.z.ai", "/api/biz/customer/getCustomerInfo", _,
                     ["Bearer biz-token"]}

    assert_received {:request, "POST", "api.z.ai", @keys_path, %{"name" => "lemon"}, _}
  end

  test "reuses an existing lemon key", %{opts: opts} do
    stub([%{"name" => "lemon", "apiKey" => "existing-id"}])

    assert {:ok, "existing-id.secret-for-existing-id"} = ZaiOAuth.mint_api_key("oauth-at", opts)
    refute_received {:request, "POST", "api.z.ai", @keys_path, _, _}
  end

  test "rejects a pasted redirect for another sign-in", %{opts: opts} do
    stub([])

    opts =
      Keyword.merge(opts,
        on_auth: fn _, _ -> :ok end,
        on_prompt: fn _ -> "the-code#other-state" end
      )

    assert {:error, :oauth_state_mismatch} = ZaiOAuth.login_device_flow(opts)
    refute_received {:request, _, _, _, _, _}
  end

  test "an error envelope fails without leaking the body", %{opts: opts} do
    Req.Test.stub(__MODULE__, fn conn ->
      json(conn, %{"code" => 1001, "msg" => "invalid code", "success" => false})
    end)

    assert {:error, {:zai_request_failed, :token_exchange, 1001}} =
             ZaiOAuth.exchange_code("c", "s", "zcode://zai-auth/callback", opts)
  end

  test "missing callback state is rejected even for a bare code", %{opts: opts} do
    Req.Test.stub(__MODULE__, fn _ -> flunk("must not exchange without returned state") end)

    for input <- ["the-code", "zcode://zai-auth/callback?code=the-code", "code=the-code"] do
      assert {:error, :oauth_state_mismatch} =
               ZaiOAuth.login_device_flow(
                 Keyword.merge(opts, on_auth: fn _, _ -> :ok end, on_prompt: fn _ -> input end)
               )
    end
  end

  test "a matching state does not authorize a different redirect endpoint", %{opts: opts} do
    Req.Test.stub(__MODULE__, fn _ -> flunk("must not exchange unbound callback") end)

    for input <- [
          "zcode://attacker/callback?code=c&state=state-123",
          "zcode://zai-auth/other?code=c&state=state-123",
          "https://zai-auth/callback?code=c&state=state-123"
        ] do
      assert {:error, :oauth_redirect_mismatch} =
               ZaiOAuth.login_device_flow(
                 Keyword.merge(opts, on_auth: fn _, _ -> :ok end, on_prompt: fn _ -> input end)
               )
    end
  end

  test "code and returned state remain supported without a full redirect URL", %{opts: opts} do
    stub([%{"name" => "lemon", "apiKey" => "existing-id"}])

    assert {:ok, "existing-id.secret-for-existing-id"} =
             ZaiOAuth.login_device_flow(
               Keyword.merge(opts,
                 on_auth: fn _, _ -> :ok end,
                 on_prompt: fn _ -> "the-code#state-123" end
               )
             )
  end

  test "untrusted envelope codes never enter error terms", %{opts: opts} do
    for code <- ["secret-access-token", %{"code" => "secret-code"}, ["secret-user"]] do
      Req.Test.stub(__MODULE__, fn conn ->
        json(conn, %{"code" => code, "msg" => "secret-response", "success" => false})
      end)

      assert {:error, {:zai_request_failed, :token_exchange, :provider_error}} =
               ZaiOAuth.exchange_code("c", "s", "zcode://zai-auth/callback", opts)
    end
  end

  test "malformed successful token data returns a credential-free error", %{opts: opts} do
    for data <- ["secret-response", %{"zai" => "secret-token"}, %{"zai" => ["secret"]}] do
      Req.Test.stub(__MODULE__, fn conn -> json(conn, %{"code" => 0, "data" => data}) end)

      assert {:error, :missing_access_token} =
               ZaiOAuth.exchange_code("c", "s", "zcode://zai-auth/callback", opts)
    end
  end

  test "organization and project identifiers stay in a single URL segment", %{opts: opts} do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/api/auth/z/login" ->
          json(conn, %{"data" => %{"access_token" => "biz-token"}})

        "/api/biz/customer/getCustomerInfo" ->
          json(conn, %{
            "data" => %{
              "organizations" => [
                %{
                  "organizationId" => "org/other",
                  "projects" => [%{"projectId" => "project?query"}]
                }
              ]
            }
          })

        "/api/biz/v1/organization/org%2Fother/projects/project%3Fquery/api_keys" ->
          json(conn, %{"data" => [%{"name" => "lemon", "apiKey" => "id"}]})

        "/api/biz/v1/organization/org%2Fother/projects/project%3Fquery/api_keys/copy/id" ->
          json(conn, %{"data" => %{"secretKey" => "secret"}})
      end
    end)

    assert {:ok, "id.secret"} = ZaiOAuth.mint_api_key("oauth-token", opts)
  end

  test "malformed pasted URLs fail without echoing input" do
    assert {:error, :invalid_authorization_input} =
             ZaiOAuth.parse_authorization_input("zcode://zai-auth:secret/callback?code=secret")
  end

  test "rejects malformed callback authorities before exchanging a code", %{opts: opts} do
    Req.Test.stub(__MODULE__, fn _ -> flunk("must not exchange malformed callback") end)

    for authority <- ["zai-auth:secret", "zai-auth:443junk", "zai-auth:", "zai-auth:65536"] do
      input = "zcode://#{authority}/callback?code=secret&state=state-123"

      assert {:error, :invalid_authorization_input} =
               ZaiOAuth.parse_authorization_input(input)

      assert {:error, :invalid_authorization_input} =
               ZaiOAuth.login_device_flow(
                 Keyword.merge(opts, on_auth: fn _, _ -> :ok end, on_prompt: fn _ -> input end)
               )
    end
  end

  test "valid URI authorities and non-URL code/state inputs remain supported" do
    for input <- [
          "zcode://zai-auth/callback?code=the-code&state=state-123",
          "zcode://zai-auth:443/callback?code=the-code&state=state-123",
          "zcode://zai-auth:0443/callback?code=the-code&state=state-123",
          "code=the-code&state=state-123",
          "the-code#state-123"
        ] do
      assert {:ok, %{code: "the-code", state: "state-123"}} =
               ZaiOAuth.parse_authorization_input(input)
    end

    assert {:ok, %{code: "the-code", state: nil}} = ZaiOAuth.parse_authorization_input("the-code")
  end
end
