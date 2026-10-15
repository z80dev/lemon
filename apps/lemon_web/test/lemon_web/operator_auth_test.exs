defmodule LemonWeb.OperatorAuthTest do
  use ExUnit.Case, async: false

  @endpoint LemonWeb.Endpoint

  import ExUnit.CaptureLog
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import LemonWeb.Test.OperatorAuth
  import Plug.Conn, only: [get_session: 2]

  alias LemonWeb.{Auth, LoginController, LoginThrottle}

  defp peer(conn, ip), do: %{conn | remote_ip: ip}

  defp clear_throttle(_context) do
    for ip <- [{127, 0, 0, 1}, {10, 0, 0, 7}, {10, 0, 0, 8}], do: LoginThrottle.clear(ip)
    :ok
  end

  setup :clear_throttle

  describe "token required by default" do
    setup :configure_operator_token

    test "unauthenticated page requests redirect to login with a safe return path" do
      conn = get(build_conn(), "/sessions?view=all&token=leaked")
      location = redirected_to(conn, 302)
      assert location =~ "/login?"
      assert URI.decode_query(URI.parse(location).query) == %{"return_to" => "/sessions?view=all"}
    end

    test "query tokens never authenticate", %{token: token} do
      conn = get(build_conn(), "/sessions?token=#{token}")
      assert redirected_to(conn, 302) =~ "/login?"
    end

    test "bearer headers never authenticate browser routes", %{token: token} do
      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
        |> get("/sessions")

      assert redirected_to(conn, 302) =~ "/login?"
    end

    test "non-GET requests without a session are 401" do
      conn = post(build_conn(), "/sessions/agent:x/export/json")
      assert conn.status in [401, 404]
    end

    test "login page renders a password field and keeps the token out of HTML" do
      html = build_conn() |> get("/login") |> html_response(200)
      assert html =~ ~s(type="password")
      assert html =~ "Sign in to Lemon"
    end

    test "valid token logs in, renews the session and redirects to return_to", %{token: token} do
      log =
        capture_log(fn ->
          conn =
            build_conn()
            |> peer({10, 0, 0, 7})
            |> post("/login", %{"token" => token, "return_to" => "/sessions"})

          assert redirected_to(conn, 302) == "/sessions"
          stored = get_session(conn, Auth.session_key())
          assert is_binary(stored)
          refute stored =~ token
          refute conn.resp_body =~ token

          html = conn |> recycle() |> get("/sessions") |> html_response(200)
          refute html =~ token
        end)

      refute log =~ token
    end

    test "invalid token is refused with 401 and no session", %{token: token} do
      conn = build_conn() |> peer({10, 0, 0, 7}) |> post("/login", %{"token" => token <> "x"})
      assert html_response(conn, 401) =~ "not accepted"
      assert get_session(conn, Auth.session_key()) == nil
    end

    test "blank token is refused" do
      conn = build_conn() |> peer({10, 0, 0, 7}) |> post("/login", %{"token" => "   "})
      assert html_response(conn, 401) =~ "not accepted"
    end

    test "repeated failures from one peer are throttled", %{token: token} do
      for _ <- 1..5 do
        conn = build_conn() |> peer({10, 0, 0, 8}) |> post("/login", %{"token" => "wrong"})
        assert conn.status == 401
      end

      conn = build_conn() |> peer({10, 0, 0, 8}) |> post("/login", %{"token" => token})
      assert conn.status == 429
      assert [_] = Plug.Conn.get_resp_header(conn, "retry-after")

      # Another peer is unaffected.
      conn = build_conn() |> peer({10, 0, 0, 7}) |> post("/login", %{"token" => token})
      assert redirected_to(conn, 302) == "/"
    end

    test "rotating the operator token invalidates existing sessions", %{conn: conn} do
      assert conn |> get("/sessions") |> html_response(200)

      Application.put_env(:lemon_control_plane, :operator_token, "rotated-token")
      assert conn |> get("/sessions") |> redirected_to(302) =~ "/login?"
    end

    test "a node session token is not an operator credential" do
      node_token = "node-session-#{System.unique_integer([:positive])}"

      {:ok, _} =
        LemonControlPlane.Auth.TokenStore.store(node_token, %{"type" => "node", "nodeId" => "n1"})

      on_exit(fn -> LemonControlPlane.Auth.TokenStore.revoke(node_token) end)

      assert {:error, :invalid_token} = Auth.login(node_token, {127, 0, 0, 1})
    end

    test "logout drops the session", %{conn: conn} do
      conn = delete(conn, "/logout")
      assert redirected_to(conn, 302) == "/login"
      assert conn |> recycle() |> get("/sessions") |> redirected_to(302) =~ "/login?"
    end

    test "LiveView mounts re-verify the session marker", %{conn: conn, token: token} do
      assert {:ok, _view, _html} = live(conn, "/sessions")

      socket = fn ip ->
        %Phoenix.LiveView.Socket{private: %{connect_info: %{peer_data: %{address: ip}}}}
      end

      {:ok, marker} = Auth.login(token, {127, 0, 0, 1})
      session = %{Auth.session_key() => marker}

      assert {:cont, %{assigns: %{operator_access: :token}}} =
               LemonWeb.LiveAuth.on_mount(:require_operator, %{}, session, socket.({10, 0, 0, 7}))

      assert {:halt, %{redirected: {:redirect, %{to: "/login"}}}} =
               LemonWeb.LiveAuth.on_mount(
                 :require_operator,
                 %{},
                 %{Auth.session_key() => "forged"},
                 socket.({127, 0, 0, 1})
               )

      Application.put_env(:lemon_control_plane, :operator_token, "rotated-token")

      assert {:halt, _} =
               LemonWeb.LiveAuth.on_mount(
                 :require_operator,
                 %{},
                 session,
                 socket.({127, 0, 0, 1})
               )
    end

    test "healthz stays public" do
      assert build_conn() |> get("/healthz") |> text_response(200) == "ok"
    end
  end

  describe "no configured token" do
    setup :clear_operator_token

    test "fails closed with 503 by default, even from loopback" do
      conn = build_conn() |> peer({127, 0, 0, 1}) |> get("/sessions")
      assert response(conn, 503) =~ "operator token"

      conn = build_conn() |> peer({127, 0, 0, 1}) |> get("/login")
      assert html_response(conn, 503) =~ "No operator token is configured"
    end

    test "browser GET receives helpful HTML without opening access" do
      conn =
        build_conn()
        |> Plug.Conn.put_req_header("accept", "text/html,application/xhtml+xml")
        |> get("/sessions")

      html = html_response(conn, 503)
      assert html =~ "No operator token is configured"
      assert html =~ "LEMON_CONTROL_PLANE_OPERATOR_TOKEN"
      assert html =~ ~s(href="/login")
    end

    test "non-HTML GET keeps the plain-text 503" do
      conn =
        build_conn() |> Plug.Conn.put_req_header("accept", "application/json") |> get("/sessions")

      assert response(conn, 503) =~ "operator token"
      assert Plug.Conn.get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    end

    test "explicit tokenless compatibility admits only direct loopback peers" do
      Application.put_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator, true)

      assert build_conn() |> peer({127, 0, 0, 1}) |> get("/sessions") |> html_response(200)

      assert build_conn()
             |> peer({0, 0, 0, 0, 0, 0, 0, 1})
             |> get("/sessions")
             |> html_response(200)

      conn = build_conn() |> peer({10, 0, 0, 7}) |> get("/sessions")
      assert response(conn, 503)

      # Forwarded headers are never consulted.
      conn =
        build_conn()
        |> peer({10, 0, 0, 7})
        |> Plug.Conn.put_req_header("x-forwarded-for", "127.0.0.1")
        |> get("/sessions")

      assert response(conn, 503)
    end

    test "tokenless loopback cannot be used to log in" do
      Application.put_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator, true)
      assert {:error, :not_configured} = Auth.login("anything", {127, 0, 0, 1})
    end
  end

  describe "return_to sanitization" do
    test "only same-origin absolute paths survive" do
      assert LoginController.safe_return_to("/chat/agent:a") == "/chat/agent:a"
      assert LoginController.safe_return_to("https://evil.example/") == "/"
      assert LoginController.safe_return_to("//evil.example/") == "/"
      assert LoginController.safe_return_to("/\\evil") == "/"
      assert LoginController.safe_return_to("/login?return_to=/x") == "/"
      assert LoginController.safe_return_to(nil) == "/"
    end
  end
end
