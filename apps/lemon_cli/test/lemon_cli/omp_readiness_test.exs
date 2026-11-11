defmodule LemonCli.OmpReadinessTest do
  use ExUnit.Case, async: false

  alias LemonCore.Doctor.Checks.Providers
  alias LemonCore.Setup.Readiness

  setup do
    dir = Path.join(System.tmp_dir!(), "omp_readiness_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, ".lemon"))
    original = LemonCore.ProviderManagement.service()
    :ok = LemonCore.ProviderManagement.register(LemonCli.Setup.ProviderManagement)

    on_exit(fn ->
      if original,
        do: LemonCore.ProviderManagement.register(original),
        else: Application.delete_env(:lemon_core, :provider_management_service)

      File.rm_rf!(dir)
    end)

    %{dir: dir, path: Path.join(dir, "omp"), config_path: Path.join(dir, ".lemon/config.toml")}
  end

  test "omp-only setup and doctor use external token readiness without a local encrypted login",
       ctx do
    token = jwt()
    script(ctx.path, "printf '%s' '#{token}'")
    write_config(ctx)
    state = Readiness.status(config_path: ctx.config_path)
    assert state.provider.complete
    assert state.secrets.complete
    assert state.secrets.source == :not_required

    check =
      Providers.run(project_dir: ctx.dir) |> Enum.find(&(&1.name == "providers.credentials"))

    assert check.status == :pass
    assert check.message =~ "reuses omp's Kimi Code login"
    refute inspect(check) =~ token
  end

  test "bad omp token fails readiness even with an inline key", ctx do
    script(ctx.path, "printf 'not-jwt'")
    write_config(ctx)
    state = Readiness.status(config_path: ctx.config_path)
    refute state.provider.complete
    refute state.provider.credential_ready

    check =
      Providers.run(project_dir: ctx.dir) |> Enum.find(&(&1.name == "providers.credentials"))

    assert check.status == :fail
    assert check.remediation =~ "/login kimi-code"
  end

  defp write_config(ctx) do
    File.write!(ctx.config_path, """
    [defaults]
    provider = "kimi_coding"
    model = "k3.1-pro"
    [providers.kimi_coding]
    auth_source = "omp"
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
