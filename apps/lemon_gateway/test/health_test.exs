defmodule LemonGateway.HealthTest do
  use ExUnit.Case, async: false

  import Plug.Test

  defmodule XmtpMissingStatusStub do
  end

  defmodule XmtpDisconnectedStub do
    def status do
      {:ok, %{mode: :mock, require_live: true, connected?: false, healthy?: true}}
    end
  end

  defmodule XmtpUnhealthyStub do
    def status do
      {:ok, %{mode: :mock, require_live: true, connected?: true, healthy?: false}}
    end
  end

  defmodule XmtpCrashingStub do
    def status, do: raise("xmtp status crashed")
  end

  setup do
    Application.stop(:lemon_gateway)

    Application.put_env(:lemon_gateway, LemonGateway.Config, %{
      max_concurrent_runs: 1,
      default_engine: "echo",
      enable_telegram: false
    })

    Application.put_env(:lemon_gateway, :engines, [LemonGateway.Engines.Echo])
    Application.put_env(:lemon_gateway, :transports, [])
    Application.put_env(:lemon_gateway, :commands, [])

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    on_exit(fn ->
      Application.stop(:lemon_gateway)
      Application.delete_env(:lemon_gateway, :health_checks)
      Application.delete_env(:lemon_gateway, :xmtp_transport_module)
    end)

    :ok
  end

  test "health endpoint returns 200 when built-in checks pass" do
    conn = conn(:get, "/healthz") |> LemonGateway.Health.Router.call([])

    assert conn.status == 200

    body = Jason.decode!(conn.resp_body)
    assert body["ok"] == true
    assert is_list(body["checks"])
  end

  test "custom health checks are supported and can fail readiness" do
    Application.put_env(:lemon_gateway, :health_checks, [
      {"forced_failure", fn -> {:error, :forced} end}
    ])

    conn = conn(:get, "/healthz") |> LemonGateway.Health.Router.call([])

    assert conn.status == 503

    body = Jason.decode!(conn.resp_body)
    assert body["ok"] == false

    assert Enum.any?(body["checks"], fn check ->
             check["name"] == "forced_failure" and check["ok"] == false
           end)
  end

  test "xmtp readiness check fails health when xmtp is enabled but not live" do
    Application.stop(:lemon_gateway)

    Application.put_env(:lemon_gateway, LemonGateway.Config, %{
      max_concurrent_runs: 1,
      default_engine: "echo",
      enable_telegram: false,
      enable_xmtp: true,
      xmtp: %{
        require_live: true,
        mock_mode: true,
        connect_timeout_ms: 200
      }
    })

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    conn = conn(:get, "/healthz") |> LemonGateway.Health.Router.call([])
    assert conn.status == 503

    body = Jason.decode!(conn.resp_body)

    assert Enum.any?(body["checks"], fn check ->
             check["name"] == "xmtp_transport" and check["ok"] == false
           end)
  end

  test "xmtp readiness check distinguishes missing channel module" do
    restart_gateway_with_xmtp(:"Elixir.LemonGateway.HealthTest.MissingXmtpModule")

    check = xmtp_health_check()

    assert check.ok == false
    assert check.error =~ ":xmtp_module_not_loaded"
  end

  test "xmtp readiness check distinguishes missing status callback" do
    restart_gateway_with_xmtp(XmtpMissingStatusStub)

    check = xmtp_health_check()

    assert check.ok == false
    assert check.error =~ ":xmtp_status_unavailable"
  end

  test "xmtp readiness check distinguishes disconnected and unhealthy transport" do
    restart_gateway_with_xmtp(XmtpDisconnectedStub)

    check = xmtp_health_check()
    assert check.ok == false
    assert check.error =~ ":xmtp_not_connected"

    restart_gateway_with_xmtp(XmtpUnhealthyStub)

    check = xmtp_health_check()
    assert check.ok == false
    assert check.error =~ ":xmtp_unhealthy"
  end

  test "xmtp readiness check reports status callback crashes without raising" do
    restart_gateway_with_xmtp(XmtpCrashingStub)

    check = xmtp_health_check()

    assert check.ok == false
    assert check.error =~ "xmtp status crashed"
  end

  defp restart_gateway_with_xmtp(transport_module) do
    Application.stop(:lemon_gateway)

    Application.put_env(:lemon_gateway, :xmtp_transport_module, transport_module)

    Application.put_env(:lemon_gateway, LemonGateway.Config, %{
      max_concurrent_runs: 1,
      default_engine: "echo",
      enable_telegram: false,
      enable_xmtp: true
    })

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)
  end

  defp xmtp_health_check do
    LemonGateway.Health.status()
    |> Map.fetch!(:checks)
    |> Enum.find(&(&1.name == "xmtp_transport"))
  end
end
