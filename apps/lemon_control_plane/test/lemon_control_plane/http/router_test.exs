defmodule LemonControlPlane.HTTP.RouterTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias LemonControlPlane.HTTP.Router

  setup do
    previous_loopback =
      Application.fetch_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator)

    previous_operator = Application.fetch_env(:lemon_control_plane, :operator_token)

    on_exit(fn ->
      restore_env(:allow_unauthenticated_loopback_operator, previous_loopback)
      restore_env(:operator_token, previous_operator)
    end)

    :ok
  end

  test "unknown HTTP paths share protocol codes and a JSON error envelope" do
    missing = conn(:get, "/missing") |> Router.call([]) |> json_response()
    assert missing.status == 404
    assert missing.body == %{"error" => %{"code" => "NOT_FOUND", "message" => "Not found"}}
    assert conn(:get, "/healthz") |> Router.call([]) |> Map.fetch!(:resp_body) == ~s({"ok":true})
  end

  # #711: the OpenAI-compatible `/v1` and the single-shot POST `/acp` surfaces
  # are retired. Even a valid operator credential, or tokenless loopback
  # compatibility, reaches only the ordinary 404 envelope.
  test "the retired /v1 and POST /acp surfaces are gone for every credential" do
    Application.put_env(:lemon_control_plane, :operator_token, "router-operator-token")

    requests = [
      {:get, "/v1/models", nil},
      {:get, "/v1/health", nil},
      {:post, "/v1/chat/completions", %{"model" => "m", "messages" => []}},
      {:post, "/v1/responses", %{"model" => "m", "input" => "hi"}},
      {:get, "/v1/runs/run_1", nil},
      {:post, "/v1/runs/run_1/cancel", nil},
      {:post, "/acp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"}}
    ]

    for {method, path, body} <- requests,
        auth <- [[], [{"authorization", "Bearer router-operator-token"}]] do
      request =
        if body, do: json_conn(method, path, body), else: conn(method, path)

      response =
        auth
        |> Enum.reduce(request, fn {key, value}, acc -> put_req_header(acc, key, value) end)
        |> Router.call([])
        |> json_response()

      assert response.status == 404, "#{method} #{path} is still served"
      assert response.body == %{"error" => %{"code" => "NOT_FOUND", "message" => "Not found"}}
    end

    Application.delete_env(:lemon_control_plane, :operator_token)
    Application.put_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator, true)

    for {method, path, _body} <- requests do
      assert (conn(method, path) |> Router.call([])).status == 404
    end
  end

  test "ACP WebSocket denial names the operator credential without exposing it" do
    Application.put_env(:lemon_control_plane, :operator_token, "private-operator-test-token")

    response = conn(:get, "/acp/ws") |> Router.call([]) |> json_response()
    assert response.status == 401
    assert response.body["error"]["code"] == "UNAUTHORIZED"
    assert response.body["error"]["message"] =~ "Authorization: Bearer <token>"
    assert response.body["error"]["message"] =~ "LEMON_CONTROL_PLANE_OPERATOR_TOKEN"
    assert response.body["error"]["message"] =~ "control-plane-<port>.token"
    refute Jason.encode!(response.body) =~ "private-operator-test-token"
  end

  defp json_conn(method, path, body) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
  end

  # The router refuses non-loopback Host headers from loopback peers.
  defp conn(method, path, body \\ nil),
    do: %{Plug.Test.conn(method, path, body) | host: "localhost"}

  defp json_response(conn) do
    %{status: conn.status, body: Jason.decode!(conn.resp_body)}
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:lemon_control_plane, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:lemon_control_plane, key)
end
