defmodule LemonCli.OmpBrokerReadinessTest do
  use ExUnit.Case, async: false

  alias LemonAgent.ModelRuntime.OmpAuthBroker
  alias LemonCore.Doctor.Checks.Providers
  alias LemonCore.Setup.Readiness

  @access "sk-ant-oat01-broker-readiness"

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_ai)

    dir =
      Path.join(System.tmp_dir!(), "omp_broker_readiness_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(dir, ".lemon"))
    previous_paths = Application.fetch_env(:lemon_core, :paths)
    Application.put_env(:lemon_core, :paths, global_config: Path.join(dir, "operator.toml"))
    original = LemonCore.ProviderManagement.service()
    :ok = LemonCore.ProviderManagement.register(LemonCli.Setup.ProviderManagement)
    env = Map.new(~w(OMP_AUTH_BROKER_URL OMP_AUTH_BROKER_TOKEN), &{&1, System.get_env(&1)})
    System.put_env("OMP_AUTH_BROKER_URL", "http://broker.test:8765")
    System.put_env("OMP_AUTH_BROKER_TOKEN", "broker-bearer")
    previous = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})
    OmpAuthBroker.invalidate_all()

    on_exit(fn ->
      case previous_paths do
        {:ok, value} -> Application.put_env(:lemon_core, :paths, value)
        :error -> Application.delete_env(:lemon_core, :paths)
      end

      if original,
        do: LemonCore.ProviderManagement.register(original),
        else: Application.delete_env(:lemon_core, :provider_management_service)

      Enum.each(env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      Req.default_options(previous)
      Req.Test.set_req_test_to_private(%{})
      OmpAuthBroker.invalidate_all()
      File.rm_rf!(dir)
    end)

    config_path = LemonCore.Paths.global_config()

    File.write!(config_path, """
    [defaults]
    provider = "anthropic"
    model = "claude-haiku-4-5"
    [providers.anthropic]
    auth_source = "omp_broker"
    """)

    %{dir: dir, config_path: config_path}
  end

  test "a broker-backed default provider is ready without a local secret store", ctx do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "generation" => 1,
        "generatedAt" => System.system_time(:millisecond),
        "serverNowMs" => System.system_time(:millisecond),
        "refresher" => %{
          "enabled" => true,
          "intervalMs" => 60_000,
          "skewMs" => 300_000,
          "nextSweepInMs" => 1_000
        },
        "credentials" => [
          %{
            "id" => 1,
            "provider" => "anthropic",
            "identityKey" => "email:me@example.com",
            "rotatesInMs" => nil,
            "credential" => %{
              "type" => "oauth",
              "access" => @access,
              "refresh" => "__remote__",
              "expires" => System.system_time(:millisecond) + 3_600_000
            }
          }
        ]
      })
    end)

    state = Readiness.status(config_path: ctx.config_path)
    assert state.provider.complete
    assert state.secrets.source == :not_required

    snapshot =
      LemonAgent.ModelRuntime.ProviderStatus.snapshot(%{
        "projectDir" => ctx.dir,
        "provider" => "anthropic"
      })

    provider = Enum.find(snapshot["providers"], &(&1["provider"] == "anthropic"))
    assert provider["credentialReady"]
    assert provider["config"]["authSource"] == "omp_broker"
    refute inspect(snapshot) =~ @access

    check =
      Providers.run(project_dir: ctx.dir) |> Enum.find(&(&1.name == "providers.credentials"))

    assert check.status == :pass
    assert check.message =~ "omp_broker"
    refute inspect(check) =~ @access
  end

  test "offline readiness never contacts the broker; without a broker token it is not ready",
       ctx do
    Req.Test.stub(__MODULE__, fn _conn -> flunk("offline readiness contacted the broker") end)
    previous_config_dir = System.get_env("PI_CONFIG_DIR")
    System.put_env("PI_CONFIG_DIR", Path.join(ctx.dir, "no-omp"))
    System.delete_env("OMP_AUTH_BROKER_TOKEN")

    on_exit(fn ->
      if previous_config_dir,
        do: System.put_env("PI_CONFIG_DIR", previous_config_dir),
        else: System.delete_env("PI_CONFIG_DIR")
    end)

    state = Readiness.status(config_path: ctx.config_path)
    refute state.provider.complete

    check =
      Providers.run(project_dir: ctx.dir) |> Enum.find(&(&1.name == "providers.credentials"))

    assert check.status == :fail
    assert check.remediation =~ "omp auth-broker"
  end

  test "live resolution fails closed on an unauthorized broker", ctx do
    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "unauthorized"})
    end)

    providers = LemonCore.Config.load(ctx.dir, cache: false).providers

    refute LemonAgent.ModelRuntime.Credentials.provider_has_credentials?(
             "anthropic",
             providers,
             mode: :resolve
           )

    readiness =
      LemonCli.Setup.ModelReadiness.check(
        config_path: ctx.config_path,
        cwd: ctx.dir,
        verifier: fn _input -> flunk("no model request after a broker refusal") end
      )

    assert readiness.state == :action_required
  end
end
