defmodule LemonGateway.Transports.Webhook.ResponseTest do
  use ExUnit.Case, async: true

  alias LemonGateway.Transports.Webhook.Response

  describe "json/3" do
    test "sends JSON response with correct content type and status" do
      conn = Plug.Test.conn(:post, "/test", "")
      result = Response.json(conn, 200, %{ok: true})

      assert result.status == 200
      assert result.resp_body == ~s({"ok":true})
      assert {"content-type", "application/json; charset=utf-8"} in result.resp_headers
    end

    test "supports different status codes" do
      conn = Plug.Test.conn(:post, "/test", "")
      result = Response.json(conn, 202, %{status: "accepted"})
      assert result.status == 202
    end
  end

  describe "json_error/3" do
    test "sends error response with standard format" do
      conn = Plug.Test.conn(:post, "/test", "")
      result = Response.json_error(conn, 404, "not found")

      assert result.status == 404
      assert Jason.decode!(result.resp_body) == %{"error" => "not found"}
    end
  end

  describe "request_metadata/1" do
    test "extracts basic request metadata" do
      conn = Plug.Test.conn(:post, "/webhooks/demo", "")
      metadata = Response.request_metadata(conn)

      assert metadata.method == "POST"
      assert metadata.path == "/webhooks/demo"
    end

    test "redacts sensitive query parameters" do
      conn = Plug.Test.conn(:post, "/webhooks/demo?token=topsecret&foo=bar&api_key=abc123", "")
      metadata = Response.request_metadata(conn)

      assert is_binary(metadata.query)
      redacted_query = URI.decode_query(metadata.query)

      assert redacted_query["token"] == "[REDACTED]"
      assert redacted_query["api_key"] == "[REDACTED]"
      assert redacted_query["foo"] == "bar"
    end

    test "redacts password, secret, auth, signature, sig, apikey params" do
      params = "password=x&secret=x&auth=x&authorization=x&signature=x&sig=x&apikey=x&safe=ok"
      conn = Plug.Test.conn(:post, "/test?#{params}", "")
      metadata = Response.request_metadata(conn)
      decoded = URI.decode_query(metadata.query)

      assert decoded["password"] == "[REDACTED]"
      assert decoded["secret"] == "[REDACTED]"
      assert decoded["auth"] == "[REDACTED]"
      assert decoded["authorization"] == "[REDACTED]"
      assert decoded["signature"] == "[REDACTED]"
      assert decoded["sig"] == "[REDACTED]"
      assert decoded["apikey"] == "[REDACTED]"
      assert decoded["safe"] == "ok"
    end

    test "returns nil query for empty query string" do
      conn = Plug.Test.conn(:post, "/test", "")
      metadata = Response.request_metadata(conn)
      assert metadata.query == nil
    end

    test "extracts user-agent header" do
      conn =
        Plug.Test.conn(:post, "/test", "")
        |> Plug.Conn.put_req_header("user-agent", "TestAgent/1.0")

      metadata = Response.request_metadata(conn)
      assert metadata.user_agent == "TestAgent/1.0"
    end

    test "extracts x-request-id header" do
      conn =
        Plug.Test.conn(:post, "/test", "")
        |> Plug.Conn.put_req_header("x-request-id", "req-abc-123")

      metadata = Response.request_metadata(conn)
      assert metadata.request_id == "req-abc-123"
    end

    test "formats IPv4 remote_ip" do
      conn = %{Plug.Test.conn(:post, "/test", "") | remote_ip: {192, 168, 1, 100}}
      metadata = Response.request_metadata(conn)
      assert metadata.remote_ip == "192.168.1.100"
    end
  end
end
