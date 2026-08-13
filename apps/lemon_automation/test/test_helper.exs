Application.put_env(:lemon_gateway, LemonGateway.Config, %{
  enable_telegram: false,
  max_concurrent_runs: 1,
  default_engine: "lemon"
})

Application.delete_env(:lemon_gateway, :telegram)

# Ensure runtime dependencies are started for automation tests.
_ = Application.stop(:lemon_gateway)
{:ok, _} = Application.ensure_all_started(:lemon_gateway)

# Cron dispatch preflight probes real provider credentials; unit suites inject
# their own preflight/stubs explicitly.
Application.put_env(:lemon_automation, :cron_preflight, enabled: false)
Application.put_env(:lemon_automation, :cron_drift_guard, enabled: false)

ExUnit.start()

ExUnit.after_suite(fn _ ->
  _ = Application.stop(:lemon_channels)
  _ = Application.stop(:lemon_gateway)

  {:ok, _} = Application.ensure_all_started(:lemon_channels)
  {:ok, _} = Application.ensure_all_started(:lemon_gateway)
end)
