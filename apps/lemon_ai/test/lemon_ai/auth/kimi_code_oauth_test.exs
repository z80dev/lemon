defmodule LemonAi.Auth.KimiCodeOAuthTest do
  # The provider-header test swaps Req's global default plug.
  use ExUnit.Case, async: false

  alias LemonAi.Auth.{KimiCodeOAuth, OAuthSecretResolver}
  alias LemonAi.EventStream
  alias LemonAi.Providers.Anthropic
  alias LemonAi.Types.{Context, Model, ModelCost, StreamOptions, UserMessage}

  setup do
    previous = Map.new(~w(KIMI_CODE_OAUTH_HOST KIMI_OAUTH_HOST), &{&1, System.get_env(&1)})
    Enum.each(Map.keys(previous), &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    {:ok, opts: [req_options: [plug: {Req.Test, __MODULE__}], sleep: fn _ -> :ok end]}
  end

  defp stub(fun) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(raw)
      send(test_pid, {:request, conn.host, conn.request_path, params, conn.req_headers})
      fun.(conn, conn.request_path, params)
    end)
  end

  defp json(conn, status \\ 200, body),
    do: conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)

  defp jwt(claims) do
    "eyJhbGciOiJub25lIn0.#{claims |> Jason.encode!() |> Base.url_encode64(padding: false)}.sig"
  end

  test "device login polls the Kimi auth host with the CLI fingerprint", %{opts: opts} do
    {:ok, polls} = Agent.start_link(fn -> [:pending] end)
    access_token = jwt(%{"user_id" => "kimi-user", "sub" => "other"})
    test_pid = self()

    stub(fn conn, path, params ->
      assert params["client_id"] == "17e5f671-d194-4dfb-9706-5516cb48c098"

      case path do
        "/api/oauth/device_authorization" ->
          json(conn, %{
            "device_code" => "dev",
            "user_code" => "KIMI-1",
            "verification_uri" => "https://www.kimi.com/device",
            "interval" => 1,
            "expires_in" => 600
          })

        "/api/oauth/token" ->
          case Agent.get_and_update(polls, fn
                 [n | r] -> {n, r}
                 [] -> {:done, []}
               end) do
            :pending ->
              json(conn, 400, %{"error" => "authorization_pending"})

            :done ->
              json(conn, %{
                "access_token" => access_token,
                "refresh_token" => "kimi-rt",
                "expires_in" => 900
              })
          end
      end
    end)

    opts = Keyword.put(opts, :on_auth, fn url, text -> send(test_pid, {:auth, url, text}) end)
    assert {:ok, secret} = KimiCodeOAuth.login_device_flow(opts)

    assert_received {:auth, "https://www.kimi.com/device", "Enter code: KIMI-1"}
    assert_received {:request, "auth.kimi.com", "/api/oauth/device_authorization", _, headers}
    headers = Map.new(headers)
    assert headers["user-agent"] =~ "KimiCLI/"
    assert headers["x-msh-platform"] == "kimi_cli"
    assert byte_size(headers["x-msh-device-id"]) == 32

    assert %{
             "type" => "kimi_code_oauth",
             "access_token" => ^access_token,
             "refresh_token" => "kimi-rt",
             "account_id" => "kimi-user"
           } = secret
  end

  test "KIMI_CODE_OAUTH_HOST overrides the auth host", %{opts: opts} do
    System.put_env("KIMI_CODE_OAUTH_HOST", "https://auth.kimi.test/")

    stub(fn conn, "/api/oauth/device_authorization", _ ->
      json(conn, 400, %{"error" => "invalid_client"})
    end)

    assert {:error, {:device_authorization_failed, {:http_error, 400, "invalid_client"}}} =
             KimiCodeOAuth.login_device_flow(Keyword.put(opts, :on_auth, fn _, _ -> :ok end))

    assert_received {:request, "auth.kimi.test", _, _, _}
  end

  test "a near-expiry login refreshes through the resolver and persists the rotated token",
       %{opts: opts} do
    test_pid = self()

    stub(fn conn, "/api/oauth/token", params ->
      assert params["grant_type"] == "refresh_token"
      assert params["refresh_token"] == "kimi-rt"

      json(conn, %{"access_token" => "fresh", "refresh_token" => "kimi-rt-2", "expires_in" => 900})
    end)

    persist = fn name, value -> send(test_pid, {:persisted, name, value}) end

    assert {:ok, "fresh"} =
             OAuthSecretResolver.resolve_api_key_from_secret(
               "llm_kimi_coding_api_key",
               payload(60_000),
               Keyword.put(opts, :persist_secret, persist)
             )

    assert_received {:persisted, "llm_kimi_coding_api_key", stored}
    assert Jason.decode!(stored)["refresh_token"] == "kimi-rt-2"
  end

  describe "kimi_coding requests" do
    setup do
      previous_defaults = Req.default_options()
      Req.default_options(plug: {Req.Test, __MODULE__})
      Req.Test.set_req_test_to_shared(%{})

      on_exit(fn ->
        Req.default_options(previous_defaults)
        Req.Test.set_req_test_to_private(%{})
      end)
    end

    test "send an OAuth token as a bearer with the fingerprint; API keys keep x-api-key" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:headers, Map.new(conn.req_headers)})
        Plug.Conn.send_resp(conn, 200, "event: message_stop\ndata: {}\n\n")
      end)

      token = jwt(%{"user_id" => "u"})

      for {api_key, oauth?} <- [{token, true}, {"sk-kimi-key", false}] do
        {:ok, stream} =
          Anthropic.stream(
            model(),
            Context.new(messages: [%UserMessage{content: "Hi"}]),
            %StreamOptions{
              api_key: api_key
            }
          )

        assert_receive {:headers, headers}, 1000
        assert {:ok, _} = EventStream.result(stream, 1000)

        if oauth? do
          assert headers["authorization"] == "Bearer #{token}"
          refute Map.has_key?(headers, "x-api-key")
          assert headers["x-msh-platform"] == "kimi_cli"
        else
          assert headers["x-api-key"] == "sk-kimi-key"
          refute Map.has_key?(headers, "x-msh-platform")
        end
      end
    end
  end

  defp model do
    %Model{
      id: "k3",
      name: "Kimi K3",
      api: :anthropic_messages,
      provider: :kimi_coding,
      base_url: "https://api.kimi.com/coding",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 32_768
    }
  end

  defp payload(expires_in_ms) do
    Jason.encode!(%{
      "type" => "kimi_code_oauth",
      "access_token" => "old",
      "refresh_token" => "kimi-rt",
      "expires_at_ms" => System.system_time(:millisecond) + expires_in_ms
    })
  end
end
