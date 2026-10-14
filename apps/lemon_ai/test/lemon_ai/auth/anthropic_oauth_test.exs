defmodule LemonAi.Auth.AnthropicOAuthTest do
  # Swaps Req's global default plug and process environment.
  use ExUnit.Case, async: false

  alias LemonAi.Auth.AnthropicOAuth

  @client_id "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  @code_page "https://platform.claude.com/oauth/code/callback"

  defmodule BusyListener do
    def local_redirect_uri?(_uri), do: true
    def start(_uri), do: {:error, :eaddrinuse}
    def wait(_listener, _timeout), do: flunk_wait()
    def stop(_listener), do: :ok
    defp flunk_wait, do: raise("listener must not be waited on")
  end

  setup do
    previous_defaults = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})

    tmp_dir =
      Path.join(System.tmp_dir!(), "anthropic_oauth_test_#{System.unique_integer([:positive])}")

    home_dir = Path.join(tmp_dir, "home")
    File.mkdir_p!(home_dir)

    previous_env =
      Map.new(~w(HOME PATH ANTHROPIC_TOKEN CLAUDE_CODE_OAUTH_TOKEN), &{&1, System.get_env(&1)})

    System.put_env("HOME", home_dir)
    System.delete_env("ANTHROPIC_TOKEN")
    System.delete_env("CLAUDE_CODE_OAUTH_TOKEN")

    on_exit(fn ->
      Req.default_options(previous_defaults)
      Req.Test.set_req_test_to_private(%{})

      Enum.each(previous_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      File.rm_rf!(tmp_dir)
    end)

    {:ok, home: home_dir}
  end

  describe "authorization request" do
    test "builds a PKCE S256 authorize URL for the Claude subscription client" do
      assert {:ok, auth} = AnthropicOAuth.build_authorize_url(state: "state-123")

      uri = URI.parse(auth.authorize_url)
      assert {uri.scheme, uri.host, uri.path} == {"https", "claude.ai", "/oauth/authorize"}
      params = URI.decode_query(uri.query)

      assert params["code"] == "true"
      assert params["client_id"] == @client_id
      assert params["response_type"] == "code"
      assert params["redirect_uri"] == @code_page
      assert params["state"] == "state-123"
      assert params["code_challenge_method"] == "S256"

      assert params["scope"] ==
               "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

      expected_challenge =
        :crypto.hash(:sha256, auth.code_verifier) |> Base.url_encode64(padding: false)

      assert params["code_challenge"] == expected_challenge
      assert byte_size(auth.code_verifier) >= 43
      assert auth.redirect_uri == @code_page
    end

    test "generates a fresh verifier and a 32-byte state per request" do
      {:ok, first} = AnthropicOAuth.build_authorize_url()
      {:ok, second} = AnthropicOAuth.build_authorize_url()

      # claude.ai rejects a 22-character state with "Invalid request format".
      assert byte_size(first.state) == 43
      refute first.code_verifier == second.code_verifier
      refute first.state == second.state
      refute first.state == first.code_verifier
    end

    test "parses pasted codes, code#state and redirect URLs" do
      assert {:ok, %{code: "abc", state: "xyz"}} =
               AnthropicOAuth.parse_authorization_input(" abc#xyz ")

      assert {:ok, %{code: "abc", state: "xyz"}} =
               AnthropicOAuth.parse_authorization_input(
                 "http://localhost:53692/callback?code=abc&state=xyz"
               )

      assert {:ok, %{code: "abc", state: nil}} = AnthropicOAuth.parse_authorization_input("abc")

      assert {:error, :missing_authorization_code} =
               AnthropicOAuth.parse_authorization_input("  ")
    end
  end

  describe "token exchange" do
    test "posts the PKCE exchange as JSON and records account identity" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:token_request, conn.host, conn.request_path, Jason.decode!(body)})

        Req.Test.json(conn, %{
          "access_token" => "sk-ant-oat01-access",
          "refresh_token" => "sk-ant-ort01-refresh",
          "expires_in" => 28_800,
          "scope" => "user:inference user:profile",
          "account" => %{"uuid" => "acct-1", "email_address" => "user@example.com"},
          "organization" => %{"uuid" => "org-1", "name" => "Personal"}
        })
      end)

      before = System.system_time(:millisecond)

      assert {:ok, secret} =
               AnthropicOAuth.exchange_code_for_secret("auth-code", "verifier-1",
                 redirect_uri: "http://localhost:53692/callback",
                 state: "state-1"
               )

      assert_receive {:token_request, "platform.claude.com", "/v1/oauth/token", body}

      assert body == %{
               "grant_type" => "authorization_code",
               "client_id" => @client_id,
               "code" => "auth-code",
               "state" => "state-1",
               "redirect_uri" => "http://localhost:53692/callback",
               "code_verifier" => "verifier-1"
             }

      assert secret["type"] == "anthropic_oauth"
      assert secret["source"] == "lemon_oauth"
      assert secret["access_token"] == "sk-ant-oat01-access"
      assert secret["refresh_token"] == "sk-ant-ort01-refresh"
      assert secret["expires_at_ms"] >= before + 28_800_000
      assert secret["account_email"] == "user@example.com"
      assert secret["organization_name"] == "Personal"

      assert %{kind: :refreshable, account_email: "user@example.com", reauth_by_ms: reauth_by} =
               AnthropicOAuth.describe_secret(secret)

      assert reauth_by == secret["created_at_ms"] + 30 * 24 * 60 * 60 * 1000
    end

    test "rejects token responses without an access token or expiry" do
      for body <- [%{"expires_in" => 3600}, %{"access_token" => "sk-ant-oat01-x"}] do
        Req.Test.stub(__MODULE__, &Req.Test.json(&1, body))
        assert {:error, _} = AnthropicOAuth.exchange_code_for_secret("code", "verifier")
      end
    end

    test "maps a rejected code to a bounded error without the response body" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, ~s({"error":"invalid_grant","error_description":"bad"}))
      end)

      assert {:error, :authorization_code_rejected} =
               AnthropicOAuth.exchange_code_for_secret("code", "verifier")
    end
  end

  describe "login_device_flow" do
    setup do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(:anthropic_oauth_test, {:exchange, Jason.decode!(body)})

        Req.Test.json(conn, %{
          "access_token" => "sk-ant-oat01-login",
          "refresh_token" => "sk-ant-ort01-login",
          "expires_in" => 28_800
        })
      end)

      Process.register(self(), :anthropic_oauth_test)
      :ok
    end

    test "uses the copy-code page without a listener and exchanges code#state" do
      assert {:ok, secret} =
               AnthropicOAuth.login_device_flow(
                 on_auth: fn url, _instructions -> send(self(), {:auth_url, url}) end,
                 on_prompt: fn %{message: message} ->
                   assert message =~ "code#state"
                   assert_received {:auth_url, url}
                   params = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
                   assert params["redirect_uri"] == @code_page
                   "pasted-code#" <> params["state"]
                 end
               )

      assert_receive {:exchange, body}
      assert body["code"] == "pasted-code"
      assert body["redirect_uri"] == @code_page
      assert secret["access_token"] == "sk-ant-oat01-login"
    end

    test "falls back to the copy-code page when the loopback port is busy" do
      assert {:ok, _secret} =
               AnthropicOAuth.login_device_flow(
                 local_callback_listener: BusyListener,
                 on_progress: fn message -> send(self(), {:progress, message}) end,
                 on_auth: fn url, _ -> send(self(), {:auth_url, url}) end,
                 on_prompt: fn _ ->
                   assert_received {:auth_url, url}
                   params = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
                   assert params["redirect_uri"] == @code_page
                   "code#" <> params["state"]
                 end
               )

      assert_received {:progress, message}
      assert message =~ "port already in use"
    end

    test "captures the loopback redirect automatically" do
      redirect_uri = "http://localhost:#{reserve_local_port()}/callback"

      assert {:ok, secret} =
               AnthropicOAuth.login_device_flow(
                 redirect_uri: redirect_uri,
                 callback_timeout_ms: 2_000,
                 local_callback_listener: LemonCore.OAuth.LocalCallbackListener,
                 on_auth: fn url, _ ->
                   state = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
                   deliver("#{redirect_uri}?code=loopback-code&state=#{state["state"]}")
                 end,
                 on_prompt: fn _ -> flunk("loopback capture must not prompt") end
               )

      assert_receive {:exchange, body}
      assert body["code"] == "loopback-code"
      assert body["redirect_uri"] == redirect_uri
      assert secret["refresh_token"] == "sk-ant-ort01-login"
    end

    test "rejects a pasted code whose state does not match" do
      assert {:error, :oauth_state_mismatch} =
               AnthropicOAuth.login_device_flow(
                 on_auth: fn _, _ -> :ok end,
                 on_prompt: fn _ -> "code#forged-state" end
               )

      refute_received {:exchange, _}
    end

    test "accepts a claude setup-token as a static credential without HTTP" do
      assert {:ok, secret} =
               AnthropicOAuth.login_device_flow(
                 on_auth: fn _, _ -> :ok end,
                 on_prompt: fn _ -> "sk-ant-oat01-setup-token" end
               )

      refute_received {:exchange, _}
      assert secret["access_token"] == "sk-ant-oat01-setup-token"
      assert secret["source"] == "setup_token"
      assert secret["refresh_token"] == nil
      assert %{kind: :static_token, reauth_by_ms: nil} = AnthropicOAuth.describe_secret(secret)
    end

    test "an empty answer cancels sign-in" do
      assert {:error, :login_cancelled} =
               AnthropicOAuth.login_device_flow(
                 on_auth: fn _, _ -> :ok end,
                 on_prompt: fn _ -> "" end
               )
    end
  end

  describe "resolve_api_key_from_secret" do
    test "returns a fresh token without contacting the token endpoint" do
      Req.Test.stub(__MODULE__, fn _ -> flunk("fresh token must not refresh") end)
      secret = encoded_secret(expires_in_ms: 3_600_000)

      assert {:ok, "sk-ant-oat01-old"} =
               AnthropicOAuth.resolve_api_key_from_secret("llm_anthropic_api_key", secret)
    end

    test "refreshes within five minutes of expiry, keeps the rotation and persists it" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:refresh, conn.request_path, Jason.decode!(body)})

        Req.Test.json(conn, %{
          "access_token" => "sk-ant-oat01-new",
          "refresh_token" => "sk-ant-ort01-new",
          "expires_in" => 28_800
        })
      end)

      secret = encoded_secret(expires_in_ms: 4 * 60_000, account_email: "user@example.com")
      revision = make_ref()

      assert {:ok, "sk-ant-oat01-new"} =
               AnthropicOAuth.resolve_api_key_from_secret("llm_anthropic_api_key", secret,
                 reload_secret: fn _ -> {:ok, secret, revision} end,
                 persist_secret: fn name, value, expected ->
                   assert expected == revision
                   send(test_pid, {:persist, name, value})
                   :ok
                 end
               )

      assert_received {:refresh, "/v1/oauth/token", body}

      assert body == %{
               "grant_type" => "refresh_token",
               "refresh_token" => "sk-ant-ort01-old",
               "client_id" => @client_id
             }

      assert_received {:persist, "llm_anthropic_api_key", stored}
      stored = Jason.decode!(stored)
      assert stored["refresh_token"] == "sk-ant-ort01-new"
      assert stored["account_email"] == "user@example.com"
      assert stored["created_at_ms"] == 1_000
    end

    test "keeps the previous refresh token when the response omits one" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{"access_token" => "sk-ant-oat01-new", "expires_in" => 3600})
      end)

      test_pid = self()
      secret = encoded_secret(expires_in_ms: -1)
      revision = make_ref()

      assert {:ok, "sk-ant-oat01-new"} =
               AnthropicOAuth.resolve_api_key_from_secret(
                 "s",
                 secret,
                 reload_secret: fn _ -> {:ok, secret, revision} end,
                 persist_secret: fn _, value, expected ->
                   assert expected == revision
                   send(test_pid, {:persist, value})
                   :ok
                 end
               )

      assert_received {:persist, stored}
      assert Jason.decode!(stored)["refresh_token"] == "sk-ant-ort01-old"
    end

    test "a rejected refresh fails closed even while the access token is valid" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, ~s({"error":"invalid_grant"}))
      end)

      secret = encoded_secret(expires_in_ms: 60_000)

      assert {:error, :reauth_required} =
               AnthropicOAuth.resolve_api_key_from_secret(
                 "s",
                 secret,
                 reload_secret: fn _ -> {:ok, secret, :test_revision} end,
                 persist_secret: fn _, _, _ -> flunk("nothing to persist") end
               )
    end

    test "a transient refresh failure uses only an unexpired access token" do
      Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 503, "unavailable"))

      assert {:ok, "sk-ant-oat01-old"} =
               AnthropicOAuth.resolve_api_key_from_secret(
                 "s",
                 encoded_secret(expires_in_ms: 60_000)
               )

      assert {:error, {:http_error, 503}} =
               AnthropicOAuth.resolve_api_key_from_secret("s", encoded_secret(expires_in_ms: -1))
    end

    test "an expired static token is not used" do
      secret =
        Jason.encode!(%{
          "type" => "anthropic_oauth",
          "access_token" => "sk-ant-oat01-static",
          "expires_at_ms" => System.system_time(:millisecond) - 1
        })

      assert {:error, :expired_access_token} =
               AnthropicOAuth.resolve_api_key_from_secret("s", secret)
    end

    test "concurrent resolvers share one refresh and reuse the stored rotation" do
      test_pid = self()

      store =
        start_supervised!(
          {Agent,
           fn -> %{secret: encoded_secret(expires_in_ms: 60_000), revision: make_ref()} end}
        )

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:refresh_request, self()})

        receive do
          :continue_refresh -> :ok
        after
          5_000 -> flunk("refresh barrier timed out")
        end

        Req.Test.json(conn, %{
          "access_token" => "sk-ant-oat01-new",
          "refresh_token" => "sk-ant-ort01-new",
          "expires_in" => 28_800
        })
      end)

      opts = [
        persist_secret: fn _name, value, expected ->
          Agent.get_and_update(store, fn current ->
            if current.revision == expected,
              do: {:ok, %{secret: value, revision: make_ref()}},
              else: {{:error, :stale_revision}, current}
          end)
        end,
        reload_secret: fn _name -> Agent.get(store, &{:ok, &1.secret, &1.revision}) end
      ]

      stale = Agent.get(store, & &1.secret)

      tasks =
        Enum.map(1..8, fn _ ->
          Task.async(fn -> AnthropicOAuth.resolve_api_key_from_secret("shared", stale, opts) end)
        end)

      assert_receive {:refresh_request, refresher}, 5_000
      send(refresher, :continue_refresh)
      results = Task.await_many(tasks, 5_000)

      assert Enum.uniq(results) == [{:ok, "sk-ant-oat01-new"}]
      refute_received {:refresh_request, _}
      assert Jason.decode!(Agent.get(store, & &1.secret))["refresh_token"] == "sk-ant-ort01-new"
    end

    test "a waiter fails closed when the login was deleted meanwhile" do
      Req.Test.stub(__MODULE__, fn _ -> flunk("deleted login must not refresh") end)

      assert {:error, :oauth_secret_missing} =
               AnthropicOAuth.resolve_api_key_from_secret("s", encoded_secret(expires_in_ms: -1),
                 reload_secret: fn _ -> {:error, :not_found} end
               )
    end

    test "ignores values that are not Anthropic OAuth payloads" do
      assert :ignore = AnthropicOAuth.resolve_api_key_from_secret("s", "sk-ant-api03-raw")
    end
  end

  describe "ambient Claude Code credentials" do
    test "reads ~/.claude/.credentials.json", %{home: home} do
      write_claude_credentials(home, "sk-ant-oat01-file-token", 3_600_000)
      assert AnthropicOAuth.resolve_access_token() == "sk-ant-oat01-file-token"
    end

    test "prefers refreshable Claude Code credentials over a static env token", %{home: home} do
      write_claude_credentials(home, "sk-ant-oat01-refreshable-token", 3_600_000)
      System.put_env("ANTHROPIC_TOKEN", "sk-ant-oat01-static-token")

      assert AnthropicOAuth.resolve_access_token() == "sk-ant-oat01-refreshable-token"
    end

    test "refreshes and writes back the Claude Code credentials file", %{home: home} do
      path = write_claude_credentials(home, "sk-ant-oat01-stale", -1)

      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "access_token" => "sk-ant-oat01-rotated",
          "refresh_token" => "rotated-refresh",
          "expires_in" => 3600
        })
      end)

      assert AnthropicOAuth.resolve_access_token() == "sk-ant-oat01-rotated"
      stored = path |> File.read!() |> Jason.decode!()
      assert stored["claudeAiOauth"]["refreshToken"] == "rotated-refresh"
      assert stored["claudeAiOauth"]["scopes"] == ["user:inference"]
    end
  end

  describe "request fingerprint" do
    test "uses the newer of the installed Claude Code version and the pinned floor", %{
      home: home
    } do
      bin_dir = Path.join(home, "bin-#{System.unique_integer([:positive])}")
      File.mkdir_p!(bin_dir)
      script = Path.join(bin_dir, "claude-code")
      File.write!(script, "#!/bin/sh\necho \"9.9.9 (Claude Code)\"\n")
      File.chmod!(script, 0o755)
      System.put_env("PATH", bin_dir)

      headers = Map.new(AnthropicOAuth.oauth_headers())
      assert headers["user-agent"] == "claude-cli/9.9.9 (external, cli)"
      assert headers["x-app"] == "cli"

      File.write!(script, "#!/bin/sh\necho \"1.0.0 (Claude Code)\"\n")
      System.put_env("PATH", bin_dir <> ":")
      assert {"user-agent", "claude-cli/2.1." <> _} = hd(AnthropicOAuth.oauth_headers())
    end
  end

  defp encoded_secret(opts) do
    now = System.system_time(:millisecond)

    %{
      "type" => "anthropic_oauth",
      "source" => "lemon_oauth",
      "access_token" => "sk-ant-oat01-old",
      "refresh_token" => "sk-ant-ort01-old",
      "expires_at_ms" => now + Keyword.fetch!(opts, :expires_in_ms),
      "created_at_ms" => 1_000,
      "updated_at_ms" => 1_000
    }
    |> then(fn secret ->
      case opts[:account_email] do
        nil -> secret
        email -> Map.put(secret, "account_email", email)
      end
    end)
    |> Jason.encode!()
  end

  defp write_claude_credentials(home, access_token, expires_in_ms) do
    path = Path.join([home, ".claude", ".credentials.json"])
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{
        "claudeAiOauth" => %{
          "accessToken" => access_token,
          "refreshToken" => "refresh-token",
          "expiresAt" => System.system_time(:millisecond) + expires_in_ms,
          "scopes" => ["user:inference"]
        }
      })
    )

    path
  end

  defp reserve_local_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_ip, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    port
  end

  defp deliver(url) do
    assert {:ok, _response} = :httpc.request(:get, {String.to_charlist(url), []}, [], [])
  end
end
