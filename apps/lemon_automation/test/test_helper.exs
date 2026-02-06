Application.put_env(:lemon_gateway, LemonGateway.Config, %{
  enable_telegram: false,
  max_concurrent_runs: 1,
  default_engine: "lemon"
})

Application.delete_env(:lemon_gateway, :telegram)

# LemonAutomation uses LemonCore.Store, which currently delegates to LemonGateway.Store.
# Ensure the gateway app (and Store) is running for these tests.
_ = Application.stop(:lemon_gateway)
{:ok, _} = Application.ensure_all_started(:lemon_gateway)

ExUnit.start()

ExUnit.after_suite(fn _ ->
  _ = Application.stop(:lemon_channels)
  _ = Application.stop(:lemon_gateway)
end)
