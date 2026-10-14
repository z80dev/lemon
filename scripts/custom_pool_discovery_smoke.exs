# Run from the umbrella root with:
# mix run --no-start scripts/custom_pool_discovery_smoke.exs
# No ExUnit, vendor traffic, persistent user storage or credential output.
Code.require_file("support/custom_pool_discovery_probe.exs", __DIR__)

if Process.whereis(LemonCore.Store) do
  raise "standalone discovery smoke requires --no-start and an isolated BEAM"
end

{:ok, _} = Application.ensure_all_started(:lemon_ai)
{:ok, _} = Application.ensure_all_started(:bandit)
{:ok, store} = LemonCore.Store.start_link(backend: LemonCore.Store.EtsBackend)

home =
  Path.join(System.tmp_dir!(), "custom_pool_discovery_#{System.unique_integer([:positive])}")

File.mkdir_p!(home)

try do
  report = LemonScripts.CustomPoolDiscoveryProbe.run!(home)
  IO.puts(Jason.encode!(Map.put(report, :status, :passed), pretty: true))
after
  GenServer.stop(store)
  File.rm_rf!(home)
end
