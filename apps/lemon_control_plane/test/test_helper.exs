ExUnit.start()

Code.require_file("support/manifest_stub.ex", __DIR__)

# In umbrella `mix test`, other apps may have started/stopped lemon_gateway,
# lemon_channels, or lemon_control_plane earlier in the same BEAM. Many control
# plane methods assume the runtime services and the control plane's own supervised
# ETS registries are running. Ensure a consistent production baseline here.

Application.put_env(:lemon_gateway, LemonGateway.Config, %{
  enable_telegram: false,
  max_concurrent_runs: 1
})

Application.delete_env(:lemon_gateway, :telegram)

_ = Application.stop(:lemon_channels)
_ = Application.stop(:lemon_router)
_ = Application.stop(:lemon_gateway)

{:ok, _} = Application.ensure_all_started(:lemon_channels)
{:ok, _} = Application.ensure_all_started(:coding_agent)
{:ok, _} = Application.ensure_all_started(:lemon_control_plane)

ExUnit.after_suite(fn _ ->
  _ = Application.stop(:lemon_channels)
  _ = Application.stop(:lemon_router)
  _ = Application.stop(:lemon_gateway)

  {:ok, _} = Application.ensure_all_started(:lemon_channels)
  {:ok, _} = Application.ensure_all_started(:lemon_router)
  {:ok, _} = Application.ensure_all_started(:lemon_gateway)
end)
