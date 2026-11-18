defmodule LemonAi.Auth.OAuthStateBindingTest do
  # Drives each authorization-code login through the real loopback listener and
  # the paste prompt; swaps Req's global default plug and process environment.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LemonAi.Auth.{
    AnthropicOAuth,
    GoogleAntigravityOAuth,
    GoogleGeminiCliOAuth,
    OpenAICodexOAuth
  }

  alias LemonCore.OAuth.LocalCallbackListener

  @providers [
    {AnthropicOAuth, "/callback"},
    {OpenAICodexOAuth, "/auth/callback"},
    {GoogleGeminiCliOAuth, "/oauth2callback"},
    {GoogleAntigravityOAuth, "/oauth-callback"}
  ]

  @code "attacker-code-123"

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_ai)
    :inets.start()

    previous_defaults = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})

    env = ~w(GOOGLE_ANTIGRAVITY_OAUTH_CLIENT_ID GOOGLE_ANTIGRAVITY_OAUTH_CLIENT_SECRET)
    previous_env = Map.new(env, &{&1, System.get_env(&1)})
    Enum.each(env, &System.put_env(&1, "test-#{&1}"))

    on_exit(fn ->
      Req.default_options(previous_defaults)
      Req.Test.set_req_test_to_private(%{})

      Enum.each(previous_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    test_pid = self()
    Req.Test.stub(__MODULE__, &token_endpoint(&1, test_pid))
    :ok
  end

  for {provider, path} <- @providers do
    describe "#{inspect(provider)} loopback listener" do
      test "ignores stateless, forged and whitespace-padded callbacks and completes with the real one" do
        redirect_uri = "http://localhost:#{reserve_local_port()}#{unquote(path)}"

        assert {:ok, _secret} =
                 unquote(provider).login_device_flow(
                   listener_opts(redirect_uri, fn state ->
                     [
                       "#{redirect_uri}?code=#{@code}",
                       "#{redirect_uri}?code=#{@code}&state=forged",
                       "#{redirect_uri}?code=#{@code}&state=%20#{URI.encode_www_form(state)}%20",
                       "#{redirect_uri}?code=real-code&state=#{URI.encode_www_form(state)}"
                     ]
                   end)
                 )

        assert_received {:token_request, "real-code"}
        refute_received {:token_request, _}
      end

      test "falls back to the prompt at the deadline when only forged callbacks arrive" do
        redirect_uri = "http://localhost:#{reserve_local_port()}#{unquote(path)}"

        opts =
          listener_opts(redirect_uri, fn _state ->
            ["#{redirect_uri}?code=#{@code}", "#{redirect_uri}?code=#{@code}&state=forged"]
          end)

        opts = Keyword.merge(opts, callback_timeout_ms: 500, on_prompt: fn _ -> "" end)

        assert {:error, :login_cancelled} = unquote(provider).login_device_flow(opts)
        refute_received {:token_request, _}
      end

      test "exchanges a callback carrying this flow's state" do
        redirect_uri = "http://localhost:#{reserve_local_port()}#{unquote(path)}"

        assert {:ok, _secret} =
                 unquote(provider).login_device_flow(
                   listener_opts(redirect_uri, fn state ->
                     ["#{redirect_uri}?code=#{@code}&state=#{URI.encode_www_form(state)}"]
                   end)
                 )

        assert_received {:token_request, @code}
      end
    end

    describe "#{inspect(provider)} pasted input" do
      test "rejects a pasted callback URL without state" do
        redirect_uri = "http://localhost:#{reserve_local_port()}#{unquote(path)}"

        assert {:error, :missing_oauth_state} =
                 unquote(provider).login_device_flow(
                   paste_opts(redirect_uri, fn _ -> "#{redirect_uri}?code=#{@code}" end)
                 )

        refute_received {:token_request, _}
      end

      test "rejects a pasted code= query without state" do
        redirect_uri = "http://localhost:#{reserve_local_port()}#{unquote(path)}"

        assert {:error, :missing_oauth_state} =
                 unquote(provider).login_device_flow(
                   paste_opts(redirect_uri, fn _ -> "code=#{@code}" end)
                 )

        refute_received {:token_request, _}
      end

      test "rejects a pasted URL with a mismatched state" do
        redirect_uri = "http://localhost:#{reserve_local_port()}#{unquote(path)}"

        assert {:error, :oauth_state_mismatch} =
                 unquote(provider).login_device_flow(
                   paste_opts(redirect_uri, fn _ -> "#{redirect_uri}?code=#{@code}&state=x" end)
                 )

        refute_received {:token_request, _}
      end

      test "rejects a pasted state with added whitespace" do
        redirect_uri = "http://localhost:#{reserve_local_port()}#{unquote(path)}"

        for pasted <- [
              fn state -> "#{redirect_uri}?code=#{@code}&state=%20#{state}%20" end,
              fn state -> "code=#{@code}&state=#{state}%09" end,
              fn state -> "#{@code}# #{state}" end
            ] do
          assert {:error, :oauth_state_mismatch} =
                   unquote(provider).login_device_flow(paste_opts(redirect_uri, pasted))
        end

        assert {:error, :missing_oauth_state} =
                 unquote(provider).login_device_flow(
                   paste_opts(redirect_uri, fn _ -> "#{redirect_uri}?code=#{@code}&state=" end)
                 )

        refute_received {:token_request, _}
      end

      test "a raising on_auth callback fails sign-in with a sanitized error" do
        redirect_uri = "http://localhost:#{reserve_local_port()}#{unquote(path)}"

        opts =
          Keyword.put(paste_opts(redirect_uri, fn _ -> flunk("must not prompt") end), :on_auth, fn
            url, _ -> raise "browser failed for #{url}"
          end)

        {result, log} = with_log(fn -> unquote(provider).login_device_flow(opts) end)
        assert {:error, :auth_callback_failed} = result
        refute log =~ "state="
        refute_received {:token_request, _}
      end

      test "a raising on_progress callback does not abort sign-in" do
        redirect_uri = "http://localhost:#{reserve_local_port()}#{unquote(path)}"

        opts =
          redirect_uri
          |> paste_opts(fn state ->
            "#{redirect_uri}?code=#{@code}&state=#{URI.encode_www_form(state)}"
          end)
          |> Keyword.put(:on_progress, fn _ -> raise "terminal closed" end)

        assert {:ok, _secret} = unquote(provider).login_device_flow(opts)
        assert_received {:token_request, @code}
      end

      test "cancellation from a callback is not swallowed" do
        redirect_uri = "http://localhost:#{reserve_local_port()}#{unquote(path)}"

        opts =
          Keyword.put(paste_opts(redirect_uri, fn _ -> "" end), :on_auth, fn _, _ ->
            exit(:cancelled)
          end)

        assert catch_exit(unquote(provider).login_device_flow(opts)) == :cancelled

        opts = Keyword.put(opts, :on_auth, fn _, _ -> throw(:cancelled) end)
        assert catch_throw(unquote(provider).login_device_flow(opts)) == :cancelled
      end

      test "rejects a bare code because the manual flow always carries state" do
        redirect_uri = "http://localhost:#{reserve_local_port()}#{unquote(path)}"

        assert {:error, :missing_oauth_state} =
                 unquote(provider).login_device_flow(paste_opts(redirect_uri, fn _ -> @code end))

        refute_received {:token_request, _}
      end

      test "exchanges a pasted URL carrying this flow's state" do
        redirect_uri = "http://localhost:#{reserve_local_port()}#{unquote(path)}"

        assert {:ok, _secret} =
                 unquote(provider).login_device_flow(
                   paste_opts(redirect_uri, fn state ->
                     "#{redirect_uri}?code=#{@code}&state=#{URI.encode_www_form(state)}"
                   end)
                 )

        assert_received {:token_request, @code}
      end
    end
  end

  test "Antigravity state is independent of the PKCE verifier" do
    assert {:ok, auth} = GoogleAntigravityOAuth.build_authorize_url()
    refute auth.state == auth.code_verifier
    refute auth.authorize_url =~ auth.code_verifier
  end

  # The browser (or an attacker reaching loopback) hits the real listener.
  defp listener_opts(redirect_uri, callback_url) do
    [
      redirect_uri: redirect_uri,
      project_id: "proj-123",
      callback_timeout_ms: 2_000,
      local_callback_listener: LocalCallbackListener,
      on_auth: fn url, _ ->
        urls = url |> state_from() |> callback_url.()

        spawn(fn ->
          Enum.each(urls, &:httpc.request(:get, {String.to_charlist(&1), []}, [], []))
        end)

        :ok
      end,
      on_prompt: fn _ -> flunk("listener callback must not fall back to the prompt") end
    ]
  end

  defp paste_opts(redirect_uri, pasted) do
    [
      redirect_uri: redirect_uri,
      project_id: "proj-123",
      listen_for_callback: false,
      on_auth: fn url, _ -> send(self(), {:auth_url, url}) end,
      on_prompt: fn _ ->
        assert_received {:auth_url, url}
        url |> state_from() |> pasted.()
      end
    ]
  end

  defp state_from(url) do
    url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")
  end

  defp token_endpoint(conn, test_pid) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    case conn.request_path do
      path when path in ["/token", "/oauth/token", "/v1/oauth/token"] ->
        send(test_pid, {:token_request, decode(conn, body)["code"]})
        Req.Test.json(conn, tokens())

      "/oauth2/v1/userinfo" ->
        Req.Test.json(conn, %{"email" => "dev@example.com"})

      _ ->
        Req.Test.json(conn, %{"cloudaicompanionProject" => %{"id" => "proj-123"}})
    end
  end

  defp decode(conn, body) do
    if Plug.Conn.get_req_header(conn, "content-type") |> Enum.any?(&(&1 =~ "json")),
      do: Jason.decode!(body),
      else: URI.decode_query(body)
  end

  defp tokens do
    claims =
      Jason.encode!(%{
        "exp" => System.system_time(:second) + 3_600,
        "https://api.openai.com/auth" => %{"chatgpt_account_id" => "acc"}
      })

    %{
      "access_token" => "header." <> Base.url_encode64(claims, padding: false) <> ".sig",
      "refresh_token" => "refresh-token",
      "expires_in" => 3_600
    }
  end

  defp reserve_local_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, {:active, false}, {:ip, {127, 0, 0, 1}}])
    {:ok, {_ip, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    port
  end
end
