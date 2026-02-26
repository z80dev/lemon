ExUnit.start()

# In umbrella `mix test`, other apps may have started/stopped lemon_gateway/lemon_channels
# earlier in the same BEAM. Many control plane methods assume the runtime services are
# running (Store, Outbox, AgentProfiles). Ensure a consistent baseline here.

Application.put_env(:lemon_gateway, LemonGateway.Config, %{
  enable_telegram: false,
  max_concurrent_runs: 1,
  default_engine: "lemon"
})

Application.delete_env(:lemon_gateway, :telegram)

_ = Application.stop(:lemon_channels)
_ = Application.stop(:lemon_router)
_ = Application.stop(:lemon_gateway)

{:ok, _} = Application.ensure_all_started(:lemon_channels)

ExUnit.after_suite(fn _ ->
  _ = Application.stop(:lemon_channels)
  _ = Application.stop(:lemon_router)
  _ = Application.stop(:lemon_gateway)
end)
