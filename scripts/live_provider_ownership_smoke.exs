# Offline actual public Agent/Session lifecycle -> LemonAi -> loopback HTTP.
# MIX_ENV=test mix run --no-compile --no-start scripts/live_provider_ownership_smoke.exs
Code.require_file("support/live_provider_ownership_probe.exs", __DIR__)
alias LemonScripts.LiveProviderOwnershipProbe

root =
  Path.join(System.tmp_dir!(), "live_provider_ownership_#{System.unique_integer([:positive])}")

try do
  LiveProviderOwnershipProbe.sandbox(root, fn ->
    {:ok, _} = Application.ensure_all_started(:coding_agent)

    scenarios = [
      :idle_missing,
      :idle_keyless,
      :agent_missing,
      :agent_keyless,
      :live_fallback,
      :same_provider_headers
    ]

    reports =
      Enum.map(scenarios, fn scenario ->
        report = LiveProviderOwnershipProbe.run(root, scenario)
        IO.puts(Jason.encode!(report))
        report
      end)

    unless Enum.all?(reports, & &1.passed),
      do: raise("public model-switch option ownership violated; see redacted reports")
  end)
after
  File.rm_rf!(root)
end
