#
# In umbrella `mix test`, applications are not guaranteed to be started for each
# child app. LemonRouter tests expect Registries and core runtime services to be
# running. Establish a consistent baseline here.
#

Application.put_env(:lemon_gateway, LemonGateway.Config, %{
  enable_telegram: false,
  max_concurrent_runs: 1,
  default_engine: "lemon"
})

Application.put_env(:lemon_gateway, :engines, [
  LemonGateway.Engines.Lemon,
  LemonGateway.Engines.Echo,
  LemonGateway.Engines.Codex,
  LemonGateway.Engines.Claude,
  LemonGateway.Engines.Opencode,
  LemonGateway.Engines.Pi
])

Application.delete_env(:lemon_gateway, :telegram)

_ = Application.stop(:lemon_channels)
_ = Application.stop(:coding_agent)
_ = Application.stop(:lemon_router)
_ = Application.stop(:lemon_gateway)

{:ok, _} = Application.ensure_all_started(:lemon_router)

ExUnit.start()

ExUnit.after_suite(fn _ ->
  _ = Application.stop(:lemon_channels)
  _ = Application.stop(:coding_agent)
  _ = Application.stop(:lemon_router)
  _ = Application.stop(:lemon_gateway)

  Application.delete_env(:lemon_gateway, :engines)
end)
