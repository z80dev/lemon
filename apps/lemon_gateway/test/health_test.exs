defmodule LemonGateway.HealthTest do
  use ExUnit.Case, async: false

  import Plug.Test

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
end
