defmodule LemonSimUi.AccessControlTest do
  use LemonSimUi.ConnCase

  setup do
    original = Application.get_env(:lemon_sim_ui, :access_token)
    Application.put_env(:lemon_sim_ui, :access_token, "test-sim-ui-token")

    on_exit(fn ->
      Application.put_env(:lemon_sim_ui, :access_token, original)
    end)

    :ok
  end

  test "admin dashboard requires a token", %{conn: conn} do
    conn = get(conn, "/")
    assert response(conn, 401) == "Unauthorized"
  end

  test "admin dashboard accepts token via query string", %{conn: conn} do
    conn = get(conn, "/?token=test-sim-ui-token")
    assert html_response(conn, 200) =~ "LemonSim"
  end

  test "public watch route stays accessible without a token", %{conn: conn} do
    conn = get(conn, "/watch/nonexistent_public_sim")
    assert html_response(conn, 200) =~ "Simulation Not Found"
  end

  test "health check stays public", %{conn: conn} do
    conn = get(conn, "/healthz")
    assert response(conn, 200) == "ok"
  end
end
