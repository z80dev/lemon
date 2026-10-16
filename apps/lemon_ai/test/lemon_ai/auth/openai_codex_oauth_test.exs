defmodule LemonAi.Auth.OpenAICodexOAuthTest do
  use ExUnit.Case, async: false

  alias LemonAi.Auth.OpenAICodexOAuth
  alias LemonCore.{Secrets, Store}

  setup do
    previous_secrets_config = Application.get_env(:lemon_core, LemonCore.Secrets)
    Application.put_env(:lemon_core, LemonCore.Secrets, key_providers: [:env, :file])

    on_exit(fn ->
      if previous_secrets_config,
        do: Application.put_env(:lemon_core, LemonCore.Secrets, previous_secrets_config),
        else: Application.delete_env(:lemon_core, LemonCore.Secrets)
    end)

    home = Path.join(System.tmp_dir!(), "codex_import_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    previous_env = Map.new(["HOME", "CODEX_HOME"], &{&1, System.get_env(&1)})
    System.put_env("HOME", home)
    System.delete_env("CODEX_HOME")

    on_exit(fn ->
      Enum.each(previous_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf!(home)
    end)

    {:ok, _} = Application.ensure_all_started(:lemon_ai)
    {:ok, _} = Application.ensure_all_started(:lemon_core)
    :inets.start()
    :ssl.start()

    previous_defaults = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})

    clear_secrets_table()

    master_key = :crypto.strong_rand_bytes(32) |> Base.encode64()
    System.put_env("LEMON_SECRETS_MASTER_KEY", master_key)

    System.delete_env("OPENAI_CODEX_API_KEY")
    System.delete_env("CHATGPT_TOKEN")

    on_exit(fn ->
      Req.default_options(previous_defaults)
      Req.Test.set_req_test_to_private(%{})
      clear_secrets_table()
      System.delete_env("LEMON_SECRETS_MASTER_KEY")
      System.delete_env("OPENAI_CODEX_API_KEY")
      System.delete_env("CHATGPT_TOKEN")
    end)

    {:ok, home: home}
  end

  test "parse_authorization_input handles callback URL and code#state" do
    assert {:ok, %{code: "abc", state: "state1"}} =
             OpenAICodexOAuth.parse_authorization_input(
               "http://localhost:1455/auth/callback?code=abc&state=state1"
             )

    assert {:ok, %{code: "xyz", state: "state2"}} =
             OpenAICodexOAuth.parse_authorization_input("xyz#state2")
  end

  test "resolve_api_key_from_secret returns stored access token" do
    jwt = make_jwt("acc_test", 3_600)

    payload =
      Jason.encode!(%{
        "type" => "openai_codex_oauth",
        "refresh_token" => "refresh-token",
        "access_token" => jwt,
        "expires_at_ms" => System.system_time(:millisecond) + 3_600_000,
        "account_id" => "acc_test",
        "created_at_ms" => System.system_time(:millisecond),
        "updated_at_ms" => System.system_time(:millisecond)
      })

    assert {:ok, token} =
             OpenAICodexOAuth.resolve_api_key_from_secret("llm_openai_codex_api_key", payload)

    assert token == jwt
    assert is_binary(token)
    assert String.split(token, ".") |> length() == 3
  end

  test "resolve_api_key_from_secret accepts legacy onboarding payloads" do
    jwt = make_jwt("acc_legacy", 3_600)

    payload =
      Jason.encode!(%{
        "type" => "onboarding_openai_codex_oauth",
        "refresh_token" => "refresh-token",
        "access_token" => jwt,
        "expires_at_ms" => System.system_time(:millisecond) + 3_600_000,
        "account_id" => "acc_legacy",
        "created_at_ms" => System.system_time(:millisecond),
        "updated_at_ms" => System.system_time(:millisecond)
      })

    assert {:ok, token} =
             OpenAICodexOAuth.resolve_api_key_from_secret("llm_openai_codex_api_key", payload)

    assert token == jwt
    assert is_binary(token)
    assert String.split(token, ".") |> length() == 3
  end

  test "resolve_access_token prefers OPENAI_CODEX_API_KEY env over stored secrets" do
    oauth_secret =
      Jason.encode!(%{
        "type" => "openai_codex_oauth",
        "refresh_token" => "refresh-token",
        "access_token" => make_jwt("acc_secret", 3_600),
        "expires_at_ms" => System.system_time(:millisecond) + 3_600_000,
        "account_id" => "acc_secret",
        "created_at_ms" => System.system_time(:millisecond),
        "updated_at_ms" => System.system_time(:millisecond)
      })

    assert {:ok, _} = Secrets.set("llm_openai_codex_api_key", oauth_secret)

    System.put_env("OPENAI_CODEX_API_KEY", "env-token")
    assert OpenAICodexOAuth.resolve_access_token() == "env-token"
  end

  test "resolve_access_token returns nil when env vars are missing" do
    assert OpenAICodexOAuth.resolve_access_token() == nil
  end

  test "resolve_api_key_from_secret refreshes near-expiry token and calls persistence callback" do
    secret_name = "llm_openai_codex_api_key"
    test_pid = self()

    original_payload =
      Jason.encode!(%{
        "type" => "openai_codex_oauth",
        "refresh_token" => "refresh-token",
        "access_token" => make_jwt("acc_old", -60),
        "expires_at_ms" => System.system_time(:millisecond) - 1_000,
        "account_id" => "acc_old",
        "created_at_ms" => System.system_time(:millisecond),
        "updated_at_ms" => System.system_time(:millisecond)
      })

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/oauth/token"

      Plug.Conn.send_resp(
        conn,
        200,
        Jason.encode!(%{
          "access_token" => make_jwt("acc_new", 3_600),
          "refresh_token" => "fresh-refresh-token",
          "expires_in" => 3600
        })
      )
    end)

    revision = make_ref()

    assert {:ok, refreshed_token} =
             OpenAICodexOAuth.resolve_api_key_from_secret(
               secret_name,
               original_payload,
               reload_secret: fn _ -> {:ok, original_payload, revision} end,
               persist_secret: fn name, value, expected ->
                 assert expected == revision
                 send(test_pid, {:persisted_secret, name, value})
                 :ok
               end
             )

    assert is_binary(refreshed_token)

    assert_receive {:persisted_secret, ^secret_name, refreshed_payload}, 1000
    assert {:ok, decoded} = Jason.decode(refreshed_payload)
    assert decoded["refresh_token"] == "fresh-refresh-token"
    assert decoded["account_id"] == "acc_new"
  end

  test "login_device_flow exchanges pasted code and returns oauth secret" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/oauth/token"

      Plug.Conn.send_resp(
        conn,
        200,
        Jason.encode!(%{
          "access_token" => make_jwt("acc_login", 3_600),
          "refresh_token" => "fresh-refresh-token",
          "expires_in" => 3600
        })
      )
    end)

    assert {:ok, secret} =
             OpenAICodexOAuth.login_device_flow(
               listen_for_callback: false,
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

    assert secret["type"] == "openai_codex_oauth"
    assert secret["refresh_token"] == "fresh-refresh-token"
    assert secret["account_id"] == "acc_login"
    assert is_binary(secret["access_token"])
    assert is_integer(secret["expires_at_ms"])
  end

  test "login_device_flow captures localhost callback automatically" do
    redirect_uri = "http://localhost:#{reserve_local_port()}/auth/callback"

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/oauth/token"

      Plug.Conn.send_resp(
        conn,
        200,
        Jason.encode!(%{
          "access_token" => make_jwt("acc_auto", 3_600),
          "refresh_token" => "auto-refresh-token",
          "expires_in" => 3600
        })
      )
    end)

    assert {:ok, secret} =
             OpenAICodexOAuth.login_device_flow(
               redirect_uri: redirect_uri,
               callback_timeout_ms: 2_000,
               local_callback_listener: LemonCore.OAuth.LocalCallbackListener,
               on_auth: fn url, _instructions ->
                 state = extract_query_param(url, "state")

                 deliver_local_callback(
                   "#{redirect_uri}?code=authorization-code-123&state=#{state}"
                 )
               end,
               on_prompt: fn _prompt ->
                 flunk("expected localhost callback capture without prompting")
               end
             )

    assert secret["type"] == "openai_codex_oauth"
    assert secret["refresh_token"] == "auto-refresh-token"
    assert secret["account_id"] == "acc_auto"
  end

  test "imports only the selected synthetic CLI copy without HTTP or writes", %{home: home} do
    Req.Test.stub(__MODULE__, fn _ -> flunk("import must not call HTTP") end)
    path = Path.join([home, ".codex", "auth.json"])
    login = cli_login(3_600)
    original = write_cli_login(path, login)

    assert {:ok, secret} = OpenAICodexOAuth.import_codex_cli_login()
    assert secret["type"] == "openai_codex_oauth"
    assert secret["access_token"] == login["tokens"]["access_token"]
    assert secret["refresh_token"] == "synthetic-refresh"
    assert secret["id_token"] == login["tokens"]["id_token"]
    assert secret["account_id"] == "acc_import"
    [_, payload, _] = String.split(secret["access_token"], ".")
    claims = payload |> Base.url_decode64!(padding: false) |> Jason.decode!()
    assert secret["expires_at_ms"] == claims["exp"] * 1000
    assert File.read!(path) == original

    codex_home = Path.join(home, "alternate")
    System.put_env("CODEX_HOME", codex_home)
    assert {:error, :enoent} = OpenAICodexOAuth.import_codex_cli_login()
    write_cli_login(Path.join(codex_home, "auth.json"), %{"OPENAI_API_KEY" => "synthetic-key"})
    assert {:error, :not_chatgpt_oauth} = OpenAICodexOAuth.import_codex_cli_login()
    assert {:ok, selected} = OpenAICodexOAuth.import_codex_cli_login(path: path)
    assert selected["access_token"] == secret["access_token"]
  end

  test "rejects malformed and non-refreshable CLI logins with safe errors", %{home: home} do
    Req.Test.stub(__MODULE__, fn _ -> flunk("import must not call HTTP") end)
    path = Path.join(home, "invalid.json")

    cases = [
      {%{}, :not_chatgpt_oauth},
      {%{"OPENAI_API_KEY" => "secret-marker"}, :not_chatgpt_oauth},
      {Map.put(cli_login(60), "auth_mode", "apikey"), :not_chatgpt_oauth},
      {put_in(cli_login(60), ["tokens", "refresh_token"], " "), :missing_refresh_token},
      {put_in(cli_login(60), ["tokens", "access_token"], "secret-marker"), :invalid_access_token},
      {put_in(cli_login(60), ["tokens", "access_token"], jwt(%{"exp" => "bad"})),
       :invalid_expiry},
      {%{"tokens" => %{"access_token" => jwt(%{"exp" => 1}), "refresh_token" => "secret-marker"}},
       :missing_account_id},
      {%{"tokens" => []}, :not_chatgpt_oauth}
    ]

    for {login, reason} <- cases do
      original = write_cli_login(path, login)
      assert OpenAICodexOAuth.import_codex_cli_login(path: path) == {:error, reason}
      assert File.read!(path) == original
    end

    File.write!(path, "secret-marker invalid JSON")

    assert {:error, :invalid_codex_cli_login} =
             OpenAICodexOAuth.import_codex_cli_login(path: path)

    assert {:error, :invalid_codex_auth_path} = OpenAICodexOAuth.import_codex_cli_login(path: 42)
  end

  test "imported expired login refreshes and persists only the Lemon secret", %{home: home} do
    path = Path.join(home, "auth.json")
    original = write_cli_login(path, cli_login(-60))
    assert {:ok, secret} = OpenAICodexOAuth.import_codex_cli_login(path: path)
    name = "llm_openai_codex_api_key"
    assert {:ok, _} = Secrets.set(name, OpenAICodexOAuth.encode_secret(secret))
    fresh_token = make_jwt("acc_import", 900)
    now = System.system_time(:millisecond)
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert URI.decode_query(body)["refresh_token"] == "synthetic-refresh"
      send(test_pid, :refreshed)

      Req.Test.json(conn, %{
        "access_token" => fresh_token,
        "refresh_token" => "rotated-synthetic-refresh",
        "expires_in" => 900
      })
    end)

    assert {:ok, ^fresh_token} =
             OpenAICodexOAuth.resolve_api_key_from_secret(
               name,
               OpenAICodexOAuth.encode_secret(secret),
               reload_secret: &Secrets.get_with_revision/1,
               persist_secret: &Secrets.set_if_revision/3
             )

    assert_receive :refreshed
    assert {:ok, stored} = Secrets.get(name, prefer_env: false, env_fallback: false)
    assert {:ok, updated} = OpenAICodexOAuth.decode_secret(stored)
    assert updated["refresh_token"] == "rotated-synthetic-refresh"
    assert updated["expires_at_ms"] >= now + 900_000
    assert {:ok, ^fresh_token} = OpenAICodexOAuth.resolve_api_key_from_secret(name, stored)
    refute_received :refreshed
    assert File.read!(path) == original
  end

  test "refresh does not claim success when rotating credentials cannot be persisted", %{
    home: home
  } do
    path = Path.join(home, "auth.json")
    original = write_cli_login(path, cli_login(-60))
    assert {:ok, secret} = OpenAICodexOAuth.import_codex_cli_login(path: path)
    fresh_token = make_jwt("acc_import", 900)

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "access_token" => fresh_token,
        "refresh_token" => "rotated-synthetic-refresh",
        "expires_in" => 900
      })
    end)

    for callback <- [
          fn _, _, _ -> {:error, :store_unavailable} end,
          fn _, _, _ -> raise "sensitive storage error must not escape" end
        ] do
      assert {:error, :oauth_secret_persistence_failed} =
               OpenAICodexOAuth.resolve_api_key_from_secret(
                 "llm_openai_codex_api_key",
                 OpenAICodexOAuth.encode_secret(secret),
                 reload_secret: fn _ ->
                   {:ok, OpenAICodexOAuth.encode_secret(secret), :test_revision}
                 end,
                 persist_secret: callback
               )
    end

    assert File.read!(path) == original
  end

  test "refresh failure falls back only to an unexpired token", %{home: home} do
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 400, "{}") end)
    path = Path.join(home, "auth.json")

    for {seconds, expected} <- [{-60, :error}, {60, :ok}] do
      write_cli_login(path, cli_login(seconds))
      assert {:ok, secret} = OpenAICodexOAuth.import_codex_cli_login(path: path)

      result =
        OpenAICodexOAuth.resolve_api_key_from_secret(
          "synthetic",
          OpenAICodexOAuth.encode_secret(secret),
          reload_secret: fn _ ->
            {:ok, OpenAICodexOAuth.encode_secret(secret), :test_revision}
          end,
          persist_secret: fn _, _, _ -> flunk("failed refresh must not persist") end
        )

      assert elem(result, 0) == expected
    end
  end

  test "JWT expiry bounds fallback even with a later stored expiry" do
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 400, "{}") end)

    secret = %{
      "type" => "openai_codex_oauth",
      "access_token" => make_jwt("expired-account", -60),
      "refresh_token" => "synthetic-refresh",
      "expires_at_ms" => System.system_time(:millisecond) + 3_600_000
    }

    assert {:error, _} =
             OpenAICodexOAuth.resolve_api_key_from_secret(
               "synthetic",
               OpenAICodexOAuth.encode_secret(secret)
             )

    assert {:error, :expired_access_token} =
             OpenAICodexOAuth.resolve_api_key_from_secret(
               "synthetic",
               secret |> Map.delete("refresh_token") |> OpenAICodexOAuth.encode_secret()
             )
  end

  test "imports legacy CLI shape with account claim in id_token", %{home: home} do
    login =
      cli_login(3_600)
      |> Map.delete("auth_mode")
      |> update_in(["tokens"], &Map.delete(&1, "account_id"))
      |> put_in(["tokens", "access_token"], jwt(%{"exp" => System.system_time(:second) + 3_600}))

    path = Path.join(home, "legacy.json")
    write_cli_login(path, login)
    assert {:ok, secret} = OpenAICodexOAuth.import_codex_cli_login(path: path)
    assert secret["account_id"] == "acc_import"
  end

  test "token HTTP and malformed success errors never expose provider payloads" do
    for {status, body, reason} <- [
          {400, %{"error" => "secret-code", "access_token" => "secret-token"},
           {:http_error, 400}},
          {200, %{"refresh_token" => "secret-refresh"}, :invalid_token_response},
          {200, %{"access_token" => "secret-token", "expires_in" => 0}, :invalid_expiry}
        ] do
      Req.Test.stub(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
      end)

      assert {:error, ^reason} = OpenAICodexOAuth.exchange_code_for_secret("code", "verifier")
    end
  end

  test "refresh fails closed when the stored login was removed or replaced" do
    Req.Test.stub(__MODULE__, fn _ -> flunk("must not refresh a stale login") end)

    secret = %{
      "type" => "openai_codex_oauth",
      "access_token" => make_jwt("account", 60),
      "refresh_token" => "secret-refresh",
      "expires_at_ms" => 0
    }

    for {loaded, reason} <- [
          {{:error, :not_found}, :oauth_secret_missing},
          {{:ok, "plain-api-key"}, :oauth_secret_replaced}
        ] do
      assert {:error, ^reason} =
               OpenAICodexOAuth.resolve_api_key_from_secret(
                 "custom-codex-login",
                 OpenAICodexOAuth.encode_secret(secret),
                 force_refresh: true,
                 reload_secret: fn "custom-codex-login" -> loaded end
               )
    end
  end

  test "invalid_grant never falls back to an unexpired Codex access token" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "invalid_grant"})
    end)

    secret = %{
      "type" => "openai_codex_oauth",
      "access_token" => make_jwt("account", 60),
      "refresh_token" => "secret-refresh",
      "expires_at_ms" => 0
    }

    assert {:error, :reauth_required} =
             OpenAICodexOAuth.resolve_api_key_from_secret(
               "custom-codex-login",
               OpenAICodexOAuth.encode_secret(secret)
             )
  end

  test "device sign-in passes the issued verifier and injected HTTP options to exchange" do
    test_pid = self()
    Req.Test.stub(__MODULE__, fn _ -> flunk("must use per-flow HTTP options") end)

    plug = fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      case conn.request_path do
        "/device/usercode" ->
          Req.Test.json(conn, %{
            "device_auth_id" => "device-id",
            "user_code" => "USER",
            "interval" => 1,
            "expires_in" => 60
          })

        "/device/token" ->
          assert Jason.decode!(raw) == %{"device_auth_id" => "device-id", "user_code" => "USER"}

          Req.Test.json(conn, %{
            "authorization_code" => "issued-code",
            "code_verifier" => "issued-verifier"
          })

        "/device/exchange" ->
          params = URI.decode_query(raw)
          assert params["code"] == "issued-code"
          assert params["code_verifier"] == "issued-verifier"
          assert params["redirect_uri"] == "https://auth.openai.com/deviceauth/callback"
          send(test_pid, :exchanged)

          Req.Test.json(conn, %{
            "access_token" => make_jwt("device-account", 3600),
            "refresh_token" => "rotated-refresh",
            "expires_in" => 3600
          })
      end
    end

    assert {:ok, %{"account_id" => "device-account", "refresh_token" => "rotated-refresh"}} =
             OpenAICodexOAuth.login_device_code(
               device_usercode_url: "https://auth.test/device/usercode",
               device_token_url: "https://auth.test/device/token",
               token_url: "https://auth.test/device/exchange",
               req_options: [plug: plug],
               on_auth: fn _, _ -> :ok end,
               on_device_code: fn metadata -> send(test_pid, {:device_metadata, metadata}) end,
               sleep: fn _ -> :ok end
             )

    assert_received :exchanged
    assert_received {:device_metadata, metadata}

    assert Enum.sort(Map.keys(metadata)) ==
             [:expires_at_ms, :poll_interval_ms, :user_code, :verification_url]

    assert metadata.verification_url == "https://auth.openai.com/codex/device"
    assert metadata.user_code == "USER"
    assert metadata.poll_interval_ms == 4_000
    assert metadata.expires_at_ms > System.system_time(:millisecond)
    refute inspect(metadata) =~ "device-id"
    refute inspect(metadata) =~ "issued-verifier"
  end

  test "device expiry includes time spent showing authorization instructions" do
    {:ok, clock} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/api/accounts/deviceauth/usercode"

      Req.Test.json(conn, %{
        "device_auth_id" => "device-id",
        "user_code" => "USER",
        "interval" => 1,
        "expires_in" => 30
      })
    end)

    assert {:error, :device_flow_timed_out} =
             OpenAICodexOAuth.login_device_code(
               now: fn -> Agent.get(clock, & &1) end,
               on_auth: fn _, _ -> Agent.update(clock, fn _ -> 31_000 end) end,
               sleep: fn _ -> flunk("must not wait or poll after expiry") end
             )
  end

  test "device polling counts HTTP duration rather than only poll attempts" do
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/api/accounts/deviceauth/usercode" ->
          Req.Test.json(conn, %{
            "device_auth_id" => "device-id",
            "user_code" => "USER",
            "interval" => 1,
            "expires_in" => 30
          })

        "/api/accounts/deviceauth/token" ->
          send(test_pid, :device_polled)
          Agent.update(clock, &(&1 + 31_000))
          Plug.Conn.send_resp(conn, 403, "")
      end
    end)

    assert {:error, :device_flow_timed_out} =
             OpenAICodexOAuth.login_device_code(
               now: fn -> Agent.get(clock, & &1) end,
               on_auth: fn _, _ -> :ok end,
               sleep: fn _ -> :ok end
             )

    assert_received :device_polled
    refute_received :device_polled
  end

  test "mock device transport honors the full provider interval before its first poll" do
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/api/accounts/deviceauth/usercode" ->
          Req.Test.json(conn, %{
            "device_auth_id" => "private-device-id",
            "user_code" => "MOCK-USER",
            "interval" => 10,
            "expires_in" => 60
          })

        "/api/accounts/deviceauth/token" ->
          Plug.Conn.send_resp(conn, 403, Jason.encode!(%{"error" => "access_denied"}))

        _ ->
          flunk("denied mock grant must never exchange a token")
      end
    end)

    assert {:error, :access_denied} =
             OpenAICodexOAuth.login_device_code(
               on_auth: fn _, _ -> :ok end,
               sleep: fn milliseconds -> send(parent, {:slept, milliseconds}) end
             )

    assert_received {:slept, 13_000}
    refute_received {:slept, _}
  end

  test "mock explicit denial and expiry are terminal instead of bare 403 pending" do
    for {status, error, expected} <- [
          {400, "access_denied", :access_denied},
          {403, "access_denied", :access_denied},
          {403, "expired_token", :device_code_expired}
        ] do
      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/api/accounts/deviceauth/usercode" ->
            Req.Test.json(conn, %{
              "device_auth_id" => "private-device-id",
              "user_code" => "MOCK-USER",
              "interval" => 1,
              "expires_in" => 60
            })

          "/api/accounts/deviceauth/token" ->
            Plug.Conn.send_resp(conn, status, Jason.encode!(%{"error" => error}))

          _ ->
            flunk("terminal mock grant must never exchange a token")
        end
      end)

      assert {:error, ^expected} =
               OpenAICodexOAuth.login_device_code(
                 on_auth: fn _, _ -> :ok end,
                 sleep: fn _ -> :ok end
               )
    end
  end

  test "mock device metadata bounds lifetime and rejects unsafe interval or code" do
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/api/accounts/deviceauth/usercode" ->
          Req.Test.json(conn, %{
            "device_auth_id" => "private-device-id",
            "user_code" => "MOCK-USER",
            "interval" => 57,
            "expires_in" => 999_999
          })

        "/api/accounts/deviceauth/token" ->
          Plug.Conn.send_resp(conn, 400, Jason.encode!(%{"error" => "access_denied"}))
      end
    end)

    before = System.system_time(:millisecond)

    assert {:error, :access_denied} =
             OpenAICodexOAuth.login_device_code(
               on_auth: fn _, _ -> :ok end,
               on_device_code: fn metadata -> send(parent, {:bounded_metadata, metadata}) end,
               sleep: fn _ -> :ok end
             )

    assert_received {:bounded_metadata, metadata}
    assert metadata.poll_interval_ms == 60_000
    assert metadata.expires_at_ms >= before + 900_000
    assert metadata.expires_at_ms <= System.system_time(:millisecond) + 900_000

    for override <- [
          %{"interval" => 58},
          %{"interval" => 0},
          %{"expires_in" => 0},
          %{"device_auth_id" => nil},
          %{"user_code" => nil},
          %{"user_code" => String.duplicate("A", 65)},
          %{"user_code" => "MOCK?private-device-id"},
          %{"device_auth_id" => String.duplicate("A", 4097)}
        ] do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/api/accounts/deviceauth/usercode"

        Req.Test.json(
          conn,
          Map.merge(
            %{
              "device_auth_id" => "private-device-id",
              "user_code" => "MOCK-USER",
              "interval" => 5,
              "expires_in" => 60
            },
            override
          )
        )
      end)

      assert {:error, :invalid_device_authorization_response} =
               OpenAICodexOAuth.login_device_code(
                 on_auth: fn _, _ -> flunk("invalid mock metadata must not be published") end,
                 sleep: fn _ -> flunk("invalid mock metadata must not poll") end
               )
    end
  end

  test "mock device authorization rejects missing required fields without publishing or polling" do
    for body <- [
          %{},
          %{"device_auth_id" => "private-device-id"},
          %{"user_code" => "MOCK-USER"}
        ] do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/api/accounts/deviceauth/usercode"
        Req.Test.json(conn, body)
      end)

      assert {:error, :invalid_device_authorization_response} =
               OpenAICodexOAuth.login_device_code(
                 on_auth: fn _, _ -> flunk("missing mock fields must not be published") end,
                 on_device_code: fn _ -> flunk("missing mock fields must not expose metadata") end,
                 sleep: fn _ -> flunk("missing mock fields must not poll") end
               )
    end
  end

  defp cli_login(seconds) do
    %{
      "auth_mode" => "chatgpt",
      "OPENAI_API_KEY" => nil,
      "tokens" => %{
        "access_token" => make_jwt("acc_import", seconds),
        "refresh_token" => "synthetic-refresh",
        "account_id" => "acc_import",
        "id_token" => make_jwt("acc_import", seconds)
      }
    }
  end

  defp write_cli_login(path, login) do
    contents = Jason.encode!(login)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    contents
  end

  defp jwt(claims),
    do: "header." <> Base.url_encode64(Jason.encode!(claims), padding: false) <> ".signature"

  defp make_jwt(account_id, expires_in_seconds) do
    exp = DateTime.utc_now() |> DateTime.add(expires_in_seconds, :second) |> DateTime.to_unix()

    payload =
      Jason.encode!(%{
        "exp" => exp,
        "https://api.openai.com/auth" => %{"chatgpt_account_id" => account_id}
      })

    "header." <> Base.url_encode64(payload, padding: false) <> ".signature"
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

  defp reserve_local_port do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, {:packet, :raw}, {:active, false}, {:ip, {127, 0, 0, 1}}])

    {:ok, {_ip, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    port
  end

  defp deliver_local_callback(url) do
    assert {:ok, _response} = :httpc.request(:get, {String.to_charlist(url), []}, [], [])
  end
end
