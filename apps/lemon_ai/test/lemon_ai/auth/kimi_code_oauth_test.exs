defmodule LemonAi.Auth.KimiCodeOAuthTest do
  # The provider-header test swaps Req's global default plug.
  use ExUnit.Case, async: false

  alias LemonAi.Auth.{KimiCodeOAuth, OAuthSecretResolver}
  alias LemonAi.EventStream
  alias LemonAi.Providers.Anthropic
  alias LemonAi.Types.{Context, StreamOptions, UserMessage}

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

    secret = payload(60_000)
    revision = make_ref()

    persist = fn name, value, expected ->
      assert expected == revision
      send(test_pid, {:persisted, name, value})
      :ok
    end

    assert {:ok, "fresh"} =
             OAuthSecretResolver.resolve_api_key_from_secret(
               "llm_kimi_coding_api_key",
               secret,
               Keyword.merge(opts,
                 reload_secret: fn _ -> {:ok, secret, revision} end,
                 persist_secret: persist
               )
             )

    assert_received {:persisted, "llm_kimi_coding_api_key", stored}
    assert Jason.decode!(stored)["refresh_token"] == "kimi-rt-2"
  end

  test "forced refresh fails without returning the rejected token or provider payload",
       %{opts: opts} do
    stub(fn conn, "/api/oauth/token", _ ->
      json(conn, 503, %{"error" => "secret-access-token", "error_description" => "secret-code"})
    end)

    assert {:error, {:http_error, 503}} =
             KimiCodeOAuth.resolve_api_key_from_secret(
               "custom-kimi-login",
               payload(3_600_000),
               Keyword.put(opts, :force_refresh, true)
             )
  end

  test "forced refresh reuses a login already rotated under the same storage name", %{opts: opts} do
    stub(fn _, _, _ -> flunk("must reuse the stored rotated token") end)
    stored = payload(3_600_000) |> Jason.decode!() |> Map.put("access_token", "already-rotated")

    assert {:ok, "already-rotated"} =
             KimiCodeOAuth.resolve_api_key_from_secret(
               "custom-kimi-login",
               payload(3_600_000),
               Keyword.merge(opts,
                 force_refresh: true,
                 reload_secret: fn "custom-kimi-login" -> {:ok, Jason.encode!(stored)} end
               )
             )
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

    test "every kimi_coding request carries one consistent fingerprint; only JWTs are bearers" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 200, "event: message_stop\ndata: {}\n\n")
      end)

      token = jwt(%{"user_id" => "u"})

      for {api_key, oauth?} <- [{token, true}, {"sk-kimi-key", false}] do
        {:ok, stream} =
          Anthropic.stream(
            LemonAi.Models.get_model(:kimi_coding, "k3.1-pro"),
            Context.new(messages: [%UserMessage{content: "Hi"}]),
            %StreamOptions{api_key: api_key}
          )

        assert_receive {:headers, raw_headers}, 1000
        assert {:ok, _} = EventStream.result(stream, 1000)

        assert [user_agent] =
                 for(
                   {name, value} <- raw_headers,
                   String.downcase(name) == "user-agent",
                   do: value
                 )

        headers = Map.new(raw_headers)
        assert user_agent == "KimiCLI/" <> headers["x-msh-version"]
        assert headers["x-msh-platform"] == "kimi_cli"
        assert headers["x-msh-device-id"] =~ ~r/^[\x21-\x7E]+$/

        if oauth? do
          assert headers["authorization"] == "Bearer #{token}"
          refute Map.has_key?(headers, "x-api-key")
        else
          assert headers["x-api-key"] == "sk-kimi-key"
          refute Map.has_key?(headers, "authorization")
        end
      end
    end

    test "Kimi Code reasoning models send adaptive thinking, effort, full output and a session cache identity" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, Map.new(conn.req_headers), Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, "event: message_stop\ndata: {}\n\n")
      end)

      request = fn model_id, opts ->
        {:ok, stream} =
          Anthropic.stream(
            LemonAi.Models.get_model(:kimi_coding, model_id),
            Context.new(messages: [%UserMessage{content: "Hi"}]),
            struct!(%StreamOptions{api_key: "sk-kimi-key"}, opts)
          )

        assert_receive {:request, headers, body}, 1000
        assert {:ok, _} = EventStream.result(stream, 1000)
        {headers, body}
      end

      for model_id <- ~w(k3 k3-256k k3.1-pro k3.1-pro-highspeed kimi-for-coding) do
        model = LemonAi.Models.get_model(:kimi_coding, model_id)
        {headers, body} = request.(model_id, reasoning: :high, session_id: "session-1")

        assert body["thinking"] == %{"type" => "adaptive"}, model_id
        assert body["output_config"] == %{"effort" => "high"}, model_id
        assert "effort-2025-11-24" in String.split(headers["anthropic-beta"], ",")
        assert body["max_tokens"] == model.max_tokens
        assert %{"user_id" => "lemon_" <> _ = user_id} = body["metadata"]
        refute user_id =~ "session-1"
      end

      {_, same} = request.("k3", reasoning: :low, session_id: "session-1")
      {_, other} = request.("k3", reasoning: :low, session_id: "session-2")
      assert same["metadata"] == elem(request.("k3", session_id: "session-1"), 1)["metadata"]
      refute same["metadata"] == other["metadata"]

      {_, explicit} = request.("k3", max_tokens: 4096)
      assert explicit["max_tokens"] == 4096
      refute Map.has_key?(explicit, "thinking")

      {_, forced} = request.("k3", reasoning: :high, tool_choice: :any)
      assert forced["output_config"] == %{"effort" => "low"}
      refute Map.has_key?(forced, "thinking")

      {_, uncached} =
        request.("k3",
          session_id: "session-1",
          provider_options: %{kimi_coding: %{cache_retention: :none}}
        )

      refute Map.has_key?(uncached, "metadata")
    end
  end

  test "Kimi K2.5 Coding accepts images" do
    assert :image in LemonAi.Models.get_model(:kimi_coding, "kimi-k2.5-coding").input
  end

  describe "device_id/1" do
    setup do
      home = Path.join(System.tmp_dir!(), "kimi_device_#{System.unique_integer([:positive])}")
      File.mkdir_p!(home)
      on_exit(fn -> File.rm_rf!(home) end)
      {:ok, home: home, path: Path.join([home, ".lemon", "kimi-device-id"])}
    end

    test "seeds the pre-persistence identity privately and keeps it across host renames",
         %{home: home, path: path} do
      legacy = legacy_id("old-host", home)

      assert KimiCodeOAuth.device_id(home: home, hostname: "old-host") == legacy
      assert File.read!(path) == legacy <> "\n"
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600

      assert KimiCodeOAuth.device_id(home: home, hostname: "renamed-host") == legacy
    end

    test "uses an existing id and reseeds an empty file", %{home: home, path: path} do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "  existing-device-id\n")
      assert KimiCodeOAuth.device_id(home: home, hostname: "h") == "existing-device-id"

      File.write!(path, "\n")
      seeded = KimiCodeOAuth.device_id(home: home, hostname: "h")
      assert seeded =~ ~r/^[0-9a-f]{32}$/
      assert File.read!(path) == seeded <> "\n"
    end

    test "falls back to the derived id when the file cannot be read or written",
         %{home: home, path: path} do
      # A directory in place of the file can be neither read as an id nor replaced.
      blocked = Path.join(home, "blocked")
      File.mkdir_p!(Path.join([blocked, ".lemon", "kimi-device-id"]))
      assert KimiCodeOAuth.device_id(home: blocked, hostname: "h") == legacy_id("h", blocked)
      assert File.dir?(Path.join([blocked, ".lemon", "kimi-device-id"]))

      # A file where ~/.lemon belongs prevents creating the directory.
      File.write!(Path.join(home, ".lemon"), "not a directory")
      assert KimiCodeOAuth.device_id(home: home, hostname: "h") == legacy_id("h", home)
      refute File.exists?(path)
    end
  end

  defp legacy_id(hostname, home) do
    :crypto.hash(:sha256, "lemon-kimi-device:#{hostname}:#{home}")
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
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
