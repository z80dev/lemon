defmodule LemonSimUi.AccessControlTest do
  use LemonSimUi.ConnCase

  @access_token "test-sim-ui-token-that-is-long-enough"

  setup do
    original = Application.get_env(:lemon_sim_ui, :access_token)
    Application.put_env(:lemon_sim_ui, :access_token, @access_token)

    on_exit(fn ->
      Application.put_env(:lemon_sim_ui, :access_token, original)
    end)

    :ok
  end

  test "admin dashboard redirects unauthenticated browsers to a no-store login", %{conn: conn} do
    conn = get(conn, "/admin")
    assert redirected_to(conn, 303) == "/admin/login"
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
  end

  test "admin login exchanges a form-body token for an expiring session", %{conn: conn} do
    conn = login(conn)
    assert redirected_to(conn, 302) == "/admin"

    marker = get_session(conn, :lemon_sim_ui_auth)
    assert marker["version"] == 1
    assert is_integer(marker["issued_at"])
    refute inspect(marker) =~ @access_token

    conn = conn |> recycle() |> get("/admin")
    assert html_response(conn, 200) =~ "Werewolf Control Room"
  end

  test "admin login requires a valid CSRF token", %{conn: conn} do
    conn = %{conn | private: Map.delete(conn.private, :plug_skip_csrf_protection)}

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      post(conn, "/admin/login", %{"token" => @access_token})
    end
  end

  test "admin login returns to the originally requested simulation", %{conn: conn} do
    conn = get(conn, "/admin/sims/missing-sim")
    assert redirected_to(conn, 303) == "/admin/login"

    conn = login(conn)
    assert redirected_to(conn, 302) == "/admin/sims/missing-sim"
  end

  test "query tokens are not accepted", %{conn: conn} do
    conn = get(conn, "/admin?token=#{@access_token}")
    assert redirected_to(conn, 303) == "/admin/login"

    conn = conn |> recycle() |> get("/admin")
    assert redirected_to(conn, 303) == "/admin/login"
  end

  test "invalid login fails generically and clears admin authentication", %{conn: conn} do
    conn = login(conn, "definitely-not-the-key")
    body = html_response(conn, 401)

    assert body =~ "That access key was not accepted"
    refute body =~ "definitely-not-the-key"

    conn = conn |> recycle() |> get("/admin")
    assert redirected_to(conn, 303) == "/admin/login"
  end

  test "admin surfaces fail closed when authentication is not configured", %{conn: conn} do
    original_allow = Application.get_env(:lemon_sim_ui, :allow_insecure_admin)
    Application.delete_env(:lemon_sim_ui, :access_token)
    Application.put_env(:lemon_sim_ui, :allow_insecure_admin, false)

    on_exit(fn ->
      Application.put_env(:lemon_sim_ui, :allow_insecure_admin, original_allow)
    end)

    conn = get(conn, "/admin")
    assert redirected_to(conn, 303) == "/admin/login"

    conn = conn |> recycle() |> get("/admin/login")
    assert html_response(conn, 200) =~ "Admin authentication is not configured"

    assert build_conn() |> get("/api/admin/metrics") |> response(401) == "Unauthorized"
  end

  test "expired admin sessions are rejected", %{conn: conn} do
    conn = login(conn)
    marker = get_session(conn, :lemon_sim_ui_auth)
    expired_marker = Map.put(marker, "issued_at", 0)

    conn =
      build_conn()
      |> init_test_session(%{lemon_sim_ui_auth: expired_marker})
      |> get("/admin")

    assert redirected_to(conn, 303) == "/admin/login"
  end

  test "rotating the access token invalidates existing sessions", %{conn: conn} do
    conn = login(conn)
    Application.put_env(:lemon_sim_ui, :access_token, String.duplicate("r", 32))

    conn = conn |> recycle() |> get("/admin")
    assert redirected_to(conn, 303) == "/admin/login"
  end

  test "logout removes the admin session", %{conn: conn} do
    conn = login(conn)
    admin_conn = conn |> recycle() |> get("/admin")
    admin_html = html_response(admin_conn, 200)
    assert admin_html =~ ~s(action="/admin/logout")
    assert admin_html =~ ~s(name="_csrf_token")
    csrf_token = extract_csrf_token(admin_html)

    conn =
      admin_conn
      |> recycle()
      |> post("/admin/logout", %{"_csrf_token" => csrf_token})

    assert redirected_to(conn, 302) == "/admin/login"

    conn = conn |> recycle() |> get("/admin")
    assert redirected_to(conn, 303) == "/admin/login"
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
      |> put_req_header("authorization", "Bearer #{@access_token}")
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

  test "an authenticated browser cookie does not authorize the admin API", %{conn: conn} do
    conn = login(conn)

    assert conn
           |> recycle()
           |> get("/api/admin/metrics")
           |> response(401) == "Unauthorized"
  end

  defp login(conn, token \\ @access_token) do
    conn = if conn.state == :unset, do: conn, else: recycle(conn)
    login_conn = get(conn, "/admin/login")
    csrf_token = extract_csrf_token(html_response(login_conn, 200))

    login_conn
    |> recycle()
    |> post("/admin/login", %{"_csrf_token" => csrf_token, "token" => token})
  end

  defp extract_csrf_token(html) do
    case Regex.run(~r/name="_csrf_token"[^>]*value="([^"]+)"/, html) do
      [_, token] ->
        token

      nil ->
        [_, token] = Regex.run(~r/name="csrf-token"[^>]*content="([^"]+)"/, html)
        token
    end
  end
end
