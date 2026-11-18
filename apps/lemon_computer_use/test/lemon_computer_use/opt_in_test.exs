defmodule LemonComputerUse.OptInTest do
  # Native computer use is opt-in only: a connected LCU Chrome extension (the
  # browser provider resolving to `lcu`) never starts the bridge or registers
  # the desktop-control tools.
  use ExUnit.Case, async: false

  setup do
    saved_probe = Application.fetch_env(:lemon_core, :browser_provider_lcu_probe)
    saved_env = System.get_env("LEMON_COMPUTER_USE_ENABLED")
    saved_provider = System.get_env("LEMON_BROWSER_PROVIDER")
    parent = self()

    # The resolver picks `lcu` under the default `auto` provider; every probe
    # call is reported to the test.
    Application.put_env(:lemon_core, :browser_provider_lcu_probe, fn ->
      send(parent, :lcu_probed)
      {:ok, :connected}
    end)

    System.delete_env("LEMON_COMPUTER_USE_ENABLED")

    on_exit(fn ->
      case saved_probe do
        {:ok, value} -> Application.put_env(:lemon_core, :browser_provider_lcu_probe, value)
        :error -> Application.delete_env(:lemon_core, :browser_provider_lcu_probe)
      end

      restore("LEMON_COMPUTER_USE_ENABLED", saved_env)
      restore("LEMON_BROWSER_PROVIDER", saved_provider)
      restart_app()
    end)

    :ok
  end

  test "a connected lcu extension does not enable native computer use" do
    restart_app()
    refute LemonComputerUse.Config.enabled?()
    refute LemonComputerUse.enabled?()
  end

  test "with computer use disabled, auto skips lcu and falls back to relay/local" do
    restart_app()
    local = fn provider -> if provider == "local", do: {:ok, :ready}, else: {:error, :no} end

    resolution = LemonCore.BrowserProvider.resolve(provider: "auto", probe: local)
    assert resolution.provider == "local"
    refute resolution.checks["lcu"].available
    assert resolution.checks["lcu"].reason =~ "computer use"
    refute_received :lcu_probed

    # Explicit `lcu` fails closed instead of enabling anything.
    assert LemonCore.BrowserProvider.resolve(provider: "lcu").provider == nil
    refute LemonComputerUse.Config.chrome?()
    refute "--chrome" in LemonComputerUse.Config.command()
  end

  test "boot with the switch unset starts no bridge and registers no tools, even with lcu resolved" do
    restart_app()

    assert Supervisor.which_children(LemonComputerUse.Supervisor) == []
    refute Process.whereis(LemonComputerUse.Server)

    refute Enum.any?(LemonAgent.ToolRegistry.all(), fn {name, _, _} ->
             name in [:cua_js, :cua_js_reset]
           end)

    refute Enum.any?(LemonAgent.ContextRegistry.all(), fn {name, _} -> name == :computer_use end)
    assert LemonComputerUse.status() == %{enabled: false, running: false}
  end

  test "the enablement decision never consults the browser provider and is frozen at boot" do
    restart_app()
    refute_received :lcu_probed

    # Flipping the switch after boot changes nothing until the next boot: the
    # Server child, registration and status all share the boot decision.
    System.put_env("LEMON_COMPUTER_USE_ENABLED", "true")
    refute LemonComputerUse.enabled?()
    assert LemonComputerUse.status() == %{enabled: false, running: false}
    assert LemonComputerUse.Config.enabled?()
    refute_received :lcu_probed
  end

  defp restart_app do
    :ok = Application.stop(:lemon_computer_use)
    {:ok, _} = Application.ensure_all_started(:lemon_computer_use)
  end

  defp restore(name, nil), do: System.delete_env(name)
  defp restore(name, value), do: System.put_env(name, value)
end
