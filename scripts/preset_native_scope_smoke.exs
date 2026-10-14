# Run from the umbrella root with:
# MIX_ENV=test mix run --no-compile --no-start scripts/preset_native_scope_smoke.exs
# No ExUnit, paid providers, persistent user storage or credential output.
Code.require_file("support/preset_native_scope_probe.exs", __DIR__)

if Process.whereis(LemonCore.Store) do
  raise "standalone native scope smoke requires --no-start and an isolated BEAM"
end

{:ok, _} = Application.ensure_all_started(:lemon_ai)
{:ok, _} = Application.ensure_all_started(:bandit)
{:ok, store} = LemonCore.Store.start_link(backend: LemonCore.Store.EtsBackend)
home = Path.join(System.tmp_dir!(), "preset_native_scope_#{System.unique_integer([:positive])}")
File.mkdir_p!(home)

try do
  report = LemonScripts.PresetNativeScopeProbe.run!(home)
  IO.puts(Jason.encode!(Map.put(report, :status, :passed), pretty: true))
after
  GenServer.stop(store)
  File.rm_rf!(home)
end
