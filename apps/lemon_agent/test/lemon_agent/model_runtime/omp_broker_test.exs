defmodule LemonAgent.ModelRuntime.OmpBrokerTest do
  use ExUnit.Case, async: false

  alias LemonAgent.ModelRuntime.Credentials
  alias LemonAi.Auth.OmpAuthBroker

  @env ~w(OMP_AUTH_BROKER_URL OMP_AUTH_BROKER_TOKEN OMP_AUTH_GATEWAY_TOKEN ANTHROPIC_API_KEY
          HOME PI_CONFIG_DIR OMP_PROFILE PI_PROFILE)

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_ai)
    saved = Map.new(@env, &{&1, System.get_env(&1)})
    previous = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})
    OmpAuthBroker.invalidate_all()

    System.put_env("OMP_AUTH_BROKER_URL", "http://broker.test:8765")
    System.put_env("OMP_AUTH_BROKER_TOKEN", "broker-bearer")

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      Req.default_options(previous)
      Req.Test.set_req_test_to_private(%{})
      OmpAuthBroker.invalidate_all()
    end)

    :ok
  end

  defp now_ms, do: System.system_time(:millisecond)

  defp oauth(id, provider, access, identity, extra \\ %{}) do
    %{
      "id" => id,
      "provider" => provider,
      "identityKey" => identity,
      "credential" =>
        Map.merge(
          %{
            "type" => "oauth",
            "access" => access,
            "refresh" => "__remote__",
            "expires" => now_ms() + 3_600_000
          },
          extra
        )
    }
  end

  defp serve(credentials, refresh \\ fn _id, _query -> raise "unexpected refresh" end) do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, {:broker, conn.method, conn.request_path, conn.query_string})

      case {conn.host, conn.method, conn.request_path} do
        {"broker.test", "GET", "/v1/snapshot"} ->
          Req.Test.json(conn, %{
            "generation" => 1,
            "generatedAt" => now_ms(),
            "serverNowMs" => now_ms(),
            "refresher" => %{
              "enabled" => true,
              "intervalMs" => 60_000,
              "skewMs" => 300_000,
              "nextSweepInMs" => 1_000
            },
            "credentials" => Enum.map(credentials, &Map.put_new(&1, "rotatesInMs", nil))
          })

        {"broker.test", "POST", "/v1/credential/" <> rest} ->
          [id, "refresh"] = String.split(rest, "/")
          Req.Test.json(conn, %{"entry" => refresh.(String.to_integer(id), conn.query_string)})
      end
    end)
  end

  test "broker credentials are authoritative and fail closed" do
    System.put_env("ANTHROPIC_API_KEY", "ambient-key-must-not-be-used")
    serve([oauth(1, "anthropic", "sk-ant-oat01-broker", "email:me@example.com")])
    cfg = %{"anthropic" => %{auth_source: "omp_broker"}}

    assert Credentials.resolve_provider_api_key(:anthropic, cfg) == "sk-ant-oat01-broker"
    assert Credentials.provider_has_credentials?(:anthropic, cfg)
    assert Credentials.build_get_api_key(cfg).(:anthropic) == "sk-ant-oat01-broker"

    OmpAuthBroker.invalidate_all()

    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "unauthorized"})
    end)

    assert Credentials.resolve_provider_api_key(:anthropic, cfg) == ""
    refute Credentials.provider_has_credentials?(:anthropic, cfg)
  end

  test "credentials are shaped per Lemon provider and selected by omp_provider/omp_account" do
    serve([
      oauth(2, "google-gemini-cli", "ya29.gemini", "email:me@example.com", %{
        "projectId" => "proj-1"
      }),
      oauth(3, "xai-oauth", "xai-a", "account:a"),
      oauth(4, "xai-oauth", "xai-b", "account:b")
    ])

    gemini =
      Credentials.resolve_provider_api_key(:google_gemini_cli, %{auth_source: "omp_broker"},
        provider_cfg: true
      )

    assert Jason.decode!(gemini) == %{"token" => "ya29.gemini", "projectId" => "proj-1"}

    custom = %{
      "my-xai" => %{
        auth_source: "omp_broker",
        omp_provider: "xai-oauth",
        omp_account: "account:b"
      }
    }

    assert Credentials.resolve_provider_api_key("my-xai", custom) == "xai-b"

    # Custom providers have no derivable omp id.
    assert Credentials.resolve_provider_api_key("other", %{
             "other" => %{auth_source: "omp_broker"}
           }) ==
             ""
  end

  test "a rejected token adopts a rotated one, else asks the broker for auth recovery" do
    cfg = %{"kimi_coding" => %{auth_source: "omp_broker"}}
    serve([oauth(5, "kimi-code", "token-a", "account:k")])

    # The broker already holds a different token than the rejected one.
    assert {:ok, "token-a"} =
             Credentials.refresh_provider_api_key(cfg, :kimi_coding, "default", "stale-token")

    refute_receive {:broker, "POST", _, _}

    serve([oauth(5, "kimi-code", "token-a", "account:k")], fn 5, "reason=auth-recovery" ->
      oauth(5, "kimi-code", "token-b", "account:k")
    end)

    assert {:ok, "token-b"} =
             Credentials.refresh_provider_api_key(cfg, :kimi_coding, "default", "token-a")

    assert_receive {:broker, "POST", "/v1/credential/5/refresh", "reason=auth-recovery"}

    # A recovery that hands back the rejected token fails rather than reusing it.
    serve([oauth(5, "kimi-code", "token-a", "account:k")], fn 5, _ ->
      oauth(5, "kimi-code", "token-a", "account:k")
    end)

    assert {:error, :refresh_rejected} =
             Credentials.refresh_provider_api_key(cfg, :kimi_coding, "default", "token-a")

    serve([
      %{
        "id" => 6,
        "provider" => "openrouter",
        "identityKey" => nil,
        "credential" => %{"type" => "api_key", "key" => "sk-or"}
      }
    ])

    assert {:error, :not_refreshable} =
             Credentials.refresh_provider_api_key(
               %{"openrouter" => %{auth_source: "omp_broker"}},
               :openrouter,
               "default",
               "sk-or"
             )
  end

  test "every broker account is a ref'd entry, recovery targets that id, and blocks are reported" do
    cfg = %{"kimi_coding" => %{auth_source: "omp_broker"}}
    owner = self()

    accounts = [
      oauth(7, "kimi-code", "token-7", "account:a"),
      oauth(8, "kimi-code", "token-8", "account:b")
    ]

    serve(accounts, fn 8, "reason=auth-recovery" ->
      oauth(8, "kimi-code", "token-8b", "account:b")
    end)

    assert [
             %{ref: "omp_broker:7", api_key: "token-7"},
             %{ref: "omp_broker:8", api_key: "token-8"}
           ] = Credentials.list_provider_api_keys(cfg, :kimi_coding)

    # Recovery refreshes exactly the referenced credential.
    assert {:ok, "token-8b"} =
             Credentials.refresh_provider_api_key(cfg, :kimi_coding, "omp_broker:8", "token-8")

    assert_receive {:broker, "POST", "/v1/credential/8/refresh", "reason=auth-recovery"}
    refute_receive {:broker, "POST", "/v1/credential/7/refresh", _}, 50

    # Rate limits are reported asynchronously with the broker's provider key.
    Req.Test.stub(__MODULE__, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v1/snapshot"} ->
          Req.Test.json(conn, %{
            "generation" => 1,
            "generatedAt" => now_ms(),
            "serverNowMs" => now_ms(),
            "refresher" => %{
              "enabled" => true,
              "intervalMs" => 60_000,
              "skewMs" => 300_000,
              "nextSweepInMs" => 1_000
            },
            "credentials" => Enum.map(accounts, &Map.put_new(&1, "rotatesInMs", nil))
          })

        {"POST", "/v1/credential/" <> _ = path} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(owner, {:broker_block, path, Jason.decode!(body)})
          Req.Test.json(conn, %{"ok" => true})
      end
    end)

    until_ms = now_ms() + 60_000
    assert :ok = Credentials.report_rate_limit(cfg, :kimi_coding, "omp_broker:7", until_ms)

    assert_receive {:broker_block, "/v1/credential/7/block",
                    %{
                      "providerKey" => "kimi-code:oauth",
                      "blockScope" => "",
                      "blockedUntilMs" => ^until_ms
                    }},
                   2_000

    # Non-broker refs never reach the broker.
    assert :ok = Credentials.report_rate_limit(cfg, :kimi_coding, "default", until_ms)
    assert :ok = Credentials.report_rate_limit(%{}, :kimi_coding, "omp_broker:7", until_ms)
    refute_receive {:broker_block, _, _}, 100
  end

  test "the omp_gateway provider falls back to omp's gateway token file" do
    home = Path.join(System.tmp_dir!(), "omp_home_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(home) end)
    File.mkdir_p!(Path.join(home, ".omp/profiles/work"))
    File.write!(Path.join(home, ".omp/auth-gateway.token"), "default-gateway-token\n")
    File.write!(Path.join(home, ".omp/profiles/work/auth-gateway.token"), "work-gateway-token\n")

    System.put_env("HOME", home)

    Enum.each(
      ~w(PI_CONFIG_DIR OMP_PROFILE PI_PROFILE OMP_AUTH_GATEWAY_TOKEN),
      &System.delete_env/1
    )

    assert Credentials.resolve_provider_api_key(:omp_gateway, %{}) == "default-gateway-token"
    assert Credentials.provider_has_credentials?(:omp_gateway, %{})

    System.put_env("OMP_PROFILE", "work")
    assert Credentials.resolve_provider_api_key("omp-gateway", %{}) == "work-gateway-token"

    System.put_env("OMP_AUTH_GATEWAY_TOKEN", "env-gateway-token")
    assert Credentials.resolve_provider_api_key(:omp_gateway, %{}) == "env-gateway-token"
  end
end
