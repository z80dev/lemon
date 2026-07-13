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
    conn = get(conn, "/admin")
    assert response(conn, 401) == "Unauthorized"
  end

  test "admin dashboard exchanges a query token and strips it from the URL", %{conn: conn} do
    conn = get(conn, "/admin?token=test-sim-ui-token")
    assert redirected_to(conn, 303) == "/admin"

    conn = conn |> recycle() |> get("/admin")
    assert html_response(conn, 200) =~ "LemonSim"
  end

  test "public watch route stays accessible without a token", %{conn: conn} do
    conn = get(conn, "/watch/nonexistent_public_sim")
    assert html_response(conn, 200) =~ "Simulation Not Found"
  end

  test "health check stays public and is never cached", %{conn: conn} do
    conn = get(conn, "/healthz")
    assert response(conn, 200) == "ok"
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "browser responses set a restrictive content security policy", %{conn: conn} do
    conn = get(conn, "/")
    [csp] = get_resp_header(conn, "content-security-policy")

    assert csp =~ "default-src 'self'"
    assert csp =~ "object-src 'none'"

    assert get_resp_header(conn, "permissions-policy") == [
             "camera=(), microphone=(), geolocation=(), payment=()"
           ]
  end

  test "hosted browser surfaces are private and never cached", %{conn: conn} do
    conn = get(conn, "/play")
    assert html_response(conn, 200) =~ "Host a night of"
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(conn, "pragma") == ["no-cache"]
  end

  test "readiness check verifies supervised services and store connectivity", %{conn: conn} do
    conn = get(conn, "/readyz")
    body = json_response(conn, 200)

    assert body["ok"]
    assert body["status"] == "ready"

    assert body["checks"] == %{
             "arenas" => "ok",
             "hosted_games" => "ok",
             "sim_manager" => "ok",
             "store" => "ok"
           }

    assert body["build"]["version"]
    assert body["simulations"]["active_runners"] >= 0
    assert body["simulations"]["max_concurrent_runners"] >= 1
    assert body["simulations"]["max_stored_simulations"] >= 1
    assert body["simulations"]["queued_recoveries"] >= 0
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "runtime metrics are admin-only and omit room credentials", %{conn: conn} do
    assert conn |> get("/api/admin/metrics") |> response(401) == "Unauthorized"

    body =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer test-sim-ui-token")
      |> get("/api/admin/metrics")
      |> json_response(200)

    assert body["hosted_werewolf"]["status"] == "ok"
    assert is_map(body["hosted_rooms"])
    assert body["hosted_runtime"]["ai_tasks_limit"] >= 1
    assert body["hosted_runtime"]["ai_tasks_active"] >= 0
    assert is_map(body["simulations"])
    assert is_map(body["arenas"])
    refute inspect(body) =~ "host_token"
    refute inspect(body) =~ "player_token"
  end
end
