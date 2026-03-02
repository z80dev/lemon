defmodule LemonGateway.Transports.Webhook.IdempotencyTest do
  use ExUnit.Case, async: false

  alias LemonGateway.Transports.Webhook.Idempotency
  alias LemonCore.Store

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_core)
    clear_idempotency_table()

    on_exit(fn ->
      clear_idempotency_table()
    end)

    :ok
  end

  describe "table/0" do
    test "returns the idempotency table name" do
      assert Idempotency.table() == :webhook_idempotency
    end
  end

  describe "context/4" do
    test "returns {:ok, nil} when no idempotency key is present" do
      conn = Plug.Test.conn(:post, "/webhooks/demo", "")
      assert {:ok, nil} = Idempotency.context(conn, %{}, "demo", %{})
    end

    test "creates context for new idempotency key from header" do
      integration_id = "demo-#{System.unique_integer([:positive])}"
      idempotency_key = "idem-#{System.unique_integer([:positive])}"

      conn =
        Plug.Test.conn(:post, "/webhooks/#{integration_id}", "")
        |> Plug.Conn.put_req_header("idempotency-key", idempotency_key)

      assert {:ok, %{idempotency_key: ^idempotency_key, integration_id: ^integration_id}} =
               Idempotency.context(conn, %{}, integration_id, %{})
    end

    test "returns duplicate for already-pending key" do
      integration_id = "demo-pending-#{System.unique_integer([:positive])}"
      idempotency_key = "idem-pending-#{System.unique_integer([:positive])}"

      conn =
        Plug.Test.conn(:post, "/webhooks/#{integration_id}", "")
        |> Plug.Conn.put_req_header("idempotency-key", idempotency_key)

      assert {:ok, %{store_key: _store_key}} =
               Idempotency.context(conn, %{}, integration_id, %{})

      assert {:duplicate, 202, response_payload} =
               Idempotency.context(conn, %{}, integration_id, %{})

      assert response_payload.status == "processing"
    end

    test "ignores payload idempotency key by default" do
      integration_id = "demo-#{System.unique_integer([:positive])}"

      conn = %{
        Plug.Test.conn(:post, "/webhooks/#{integration_id}", "")
        | body_params: %{"idempotency_key" => "payload-idem"}
      }

      assert {:ok, nil} = Idempotency.context(conn, %{}, integration_id, %{})
    end

    test "accepts payload idempotency key when explicitly enabled" do
      integration_id = "demo-#{System.unique_integer([:positive])}"

      conn = %{
        Plug.Test.conn(:post, "/webhooks/#{integration_id}", "")
        | body_params: %{"idempotency_key" => "payload-idem"}
      }

      assert {:ok, %{idempotency_key: "payload-idem"}} =
               Idempotency.context(conn, %{}, integration_id, %{
                 "allow_payload_idempotency_key" => true
               })
    end

    test "returns duplicate response for completed submission" do
      integration_id = "demo-completed-#{System.unique_integer([:positive])}"
      idempotency_key = "idem-completed-#{System.unique_integer([:positive])}"

      conn =
        Plug.Test.conn(:post, "/webhooks/#{integration_id}", "")
        |> Plug.Conn.put_req_header("idempotency-key", idempotency_key)

      assert {:ok, idempotency_ctx} = Idempotency.context(conn, %{}, integration_id, %{})

      # Store a completed response
      :ok =
        Store.put(Idempotency.table(), idempotency_ctx.store_key, %{
          run_id: "run-123",
          session_key: "agent:demo:main",
          mode: "async",
          response_status: 200,
          response_payload: %{run_id: "run-123", status: "completed"}
        })

      assert {:duplicate, 200, %{run_id: "run-123", status: "completed"}} =
               Idempotency.context(conn, %{}, integration_id, %{})
    end
  end

  describe "store_submission/4" do
    test "stores submission metadata" do
      integration_id = "demo-sub-#{System.unique_integer([:positive])}"
      idempotency_key = "idem-sub-#{System.unique_integer([:positive])}"

      conn =
        Plug.Test.conn(:post, "/webhooks/#{integration_id}", "")
        |> Plug.Conn.put_req_header("idempotency-key", idempotency_key)

      assert {:ok, idempotency_ctx} = Idempotency.context(conn, %{}, integration_id, %{})

      assert :ok =
               Idempotency.store_submission(idempotency_ctx, "run-456", "session:key", :async)

      entry = Store.get(Idempotency.table(), idempotency_ctx.store_key)
      assert entry.run_id == "run-456"
      assert entry.session_key == "session:key"
      assert entry.state == "submitted"
    end

    test "returns :ok for nil context" do
      assert :ok = Idempotency.store_submission(nil, "run-1", "key", :async)
    end
  end

  describe "store_response/3" do
    test "stores response for idempotency context" do
      integration_id = "demo-resp-#{System.unique_integer([:positive])}"
      idempotency_key = "idem-resp-#{System.unique_integer([:positive])}"

      conn =
        Plug.Test.conn(:post, "/webhooks/#{integration_id}", "")
        |> Plug.Conn.put_req_header("idempotency-key", idempotency_key)

      assert {:ok, idempotency_ctx} = Idempotency.context(conn, %{}, integration_id, %{})

      assert :ok =
               Idempotency.store_response(idempotency_ctx, 200, %{run_id: "run-789"})

      entry = Store.get(Idempotency.table(), idempotency_ctx.store_key)
      assert entry.response_status == 200
      assert entry.response_payload == %{run_id: "run-789"}
      assert entry.state == "completed"
    end

    test "returns :ok for nil context" do
      assert :ok = Idempotency.store_response(nil, 200, %{})
    end
  end

  # --- Helpers ---

  defp clear_idempotency_table do
    Idempotency.table()
    |> Store.list()
    |> Enum.each(fn {key, _value} ->
      Store.delete(Idempotency.table(), key)
    end)
  end
end
