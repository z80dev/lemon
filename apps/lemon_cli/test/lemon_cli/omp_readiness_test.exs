defmodule LemonCli.OmpReadinessTest do
  use ExUnit.Case, async: false

  alias LemonCore.Doctor.Checks.Providers
  alias LemonCore.Setup.Readiness

  setup do
    dir = Path.join(System.tmp_dir!(), "omp_readiness_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, ".lemon"))
    previous_paths = Application.fetch_env(:lemon_core, :paths)
    Application.put_env(:lemon_core, :paths, global_config: Path.join(dir, "operator.toml"))
    original = LemonCore.ProviderManagement.service()
    :ok = LemonCore.ProviderManagement.register(LemonCli.Setup.ProviderManagement)

    on_exit(fn ->
      case previous_paths do
        {:ok, value} -> Application.put_env(:lemon_core, :paths, value)
        :error -> Application.delete_env(:lemon_core, :paths)
      end

      if original,
        do: LemonCore.ProviderManagement.register(original),
        else: Application.delete_env(:lemon_core, :provider_management_service)

      File.rm_rf!(dir)
    end)

    %{dir: dir, path: Path.join(dir, "omp"), config_path: LemonCore.Paths.global_config()}
  end

  test "mixed-case omp setup and doctor use external token readiness without a local encrypted login",
       ctx do
    token = jwt()
    script(ctx.path, "printf '%s' '#{token}'")
    write_config(ctx)
    state = Readiness.status(config_path: ctx.config_path)
    assert state.provider.complete
    assert state.secrets.complete
    assert state.secrets.source == :not_required

    snapshot =
      LemonAgent.ModelRuntime.ProviderStatus.snapshot(%{
        "projectDir" => ctx.dir,
        "provider" => "kimi_coding"
      })

    provider = Enum.find(snapshot["providers"], &(&1["provider"] == "kimi_coding"))
    assert provider["credentialReady"]
    assert provider["config"]["authSource"] == "omp"

    check =
      Providers.run(project_dir: ctx.dir) |> Enum.find(&(&1.name == "providers.credentials"))

    assert check.status == :pass
    assert check.message =~ "reuses omp's Kimi Code login"
    refute inspect(check) =~ token
  end

  test "offline readiness is presence-only: a missing omp is not ready, an inline key never substitutes",
       ctx do
    write_config(ctx)
    refute File.exists?(ctx.path)
    state = Readiness.status(config_path: ctx.config_path)
    refute state.provider.complete
    refute state.provider.credential_ready

    check =
      Providers.run(project_dir: ctx.dir) |> Enum.find(&(&1.name == "providers.credentials"))

    assert check.status == :fail
    assert check.remediation =~ "/login kimi-code"

    # An installed omp is present offline without being run; its token is
    # judged only by the live check below.
    script(ctx.path, "touch #{Jason.encode!(Path.join(ctx.dir, "omp-ran"))}; printf 'not-jwt'")
    assert Readiness.status(config_path: ctx.config_path).provider.credential_ready
    refute File.exists?(Path.join(ctx.dir, "omp-ran"))
  end

  test "live resolution rejects a bad omp token even with an inline key", ctx do
    script(ctx.path, "printf 'not-jwt'")
    write_config(ctx)
    providers = LemonCore.Config.load(ctx.dir, cache: false).providers

    refute LemonAgent.ModelRuntime.Credentials.provider_has_credentials?(
             "kimi_coding",
             providers,
             mode: :resolve
           )

    readiness =
      LemonCli.Setup.ModelReadiness.check(
        config_path: ctx.config_path,
        cwd: ctx.dir,
        provider: "kimi_coding"
      )

    assert readiness.state == :action_required
    assert readiness.reason == :credential_missing
  end

  defp write_config(ctx) do
    File.write!(ctx.config_path, """
    [defaults]
    provider = "kimi_coding"
    model = "k3.1-pro"
    [providers.kimi_coding]
    auth_source = " OMP "
    omp_path = #{Jason.encode!(ctx.path)}
    api_key = "ignored-inline"
    """)
  end

  defp jwt do
    claims = Jason.encode!(%{"exp" => System.system_time(:second) + 3600})
    "eyJhbGciOiJIUzI1NiJ9." <> Base.url_encode64(claims, padding: false) <> ".signature"
  end

  defp script(path, body) do
    File.write!(path, "#!/bin/sh\nset -eu\n" <> body <> "\n")
    File.chmod!(path, 0o700)
  end
end
