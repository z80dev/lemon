defmodule LemonAi.Auth.OpenAICodexDeviceTest do
  # Codex token exchange uses Req's global default plug.
  use ExUnit.Case, async: false

  alias LemonAi.Auth.OpenAICodexOAuth

  setup do
    previous_defaults = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})

    on_exit(fn ->
      Req.default_options(previous_defaults)
      Req.Test.set_req_test_to_private(%{})
    end)

    :ok
  end

  defp access_token do
    claims = %{
      "exp" => div(System.system_time(:millisecond), 1000) + 3600,
      "https://api.openai.com/auth" => %{"chatgpt_account_id" => "acct-1"}
    }

    "eyJhbGciOiJub25lIn0.#{claims |> Jason.encode!() |> Base.url_encode64(padding: false)}.sig"
  end

  defp stub(polls) do
    test_pid = self()
    {:ok, agent} = Agent.start_link(fn -> polls end)
    token = access_token()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn.request_path, raw})

      case conn.request_path do
        "/api/accounts/deviceauth/usercode" ->
          assert Jason.decode!(raw) == %{"client_id" => OpenAICodexOAuth.oauth_client_id()}

          Req.Test.json(conn, %{
            "device_auth_id" => "dev-auth",
            "user_code" => "CODE-12",
            "interval" => "2"
          })

        "/api/accounts/deviceauth/token" ->
          assert Jason.decode!(raw) == %{"device_auth_id" => "dev-auth", "user_code" => "CODE-12"}

          case Agent.get_and_update(agent, fn
                 [n | r] -> {n, r}
                 [] -> {:done, []}
               end) do
            status when is_integer(status) ->
              Plug.Conn.send_resp(conn, status, "")

            :done ->
              Req.Test.json(conn, %{
                "authorization_code" => "auth-code",
                "code_verifier" => "verifier-1"
              })
          end

        "/oauth/token" ->
          Req.Test.json(conn, %{
            "access_token" => token,
            "refresh_token" => "rt",
            "expires_in" => 3600
          })
      end
    end)
  end

  test "device-code login yields the same payload as the browser flow" do
    stub([403, 404])
    test_pid = self()

    assert {:ok, secret} =
             OpenAICodexOAuth.login_device_code(
               on_auth: fn url, text -> send(test_pid, {:auth, url, text}) end,
               sleep: fn ms -> send(test_pid, {:slept, ms}) end
             )

    assert_received {:auth, "https://auth.openai.com/codex/device", "Enter code: CODE-12"}
    # First wait is capped at five seconds, later waits are interval + 3s.
    assert_received {:slept, 5000}
    assert_received {:slept, 5000}
    assert_received {:request, "/oauth/token", raw}

    assert URI.decode_query(raw) == %{
             "grant_type" => "authorization_code",
             "client_id" => OpenAICodexOAuth.oauth_client_id(),
             "code" => "auth-code",
             "code_verifier" => "verifier-1",
             "redirect_uri" => "https://auth.openai.com/deviceauth/callback"
           }

    assert %{
             "type" => "openai_codex_oauth",
             "refresh_token" => "rt",
             "account_id" => "acct-1",
             "redirect_uri" => "https://auth.openai.com/deviceauth/callback"
           } = secret

    assert {:ok, _token} =
             OpenAICodexOAuth.resolve_api_key_from_secret(
               "llm_openai_codex_api_key",
               OpenAICodexOAuth.encode_secret(secret)
             )
  end

  test "a polling error other than pending stops the flow" do
    stub([500])

    assert {:error, {:device_token_failed, 500}} =
             OpenAICodexOAuth.login_device_code(
               on_auth: fn _, _ -> :ok end,
               sleep: fn _ -> :ok end
             )

    refute_received {:request, "/oauth/token", _}
  end
end
