defmodule LemonCore.Doctor.ProviderNamesRedactionTest do
  @moduledoc """
  Custom provider names are private. Doctor compares and counts on raw
  normalized names, and shows only `ProviderIdentity.public_name/1`
  (`custom:<hash>`) in rendered output and support bundles.
  """
  use ExUnit.Case, async: false

  alias LemonCore.CredentialReadiness
  alias LemonCore.Doctor
  alias LemonCore.Doctor.{Checks, Report, SupportBundle}

  @private "customer.private.example"
  @fallback "fallback.private.example"

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "lemon_provider_names_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(tmp_dir, ".lemon"))
    previous_paths = Application.get_env(:lemon_core, :paths)
    global_config = Path.join(tmp_dir, "global.toml")
    Application.put_env(:lemon_core, :paths, global_config: global_config)
    LemonCore.ConfigCache.clear()

    on_exit(fn ->
      if previous_paths,
        do: Application.put_env(:lemon_core, :paths, previous_paths),
        else: Application.delete_env(:lemon_core, :paths)

      LemonCore.ConfigCache.clear()
      File.rm_rf!(tmp_dir)
    end)

    %{tmp_dir: tmp_dir, global_config: global_config}
  end

  defp write_config(%{global_config: path}, toml) do
    File.write!(path, toml)
    LemonCore.ConfigCache.clear()
  end

  defp routed_config(ctx) do
    write_config(ctx, """
    [defaults]
    provider = "#{@private}"
    model = "#{@private}:model"

    [providers."#{@private}"]
    api_key_secret = "missing_private_secret_name"

    [providers."#{@fallback}"]
    api_key = "sk-inline-fallback-0123456789"

    [runtime.provider_routing]
    fallback_providers = ["#{@fallback}"]
    default_pool = "primary"

    [runtime.provider_routing.credential_pools.primary]
    providers = ["#{@private}", "#{@fallback}"]
    strategy = "priority"
    """)
  end

  test "the bundle's provider section counts on raw names and shows only public ones", ctx do
    routed_config(ctx)
    status = SupportBundle.collect(project_dir: ctx.tmp_dir)["provider_diagnostics.json"]

    private = LemonCore.ProviderIdentity.public_name(@private)
    fallback = LemonCore.ProviderIdentity.public_name(@fallback)
    ready = Map.new(status["providers"], &{&1["provider"], &1["credential_ready"]})
    assert ready[fallback] == true
    assert ready[private] == false

    assert [pool] = status["routing"]["credential_pools"]
    assert pool["providers"] == [private, fallback]
    # One secret reference on the private provider; the fallback is inline.
    assert pool["credential_reference_count"] == 1
    refute inspect(status) =~ "private.example"
    assert status["default_provider"] == private
  end

  test "checks compare raw names and render only public names", ctx do
    routed_config(ctx)
    checks = Checks.Providers.run(project_dir: ctx.tmp_dir)

    default = Enum.find(checks, &(&1.name == "providers.default"))
    assert default.message =~ LemonCore.ProviderIdentity.public_name(@private)

    # The custom fallback is credential-ready; finding that needs raw-name lookups.
    routing = Enum.find(checks, &(&1.name == "providers.routing"))

    assert routing.message =~
             "ready provider(s): " <> LemonCore.ProviderIdentity.public_name(@fallback)

    refute inspect(checks) =~ "private.example"
  end

  test "a custom omp_broker provider's credential check agrees with its status", ctx do
    write_config(ctx, """
    [defaults]
    provider = "#{@private}"
    model = "#{@private}:model"

    [providers."#{@private}"]
    auth_source = "omp_broker"
    omp_provider = "anthropic"
    """)

    ready? = CredentialReadiness.ready?(@private, LemonCore.Config.load(ctx.tmp_dir).providers)

    credentials =
      ctx.tmp_dir
      |> then(&Checks.Providers.run(project_dir: &1))
      |> Enum.find(&(&1.name == "providers.credentials"))

    assert credentials.status == if(ready?, do: :pass, else: :fail)
    assert credentials.message =~ "omp"
    refute inspect(credentials) =~ "private.example"
  end

  test "config validator messages show the public provider name", ctx do
    write_config(ctx, """
    [providers."#{@private}"]
    omp_account = "someone"
    """)

    check =
      Checks.Config.run(project_dir: ctx.tmp_dir)
      |> Enum.find(&(&1.name == "config.global_valid"))

    assert check.status == :fail
    assert check.message =~ "custom:"
    refute check.message =~ "private.example"
  end

  test "doctor output and bundle entries never carry the custom name", ctx do
    routed_config(ctx)
    today_key = Date.to_iso8601(Date.utc_today())
    previous = LemonCore.UsageStore.get_summary(:current)

    on_exit(fn ->
      if previous,
        do: LemonCore.UsageStore.put_summary(:current, previous),
        else: LemonCore.Store.delete(:usage_data, :current)
    end)

    LemonCore.UsageStore.put_summary(:current, %{
      date: today_key,
      total_cost: 0.1,
      total_requests: 1,
      breakdown: %{@private => 0.1},
      requests: %{@private => 1},
      tokens: %{@private => %{input: 1, output: 1}}
    })

    report = Doctor.report(runtime: :absent, project_dir: ctx.tmp_dir)
    refute Report.to_json(report) =~ "private.example"

    bundle_path = Path.join(ctx.tmp_dir, "bundle.zip")

    assert {:ok, _} =
             SupportBundle.write(report, bundle_path: bundle_path, project_dir: ctx.tmp_dir)

    assert {:ok, entries} = :zip.extract(String.to_charlist(bundle_path), [:memory])

    for {name, content} <- entries do
      refute IO.iodata_to_binary(content) =~ "private.example", "#{name} leaks a custom provider"
    end

    usage = entries |> Enum.find(&(elem(&1, 0) == ~c"usage_diagnostics.json")) |> elem(1)
    assert IO.iodata_to_binary(usage) =~ LemonCore.ProviderIdentity.public_name(@private)
  end
end
