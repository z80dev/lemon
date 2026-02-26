defmodule LemonRouter.HealthTest do
  use ExUnit.Case, async: false

  import Plug.Test

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_router)

    on_exit(fn ->
      Application.delete_env(:lemon_router, :health_checks)
    end)

    :ok
  end

  test "health endpoint returns 200 when checks pass" do
    conn = conn(:get, "/healthz") |> LemonRouter.Health.Router.call([])

    assert conn.status == 200

    body = Jason.decode!(conn.resp_body)
    assert body["ok"] == true
    assert is_list(body["checks"])
  end

  test "custom health check can mark router unhealthy" do
    Application.put_env(:lemon_router, :health_checks, [
      {"forced_failure", fn -> {:error, :forced} end}
    ])

    conn = conn(:get, "/healthz") |> LemonRouter.Health.Router.call([])

    assert conn.status == 503

    body = Jason.decode!(conn.resp_body)
    assert body["ok"] == false

    assert Enum.any?(body["checks"], fn check ->
             check["name"] == "forced_failure" and check["ok"] == false
           end)
  end
end
