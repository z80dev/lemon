defmodule LemonControlPlane.Doctor.Checks.ListenersTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.Doctor.Checks.Listeners

  # Every listener is supplied explicitly so the suite never inspects a real
  # socket, a real epmd or this VM's distribution settings.
  @loopback [
    control_plane_ip: {127, 0, 0, 1},
    control_plane_port: 4040,
    node_gateway_ip: {127, 0, 0, 1},
    node_gateway_port: 4044,
    web_configured: true,
    web_ip: {127, 0, 0, 1},
    web_port: 4080,
    sim_ui_configured: true,
    sim_ui_ip: {127, 0, 0, 1},
    sim_ui_port: 4090,
    a2a_enabled: false,
    epmd_status: :loopback,
    distribution_status: :not_active
  ]

  defp check(overrides, name) do
    @loopback
    |> Keyword.merge(overrides)
    |> Listeners.run()
    |> Enum.find(&(&1.name == name))
  end

  describe "configured HTTP listeners" do
    test "a loopback release default passes every listener" do
      checks = Listeners.run(@loopback)

      assert Enum.map(checks, & &1.name) == [
               "listeners.control_plane",
               "listeners.node_gateway",
               "listeners.web",
               "listeners.sim_ui",
               "listeners.a2a",
               "listeners.epmd",
               "listeners.distribution"
             ]

      for check <- checks, check.name not in ["listeners.a2a", "listeners.distribution"] do
        assert check.status == :pass
      end

      assert check([], "listeners.control_plane").message ==
               "Control plane is configured to bind loopback (127.0.0.1:4040)."

      assert check([], "listeners.node_gateway").message ==
               "Node gateway is configured to bind loopback (127.0.0.1:4044)."

      assert check([], "listeners.web").message =~ "127.0.0.1:4080"
      assert check([], "listeners.sim_ui").message =~ "127.0.0.1:4090"
    end

    test "a non-loopback bind is reported as configured, never as proven exposure" do
      control = check([control_plane_ip: {0, 0, 0, 0}], "listeners.control_plane")

      assert control.status == :warn

      assert control.message ==
               "Control plane is configured to bind 0.0.0.0:4040; ensure TLS or an encrypted overlay protects this bind."

      assert control.remediation =~ "Bind to loopback (127.0.0.1)"

      gateway = check([node_gateway_ip: "0.0.0.0"], "listeners.node_gateway")
      assert gateway.status == :warn
      assert gateway.message =~ "Node gateway is configured to bind 0.0.0.0:4044"

      web = check([web_ip: {192, 168, 1, 10}], "listeners.web")
      assert web.status == :warn
      assert web.message =~ "Web UI is configured to bind 192.168.1.10:4080"

      sim = check([sim_ui_ip: "0.0.0.0"], "listeners.sim_ui")
      assert sim.status == :warn
      assert sim.message =~ "Sim UI is configured to bind 0.0.0.0:4090"
    end

    test "a node gateway disabled with port 0 binds nothing" do
      disabled =
        check([node_gateway_ip: {0, 0, 0, 0}, node_gateway_port: 0], "listeners.node_gateway")

      assert disabled.status == :pass
      assert disabled.message == "Node gateway is disabled (port 0)."
    end

    test "unconfigured optional listeners are skipped" do
      assert check([web_configured: false], "listeners.web").status == :skip
      assert check([sim_ui_configured: false], "listeners.sim_ui").status == :skip
      assert check([], "listeners.a2a").status == :skip
      assert check([], "listeners.a2a").message =~ "disabled"
    end

    test "an enabled A2A listener is checked like the other listeners" do
      passing =
        check([a2a_enabled: true, a2a_ip: {127, 0, 0, 1}, a2a_port: 9901], "listeners.a2a")

      assert passing.status == :pass
      assert passing.message =~ "A2A listener is configured to bind loopback (127.0.0.1:9901)."

      warning = check([a2a_enabled: true, a2a_ip: {0, 0, 0, 0}, a2a_port: 9901], "listeners.a2a")
      assert warning.status == :warn
      assert warning.message =~ "ensure TLS or an encrypted overlay protects this bind"
    end
  end

  describe "epmd" do
    test "a wildcard bind names the stale instance and the recovery steps" do
      stale = check([epmd_status: :wildcard], "listeners.epmd")

      assert stale.status == :warn
      assert stale.message =~ "epmd listener is bound to all interfaces (*:4369)"
      assert stale.message =~ "stale instance from before the upgrade"
      assert stale.remediation =~ "Stop Lemon with `lemon stop`"
      assert stale.remediation =~ "epmd -kill"
      assert stale.remediation =~ "restart your computer"
    end

    test "a specific non-loopback bind warns with the observed address" do
      exposed = check([epmd_status: {:non_loopback, "192.168.1.10"}], "listeners.epmd")

      assert exposed.status == :warn
      assert exposed.message =~ "epmd listener is bound to 192.168.1.10:4369"
      assert exposed.remediation =~ "epmd -kill"
    end

    test "loopback and absent epmd pass" do
      assert check([epmd_status: :loopback], "listeners.epmd").message =~
               "epmd listener is bound to loopback (127.0.0.1:4369)."

      absent = check([epmd_status: :not_running], "listeners.epmd")
      assert absent.status == :pass
      assert absent.message =~ "epmd is not running"
    end

    test "an unclassifiable socket warns instead of passing as safe" do
      unknown = check([epmd_status: :unknown], "listeners.epmd")

      assert unknown.status == :warn
      assert unknown.message =~ "bind address could not be determined"
      assert unknown.remediation =~ "epmd -kill"
    end
  end

  describe "distribution" do
    test "a configured loopback interface passes" do
      configured =
        check([distribution_status: {:configured, {127, 0, 0, 1}}], "listeners.distribution")

      assert configured.status == :pass

      assert configured.message ==
               "Erlang distribution is configured to bind 127.0.0.1 (inet_dist_use_interface)."
    end

    test "a configured non-loopback interface warns as configured" do
      configured =
        check([distribution_status: {:configured, {0, 0, 0, 0}}], "listeners.distribution")

      assert configured.status == :warn

      assert configured.message ==
               "Erlang distribution is configured to bind 0.0.0.0; ensure TLS or an encrypted overlay protects this bind."

      assert configured.remediation =~ "inet_dist_use_interface {127,0,0,1}"
    end

    test "an inactive node is skipped" do
      inactive = check([distribution_status: :not_active], "listeners.distribution")

      assert inactive.status == :skip
      assert inactive.message =~ "not active"
    end

    test "an active node without a configured interface reports unknown, never loopback" do
      unknown = check([distribution_status: :unknown], "listeners.distribution")

      assert unknown.status == :warn
      assert unknown.message =~ "listener address is unknown"
      refute unknown.message =~ "loopback"
      assert unknown.remediation =~ "inet_dist_use_interface {127,0,0,1}"
    end
  end
end
