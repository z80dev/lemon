defmodule LemonGateway.Transports.Webhook.AuthTest do
  use ExUnit.Case, async: true

  alias LemonGateway.Transports.Webhook.Auth

  describe "authorize_request/3" do
    test "accepts valid Bearer authorization header" do
      conn =
        Plug.Test.conn(:post, "/webhooks/demo", "")
        |> Plug.Conn.put_req_header("authorization", "Bearer secret-token")

      assert :ok = Auth.authorize_request(conn, %{}, %{"token" => "secret-token"})
    end

    test "accepts valid x-webhook-token header" do
      conn =
        Plug.Test.conn(:post, "/webhooks/demo", "")
        |> Plug.Conn.put_req_header("x-webhook-token", "secret-token")

      assert :ok = Auth.authorize_request(conn, %{}, %{"token" => "secret-token"})
    end

    test "rejects mismatched token" do
      conn =
        Plug.Test.conn(:post, "/webhooks/demo", "")
        |> Plug.Conn.put_req_header("authorization", "Bearer wrong-token")

      assert {:error, :unauthorized} =
               Auth.authorize_request(conn, %{}, %{"token" => "secret-token"})
    end

    test "rejects request with no token provided" do
      conn = Plug.Test.conn(:post, "/webhooks/demo", "")
      assert {:error, :unauthorized} = Auth.authorize_request(conn, %{}, %{"token" => "secret"})
    end

    test "rejects when no token is configured and none provided" do
      # When both expected and provided tokens are nil, secure_compare returns false
      conn = Plug.Test.conn(:post, "/webhooks/demo", "")
      assert {:error, :unauthorized} = Auth.authorize_request(conn, %{}, %{})
    end

    test "rejects query token by default" do
      conn = Plug.Test.conn(:post, "/webhooks/demo?token=secret-token", "")

      assert {:error, :unauthorized} =
               Auth.authorize_request(conn, %{}, %{"token" => "secret-token"})
    end

    test "accepts query token when allow_query_token is enabled" do
      conn = Plug.Test.conn(:post, "/webhooks/demo?token=secret-token", "")

      assert :ok =
               Auth.authorize_request(conn, %{}, %{
                 "token" => "secret-token",
                 "allow_query_token" => true
               })
    end

    test "rejects payload token by default" do
      conn = %{
        Plug.Test.conn(:post, "/webhooks/demo", "")
        | body_params: %{"token" => "secret-token"}
      }

      assert {:error, :unauthorized} =
               Auth.authorize_request(conn, %{"token" => "secret-token"}, %{
                 "token" => "secret-token"
               })
    end

    test "accepts payload token when allow_payload_token is enabled" do
      conn = %{
        Plug.Test.conn(:post, "/webhooks/demo", "")
        | body_params: %{"token" => "secret-token"}
      }

      assert :ok =
               Auth.authorize_request(conn, %{"token" => "secret-token"}, %{
                 "token" => "secret-token",
                 "allow_payload_token" => true
               })
    end

    test "accepts lowercase bearer prefix" do
      conn =
        Plug.Test.conn(:post, "/webhooks/demo", "")
        |> Plug.Conn.put_req_header("authorization", "bearer my-token")

      assert :ok = Auth.authorize_request(conn, %{}, %{"token" => "my-token"})
    end

    test "accepts raw authorization header without Bearer prefix" do
      conn =
        Plug.Test.conn(:post, "/webhooks/demo", "")
        |> Plug.Conn.put_req_header("authorization", "raw-token")

      assert :ok = Auth.authorize_request(conn, %{}, %{"token" => "raw-token"})
    end
  end

  describe "secure_compare/2" do
    test "returns true for exact match" do
      assert Auth.secure_compare("secret-token", "secret-token")
    end

    test "returns false for different values" do
      refute Auth.secure_compare("secret-token", "other-token")
    end

    test "returns false for different lengths" do
      refute Auth.secure_compare("short", "longer-value")
    end

    test "returns false when expected is nil" do
      refute Auth.secure_compare(nil, "token")
    end

    test "returns false when provided is nil" do
      refute Auth.secure_compare("token", nil)
    end

    test "returns false when both are nil" do
      refute Auth.secure_compare(nil, nil)
    end
  end
end
