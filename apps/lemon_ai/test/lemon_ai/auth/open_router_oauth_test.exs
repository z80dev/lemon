defmodule LemonAi.Auth.OpenRouterOAuthTest do
  use ExUnit.Case, async: true

  alias LemonAi.Auth.{OAuthSecretResolver, OpenRouterOAuth}

  defmodule FakeListener do
    def local_redirect_uri?(uri), do: String.starts_with?(uri, "http://localhost:")
    def start(uri), do: {:ok, %{uri: uri, owner: self()}}

    def wait(%{owner: owner}, _timeout) do
      send(owner, :listener_waited)

      case Process.get(:fake_callback) do
        nil -> {:error, :timeout}
        url -> {:ok, url}
      end
    end

    def stop(%{owner: owner}), do: send(owner, :listener_stopped)
  end

  setup do
    {:ok, opts: [req_options: [plug: {Req.Test, __MODULE__}]]}
  end

  defp stub_keys(test_pid) do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn.method, conn.request_path, raw, conn.req_headers})

      case conn.request_path do
        "/api/v1/auth/keys" ->
          Req.Test.json(conn, %{"key" => "sk-or-v1-minted", "user_id" => "u"})

        "/api/v1/auth/key" ->
          if {"authorization", "Bearer sk-or-v1-good"} in conn.req_headers,
            do: Req.Test.json(conn, %{"data" => %{"label" => "k"}}),
            else: conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "bad"})
      end
    end)
  end

  test "captures the loopback callback and exchanges the code with its verifier", %{opts: opts} do
    test_pid = self()
    stub_keys(test_pid)
    Process.put(:fake_callback, "http://localhost:54549/callback?code=auth-code-1")

    opts =
      Keyword.merge(opts,
        local_callback_listener: FakeListener,
        on_auth: fn url, _ -> send(test_pid, {:auth, url}) end,
        on_prompt: fn _ -> flunk("must not prompt") end
      )

    assert {:ok, "sk-or-v1-minted"} = OpenRouterOAuth.login_device_flow(opts)
    assert_received {:auth, url}
    assert_received :listener_stopped
    assert_received {:request, "POST", "/api/v1/auth/keys", raw, _}

    body = Jason.decode!(raw)
    assert body["code"] == "auth-code-1"
    assert body["code_challenge_method"] == "S256"

    challenge = URI.decode_query(URI.parse(url).query)["code_challenge"]

    assert challenge ==
             Base.url_encode64(:crypto.hash(:sha256, body["code_verifier"]), padding: false)
  end

  test "falls back to a pasted redirect URL when the callback does not arrive", %{opts: opts} do
    stub_keys(self())

    opts =
      Keyword.merge(opts,
        local_callback_listener: FakeListener,
        on_auth: fn _, _ -> :ok end,
        on_prompt: fn %{message: message} ->
          assert message =~ "redirect URL"
          "http://localhost:54549/callback?code=pasted-code\n"
        end
      )

    assert {:ok, "sk-or-v1-minted"} = OpenRouterOAuth.login_device_flow(opts)
    assert_received :listener_waited
    assert_received {:request, "POST", "/api/v1/auth/keys", raw, _}
    assert Jason.decode!(raw)["code"] == "pasted-code"
  end

  test "a pasted sk-or- key is validated instead of exchanged", %{opts: opts} do
    stub_keys(self())

    login = fn key ->
      OpenRouterOAuth.login_device_flow(
        Keyword.merge(opts, on_auth: fn _, _ -> :ok end, on_prompt: fn _ -> key end)
      )
    end

    assert {:ok, "sk-or-v1-good"} = login.("sk-or-v1-good")
    assert {:error, :invalid_api_key} = login.("sk-or-v1-bad")
    refute_received {:request, "POST", "/api/v1/auth/keys", _, _}
  end

  test "the minted key is a plain API key the OAuth resolver ignores" do
    assert :ignore =
             OAuthSecretResolver.resolve_api_key_from_secret(
               "llm_openrouter_api_key",
               "sk-or-v1-minted"
             )
  end

  test "rejects callbacks for a different endpoint before exchanging a code", %{opts: opts} do
    Req.Test.stub(__MODULE__, fn _ -> flunk("must not exchange unbound callback") end)

    for callback <- [
          "http://attacker.test:54549/callback?code=secret",
          "http://localhost:54550/callback?code=secret",
          "http://localhost:54549/other?code=secret",
          "http://user:pass@localhost:54549/callback?code=secret",
          "http://localhost:54549/callback?code=secret#fragment"
        ] do
      assert {:error, :oauth_redirect_mismatch} =
               OpenRouterOAuth.login_device_flow(
                 Keyword.merge(opts, on_auth: fn _, _ -> :ok end, on_prompt: fn _ -> callback end)
               )
    end
  end

  test "binds callback validation to the configured redirect URI", %{opts: opts} do
    stub_keys(self())

    assert {:ok, "sk-or-v1-minted"} =
             OpenRouterOAuth.login_device_flow(
               Keyword.merge(opts,
                 redirect_uri: "http://localhost:54321/custom",
                 on_auth: fn _, _ -> :ok end,
                 on_prompt: fn _ -> "http://localhost:54321/custom?code=custom-code" end
               )
             )
  end

  test "malformed pasted URLs fail without echoing input" do
    assert {:error, :invalid_authorization_input} =
             OpenRouterOAuth.parse_authorization_input(
               "http://localhost:secret/callback?code=secret"
             )
  end

  test "rejects malformed callback authorities before exchanging a code", %{opts: opts} do
    Req.Test.stub(__MODULE__, fn _ -> flunk("must not exchange malformed callback") end)

    for authority <- ["localhost:secret", "localhost:54549junk", "localhost:", "localhost:65536"] do
      input = "http://#{authority}/callback?code=secret"

      assert {:error, :invalid_authorization_input} =
               OpenRouterOAuth.parse_authorization_input(input)

      assert {:error, :invalid_authorization_input} =
               OpenRouterOAuth.login_device_flow(
                 Keyword.merge(opts, on_auth: fn _, _ -> :ok end, on_prompt: fn _ -> input end)
               )
    end
  end

  test "valid URI authorities and non-URL code inputs remain supported" do
    for input <- [
          "http://localhost/callback?code=the-code",
          "http://localhost:54549/callback?code=the-code",
          "http://localhost:054549/callback?code=the-code",
          "http://[::1]:54549/callback?code=the-code",
          "code=the-code",
          "the-code"
        ] do
      assert {:ok, "the-code"} = OpenRouterOAuth.parse_authorization_input(input)
    end
  end
end
