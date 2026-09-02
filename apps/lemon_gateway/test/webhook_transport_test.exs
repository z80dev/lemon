defmodule LemonGateway.WebhookTransportTestOrchestrator do
  @behaviour LemonCore.RouterBridge.RunOrchestrator

  def submit(request) do
    send(
      Application.fetch_env!(:lemon_gateway, :webhook_transport_test_pid),
      {:webhook_submit, request}
    )

    case Application.fetch_env!(:lemon_gateway, :webhook_transport_submit_result) do
      {:raise, message} -> raise message
      result -> result
    end
  end
end

defmodule LemonGateway.WebhookSecondDeleteFailureBackend do
  @behaviour LemonCore.Store.Backend

  @impl true
  def init(_opts), do: {:ok, %{data: %{}, delete_count: 0}}

  @impl true
  def put(state, table, key, value), do: {:ok, put_in(state, [:data, {table, key}], value)}

  @impl true
  def put_new(state, table, key, value) do
    if Map.has_key?(state.data, {table, key}),
      do: {:exists, state},
      else: put(state, table, key, value)
  end

  @impl true
  def get(state, table, key), do: {:ok, Map.get(state.data, {table, key}), state}

  @impl true
  def delete(%{delete_count: 1}, _table, _key), do: {:error, :injected_second_delete}

  def delete(state, table, key) do
    {:ok,
     %{state | data: Map.delete(state.data, {table, key}), delete_count: state.delete_count + 1}}
  end

  @impl true
  def list(state, table) do
    entries = for {{^table, key}, value} <- state.data, do: {key, value}
    {:ok, entries, state}
  end
end

defmodule LemonGateway.WebhookTransportTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LemonCore.Store
  alias LemonGateway.Transports.Webhook
  alias LemonGateway.Transports.Webhook.{Idempotency, InvocationDispatch, ResponseBuilder}
  alias Plug.Conn
  alias Plug.Test

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_core)

    original_webhook_env = Application.get_env(:lemon_gateway, :webhook)
    original_override = Application.get_env(:lemon_gateway, LemonGateway.Config)
    original_bridge = Application.get_env(:lemon_core, :router_bridge)
    original_test_pid = Application.get_env(:lemon_gateway, :webhook_transport_test_pid)

    original_submit_result =
      Application.get_env(:lemon_gateway, :webhook_transport_submit_result)

    clear_idempotency_table()

    Application.delete_env(:lemon_gateway, :webhook)
    Application.delete_env(:lemon_gateway, LemonGateway.Config)
    Application.put_env(:lemon_gateway, :webhook_transport_test_pid, self())

    Application.put_env(
      :lemon_gateway,
      :webhook_transport_submit_result,
      {:ok, "run-webhook-default"}
    )

    :ok =
      LemonCore.RouterBridge.configure(
        run_orchestrator: LemonGateway.WebhookTransportTestOrchestrator,
        router: original_bridge && original_bridge[:router]
      )

    on_exit(fn ->
      restore_env(:lemon_gateway, :webhook, original_webhook_env)
      restore_env(:lemon_gateway, LemonGateway.Config, original_override)
      restore_env(:lemon_core, :router_bridge, original_bridge)
      restore_env(:lemon_gateway, :webhook_transport_test_pid, original_test_pid)

      restore_env(
        :lemon_gateway,
        :webhook_transport_submit_result,
        original_submit_result
      )

      clear_idempotency_table()
    end)

    :ok
  end

  test "ambiguous submission returns a non-retryable HTTP receipt without claiming acceptance" do
    run_id = "run-webhook-unknown-#{System.unique_integer([:positive])}"

    Application.put_env(
      :lemon_gateway,
      :webhook_transport_submit_result,
      {:error, :outcome_unknown}
    )

    assert {:ok, run_ctx} = dispatch_webhook(run_id, nil)
    assert_receive {:webhook_submit, %{run_id: ^run_id}}

    assert {:ok, 200, payload} = ResponseBuilder.response_for_run(run_ctx)
    assert payload.run_id == run_id
    assert payload.status == "outcome_unknown"
    assert payload.retry_safe == false
    refute Map.has_key?(payload, :accepted)
    refute_receive {:webhook_submit, _request}
  end

  test "idempotency-key redelivery replays an ambiguous receipt without resubmission" do
    integration_id = "demo-unknown-#{System.unique_integer([:positive])}"
    idempotency_key = "idem-unknown-#{System.unique_integer([:positive])}"
    run_id = "run-webhook-unknown-#{System.unique_integer([:positive])}"

    conn =
      Test.conn(:post, "/webhooks/#{integration_id}", "")
      |> Conn.put_req_header("idempotency-key", idempotency_key)

    assert {:ok, idempotency_ctx} =
             Webhook.idempotency_context_for_test(conn, %{}, integration_id, %{})

    Application.put_env(
      :lemon_gateway,
      :webhook_transport_submit_result,
      {:error, :outcome_unknown}
    )

    assert {:ok, run_ctx} = dispatch_webhook(run_id, idempotency_ctx, integration_id)
    assert_receive {:webhook_submit, %{run_id: ^run_id}}
    assert {:ok, 200, payload} = ResponseBuilder.response_for_run(run_ctx)

    assert {:duplicate, 202, pending_payload} =
             Webhook.idempotency_context_for_test(conn, %{}, integration_id, %{})

    assert pending_payload.run_id == run_id
    assert pending_payload.status == "outcome_unknown"
    assert pending_payload.retry_safe == false

    assert :ok = Idempotency.store_response(idempotency_ctx, 200, payload)

    assert {:duplicate, 200, ^payload} =
             Webhook.idempotency_context_for_test(conn, %{}, integration_id, %{})

    refute_receive {:webhook_submit, _request}
  end

  test "submission exceptions and explicit rejection terms cannot expose adversarial secrets" do
    secret = "webhook-router-secret-#{System.unique_integer([:positive])}"
    run_id = "run-webhook-secret-#{System.unique_integer([:positive])}"

    Application.put_env(
      :lemon_gateway,
      :webhook_transport_submit_result,
      {:raise, secret}
    )

    log =
      capture_log(fn ->
        assert {:ok, run_ctx} = dispatch_webhook(run_id, nil)
        assert {:ok, 200, payload} = ResponseBuilder.response_for_run(run_ctx)
        assert payload.status == "outcome_unknown"
        refute inspect(payload) =~ secret
      end)

    assert_receive {:webhook_submit, %{run_id: ^run_id}}
    refute log =~ secret

    Application.put_env(
      :lemon_gateway,
      :webhook_transport_submit_result,
      {:error, {:rejected_with_secret, secret}}
    )

    assert {:error, :submit_rejected} = dispatch_webhook(run_id <> "-rejected", nil)
    assert_receive {:webhook_submit, %{run_id: rejected_run_id}}
    assert rejected_run_id == run_id <> "-rejected"
    refute_receive {:webhook_submit, _request}
  end

  test "idempotency helper reserves key and returns a retryable pending receipt" do
    integration_id = "demo-pending-#{System.unique_integer([:positive])}"
    idempotency_key = "idem-pending-#{System.unique_integer([:positive])}"

    conn =
      Test.conn(:post, "/webhooks/#{integration_id}", "")
      |> Conn.put_req_header("idempotency-key", idempotency_key)

    assert {:ok, %{store_key: store_key, idempotency_digest: digest} = ctx} =
             Webhook.idempotency_context_for_test(conn, %{}, integration_id, %{})

    assert {:v1, ^digest} = store_key
    stored = Store.get(Webhook.idempotency_table_for_test(), store_key)
    assert stored.idempotency_digest == digest
    refute Map.has_key?(ctx, :idempotency_key)
    refute Map.has_key?(stored, :idempotency_key)
    refute inspect({store_key, stored, ctx}) =~ idempotency_key

    assert {:duplicate, 503, response_payload} =
             Webhook.idempotency_context_for_test(conn, %{}, integration_id, %{})

    assert response_payload.status == "reservation_pending"
    assert response_payload.retry_safe == true
  end

  test "an expired pending lease is reclaimed with the same durable run id" do
    integration_id = "demo-reclaim-#{System.unique_integer([:positive])}"
    idempotency_key = "idem-reclaim-#{System.unique_integer([:positive])}"

    conn =
      Test.conn(:post, "/webhooks/#{integration_id}", "")
      |> Conn.put_req_header("idempotency-key", idempotency_key)

    assert {:ok, first_ctx} =
             Webhook.idempotency_context_for_test(conn, %{}, integration_id, %{})

    entry = Store.get(Webhook.idempotency_table_for_test(), first_ctx.store_key)

    assert :ok =
             Store.put(
               Webhook.idempotency_table_for_test(),
               first_ctx.store_key,
               Map.put(entry, :lease_expires_at_ms, 0)
             )

    assert {:ok, reclaimed_ctx} =
             Webhook.idempotency_context_for_test(conn, %{}, integration_id, %{})

    assert reclaimed_ctx.run_id == first_ctx.run_id
    refute reclaimed_ctx.reservation_id == first_ctx.reservation_id
  end

  test "gateway retries keep one semantic replay identity across request-local ids" do
    integration_id = "demo-stable-replay-#{System.unique_integer([:positive])}"
    idempotency_key = "stable-replay-#{System.unique_integer([:positive])}"

    base_conn =
      Test.conn(:post, "/webhooks/#{integration_id}", "")
      |> Conn.put_req_header("idempotency-key", idempotency_key)

    assert {:ok, ctx} =
             Webhook.idempotency_context_for_test(base_conn, %{}, integration_id, %{})

    Application.put_env(:lemon_gateway, :webhook_transport_submit_result, {:ok, ctx.run_id})

    assert {:ok, _run_ctx} =
             dispatch_webhook(
               Conn.put_req_header(base_conn, "x-request-id", "delivery-attempt-one"),
               ctx.run_id,
               ctx,
               integration_id
             )

    assert_receive {:webhook_submit, first_request}

    assert {:ok, _run_ctx} =
             dispatch_webhook(
               Conn.put_req_header(base_conn, "x-request-id", "delivery-attempt-two"),
               ctx.run_id,
               ctx,
               integration_id
             )

    assert_receive {:webhook_submit, second_request}
    assert first_request.meta.webhook.request.request_id == "delivery-attempt-one"
    assert second_request.meta.webhook.request.request_id == "delivery-attempt-two"

    assert first_request.meta.router_replay_identity ==
             second_request.meta.router_replay_identity

    assert String.starts_with?(first_request.meta.router_replay_identity, "webhook:v1:")
    refute inspect(first_request) =~ idempotency_key
    refute inspect(second_request) =~ idempotency_key

    refute inspect(Store.list(Webhook.idempotency_table_for_test())) =~ idempotency_key
    refute inspect(Store.list(Idempotency.response_table())) =~ idempotency_key
    refute Jason.encode!(first_request.meta) =~ idempotency_key
  end

  test "response persistence fails closed when its durable reservation disappears" do
    integration_id = "demo-response-store-#{System.unique_integer([:positive])}"

    conn =
      Test.conn(:post, "/webhooks/#{integration_id}", "")
      |> Conn.put_req_header("idempotency-key", "response-store")

    assert {:ok, ctx} = Webhook.idempotency_context_for_test(conn, %{}, integration_id, %{})
    assert :ok = Store.delete(Webhook.idempotency_table_for_test(), ctx.store_key)

    assert {:error, :idempotency_unavailable} =
             Idempotency.store_response(ctx, 202, %{run_id: ctx.run_id})
  end

  test "a sync response receipt replays the exact response if the primary completion update is lost" do
    integration_id = "demo-sync-response-#{System.unique_integer([:positive])}"
    idempotency_key = "sync-response-#{System.unique_integer([:positive])}"

    conn =
      Test.conn(:post, "/webhooks/#{integration_id}", "")
      |> Conn.put_req_header("idempotency-key", idempotency_key)

    assert {:ok, ctx} = Webhook.idempotency_context_for_test(conn, %{}, integration_id, %{})
    assert :ok = Idempotency.store_submission(ctx, ctx.run_id, "agent:sync:main", :sync)

    exact_payload = %{
      run_id: ctx.run_id,
      session_key: "agent:sync:main",
      mode: "sync",
      completed: %{ok: true, answer: "exact answer"},
      duration_ms: 17
    }

    assert :ok = Idempotency.store_response(ctx, 200, exact_payload)

    # This is the durable shape left when the independent response receipt commits
    # but the primary idempotency-row completion update does not.
    primary = Store.get(Webhook.idempotency_table_for_test(), ctx.store_key)

    assert :ok =
             Store.put(
               Webhook.idempotency_table_for_test(),
               ctx.store_key,
               primary
               |> Map.drop([:response_status, :response_payload])
               |> Map.put(:state, "submitted")
             )

    assert {:duplicate, 200, ^exact_payload} =
             Webhook.idempotency_context_for_test(conn, %{}, integration_id, %{})
  end

  test "expired exact response receipts are swept with their primary reservation" do
    integration_id = "demo-response-retention-#{System.unique_integer([:positive])}"
    idempotency_key = "response-retention-#{System.unique_integer([:positive])}"

    conn =
      Test.conn(:post, "/webhooks/#{integration_id}", "")
      |> Conn.put_req_header("idempotency-key", idempotency_key)

    assert {:ok, ctx} = Webhook.idempotency_context_for_test(conn, %{}, integration_id, %{})
    assert :ok = Idempotency.store_response(ctx, 200, %{run_id: ctx.run_id, exact: true})

    receipt_key = {ctx.store_key, ctx.reservation_id}
    receipt = Store.get(Idempotency.response_table(), receipt_key)

    primary = Store.get(Webhook.idempotency_table_for_test(), ctx.store_key)

    assert :ok =
             Store.put(Webhook.idempotency_table_for_test(), ctx.store_key, %{
               primary
               | updated_at_ms: 0
             })

    assert :ok = Idempotency.sweep_expired(10, 1)
    assert Store.get(Webhook.idempotency_table_for_test(), ctx.store_key) != nil
    assert Store.get(Idempotency.response_table(), receipt_key) == receipt

    assert :ok =
             Store.put(Idempotency.response_table(), receipt_key, %{receipt | stored_at_ms: 0})

    assert :ok = Idempotency.sweep_expired(10, 1)
    assert Store.get(Idempotency.response_table(), receipt_key) == nil
    assert Store.get(Webhook.idempotency_table_for_test(), ctx.store_key) == nil

    assert {:ok, replacement_ctx} =
             Webhook.idempotency_context_for_test(conn, %{}, integration_id, %{})

    refute replacement_ctx.reservation_id == ctx.reservation_id
  end

  test "a second-delete failure preserves the primary execution fence" do
    integration_id = "demo-response-sweep-fault-#{System.unique_integer([:positive])}"
    idempotency_key = "response-sweep-fault-#{System.unique_integer([:positive])}"

    conn =
      Test.conn(:post, "/webhooks/#{integration_id}", "")
      |> Conn.put_req_header("idempotency-key", idempotency_key)

    assert {:ok, ctx} = Webhook.idempotency_context_for_test(conn, %{}, integration_id, %{})
    assert :ok = Idempotency.store_submission(ctx, ctx.run_id, "agent:sweep-fault:main", :sync)
    assert :ok = Idempotency.store_response(ctx, 200, %{run_id: ctx.run_id, exact: true})

    receipt_key = {ctx.store_key, ctx.reservation_id}
    receipt = Store.get(Idempotency.response_table(), receipt_key)
    primary = Store.get(Webhook.idempotency_table_for_test(), ctx.store_key)

    expired_receipt = %{receipt | stored_at_ms: 0}
    expired_primary = %{primary | updated_at_ms: 0}

    backend_state = %{
      data: %{
        {Idempotency.response_table(), receipt_key} => expired_receipt,
        {Webhook.idempotency_table_for_test(), ctx.store_key} => expired_primary
      },
      delete_count: 0
    }

    original_store_state = :sys.get_state(Store)

    :sys.replace_state(Store, fn state ->
      %{
        state
        | backend: LemonGateway.WebhookSecondDeleteFailureBackend,
          backend_state: backend_state
      }
    end)

    on_exit(fn -> :sys.replace_state(Store, fn _state -> original_store_state end) end)

    assert {:error, :idempotency_unavailable} = Idempotency.sweep_expired(10, 1)
    assert Store.get(Idempotency.response_table(), receipt_key) == nil

    assert Store.get(Webhook.idempotency_table_for_test(), ctx.store_key) == expired_primary

    assert {:duplicate, 200, replay} =
             Webhook.idempotency_context_for_test(conn, %{}, integration_id, %{})

    assert replay.run_id == ctx.run_id
    assert replay.exact == true
  end

  test "a sync submission without a durable response never replays generic accepted" do
    integration_id = "demo-sync-unavailable-#{System.unique_integer([:positive])}"

    conn =
      Test.conn(:post, "/webhooks/#{integration_id}", "")
      |> Conn.put_req_header("idempotency-key", "sync-unavailable")

    assert {:ok, ctx} = Webhook.idempotency_context_for_test(conn, %{}, integration_id, %{})
    assert :ok = Idempotency.store_submission(ctx, ctx.run_id, "agent:sync:main", :sync)

    assert {:duplicate, 503, payload} =
             Webhook.idempotency_context_for_test(conn, %{}, integration_id, %{})

    assert payload.run_id == ctx.run_id
    assert payload.status == "response_persistence_unknown"
    assert payload.retry_safe == false
  end

  test "accepted submission fails closed when its durable reservation disappears" do
    integration_id = "demo-submission-store-#{System.unique_integer([:positive])}"

    conn =
      Test.conn(:post, "/webhooks/#{integration_id}", "")
      |> Conn.put_req_header("idempotency-key", "submission-store")

    assert {:ok, ctx} = Webhook.idempotency_context_for_test(conn, %{}, integration_id, %{})
    assert :ok = Store.delete(Webhook.idempotency_table_for_test(), ctx.store_key)

    Application.put_env(
      :lemon_gateway,
      :webhook_transport_submit_result,
      {:ok, ctx.run_id}
    )

    assert {:error, :idempotency_unavailable} =
             dispatch_webhook(ctx.run_id, ctx, integration_id)

    assert_receive {:webhook_submit, %{run_id: run_id}}
    assert run_id == ctx.run_id
  end

  test "an unreadable existing idempotency claim fails closed without submission" do
    integration_id = "demo-corrupt-#{System.unique_integer([:positive])}"
    idempotency_key = "idem-corrupt-#{System.unique_integer([:positive])}"

    conn =
      Test.conn(:post, "/webhooks/#{integration_id}", "")
      |> Conn.put_req_header("idempotency-key", idempotency_key)

    assert {:ok, ctx} =
             Webhook.idempotency_context_for_test(conn, %{}, integration_id, %{})

    assert :ok =
             Store.put(Webhook.idempotency_table_for_test(), ctx.store_key, %{
               integration_id: integration_id,
               idempotency_digest: ctx.idempotency_digest,
               state: "completed"
             })

    assert {:error, :idempotency_unavailable} =
             Webhook.idempotency_context_for_test(conn, %{}, integration_id, %{})

    refute_receive {:webhook_submit, _request}
  end

  test "normalizes prompt, attachments, and metadata from webhook payloads" do
    payload = %{
      "content" => %{"text" => "Ship this"},
      "files" => [%{"name" => "spec.txt", "url" => "https://example.test/spec.txt"}],
      "urls" => ["https://example.test/mock.png"],
      "metadata" => %{"source" => "zapier", "workflow_id" => "wf_123"}
    }

    assert {:ok, normalized} = Webhook.normalize_payload_for_test(payload)
    assert normalized.prompt =~ "Ship this"
    assert normalized.prompt =~ "Attachments:"
    assert normalized.prompt =~ "https://example.test/spec.txt"
    assert normalized.prompt =~ "https://example.test/mock.png"
    assert length(normalized.attachments) == 2
    assert normalized.metadata["source"] == "zapier"
    assert normalized.metadata["workflow_id"] == "wf_123"
  end

  test "secure token compare accepts exact match and rejects mismatches" do
    assert Webhook.secure_compare_for_test("secret-token", "secret-token")
    refute Webhook.secure_compare_for_test("secret-token", "secret-token-2")
    refute Webhook.secure_compare_for_test("secret-token", nil)
    refute Webhook.secure_compare_for_test(nil, "secret-token")
  end

  test "callback success status only accepts HTTP 2xx" do
    assert Webhook.callback_success_status_for_test(200)
    assert Webhook.callback_success_status_for_test(204)
    assert Webhook.callback_success_status_for_test(299)

    refute Webhook.callback_success_status_for_test(199)
    refute Webhook.callback_success_status_for_test(300)
    refute Webhook.callback_success_status_for_test(500)
  end

  test "callback URL validation enforces canonicalization, scheme, and private host policy" do
    public_dns = fn _host -> [] end

    assert {:ok, "https://example.test/callback"} =
             Webhook.validate_callback_url_for_test("https://EXAMPLE.TEST./callback", false,
               dns_resolver: public_dns
             )

    assert {:error, :invalid_callback_url} =
             Webhook.validate_callback_url_for_test("ftp://example.test/callback", false,
               dns_resolver: public_dns
             )

    assert {:error, :invalid_callback_url} =
             Webhook.validate_callback_url_for_test("http://localhost./callback", false)

    assert {:error, :invalid_callback_url} =
             Webhook.validate_callback_url_for_test("http://127.0.0.1/callback", false)

    assert {:error, :invalid_callback_url} =
             Webhook.validate_callback_url_for_test("http://[::ffff:127.0.0.1]/callback", false)

    assert {:ok, "http://127.0.0.1/callback"} =
             Webhook.validate_callback_url_for_test("http://127.0.0.1/callback", true)

    private_dns = fn
      "internal.example" -> [{10, 1, 2, 3}, {93, 184, 216, 34}]
      _ -> []
    end

    assert {:error, :invalid_callback_url} =
             Webhook.validate_callback_url_for_test("https://INTERNAL.EXAMPLE./callback", false,
               dns_resolver: private_dns
             )

    assert {:ok, "https://internal.example/callback"} =
             Webhook.validate_callback_url_for_test("https://INTERNAL.EXAMPLE./callback", true,
               dns_resolver: private_dns
             )
  end

  test "request metadata redacts query secrets" do
    conn = Test.conn(:post, "/webhooks/demo?token=topsecret&foo=bar&api_key=abc123", "")
    metadata = Webhook.request_metadata_for_test(conn)

    assert is_binary(metadata.query)
    redacted_query = URI.decode_query(metadata.query)

    assert redacted_query["token"] == "[REDACTED]"
    assert redacted_query["api_key"] == "[REDACTED]"
    assert redacted_query["foo"] == "bar"
  end

  test "wait helper returns completion payload published on run topic" do
    run_id = "run_webhook_wait_#{System.unique_integer([:positive])}"

    Task.start(fn ->
      Process.sleep(40)

      LemonCore.Bus.broadcast(
        LemonCore.Bus.run_topic(run_id),
        LemonCore.Event.new(
          :run_completed,
          %{
            completed: %{ok: true, answer: "done"},
            duration_ms: 10
          },
          %{run_id: run_id}
        )
      )
    end)

    assert {:ok, payload} = Webhook.wait_for_run_completion_for_test(run_id, 1_000)
    assert payload.completed.ok == true
    assert payload.completed.answer == "done"
    assert payload.duration_ms == 10
  end

  test "wait helper times out when no run completion event is received" do
    run_id = "run_webhook_timeout_#{System.unique_integer([:positive])}"

    assert {:error, :timeout} = Webhook.wait_for_run_completion_for_test(run_id, 25)
  end

  test "callback waiter timeout resolves per integration, global, then default" do
    assert 300_000 ==
             Webhook.resolve_callback_wait_timeout_ms_for_test(
               %{callback_wait_timeout_ms: 300_000},
               %{callback_wait_timeout_ms: 120_000}
             )

    assert 120_000 ==
             Webhook.resolve_callback_wait_timeout_ms_for_test(
               %{},
               %{callback_wait_timeout_ms: 120_000}
             )

    assert 600_000 == Webhook.resolve_callback_wait_timeout_ms_for_test(%{}, %{})
  end

  test "auth accepts headers by default and query/payload only when explicitly enabled" do
    integration = %{"token" => "secret-token"}

    header_conn =
      Test.conn(:post, "/webhooks/demo", "")
      |> Conn.put_req_header("authorization", "Bearer secret-token")

    assert :ok = Webhook.authorize_request_for_test(header_conn, %{}, integration)

    webhook_header_conn =
      Test.conn(:post, "/webhooks/demo", "")
      |> Conn.put_req_header("x-webhook-token", "secret-token")

    assert :ok = Webhook.authorize_request_for_test(webhook_header_conn, %{}, integration)

    query_conn = Test.conn(:post, "/webhooks/demo?token=secret-token", "")

    assert {:error, :unauthorized} =
             Webhook.authorize_request_for_test(query_conn, %{}, integration)

    payload_conn = %{
      Test.conn(:post, "/webhooks/demo", "")
      | body_params: %{"token" => "secret-token"}
    }

    assert {:error, :unauthorized} =
             Webhook.authorize_request_for_test(
               payload_conn,
               %{"token" => "secret-token"},
               integration
             )

    assert :ok =
             Webhook.authorize_request_for_test(query_conn, %{}, %{
               "token" => "secret-token",
               "allow_query_token" => true
             })

    assert :ok =
             Webhook.authorize_request_for_test(payload_conn, %{"token" => "secret-token"}, %{
               "token" => "secret-token",
               "allow_payload_token" => true
             })
  end

  test "idempotency helper returns duplicate response for existing key and supports payload opt-in" do
    integration_id = "demo-#{System.unique_integer([:positive])}"
    idempotency_key = "idem-#{System.unique_integer([:positive])}"

    header_conn =
      Test.conn(:post, "/webhooks/#{integration_id}", "")
      |> Conn.put_req_header("idempotency-key", idempotency_key)

    assert {:ok, idempotency_ctx} =
             Webhook.idempotency_context_for_test(header_conn, %{}, integration_id, %{})

    assert :ok =
             Store.put(Webhook.idempotency_table_for_test(), idempotency_ctx.store_key, %{
               run_id: "run-123",
               session_key: "agent:demo:main",
               mode: "async"
             })

    assert {:duplicate, 202, response_payload} =
             Webhook.idempotency_context_for_test(header_conn, %{}, integration_id, %{})

    assert response_payload.run_id == "run-123"
    assert response_payload.session_key == "agent:demo:main"
    assert response_payload.mode == "async"

    payload_conn = %{
      Test.conn(:post, "/webhooks/#{integration_id}", "")
      | body_params: %{"idempotency_key" => "payload-idem"}
    }

    assert {:ok, nil} =
             Webhook.idempotency_context_for_test(payload_conn, %{}, integration_id, %{})

    assert {:ok, %{idempotency_digest: digest} = payload_ctx} =
             Webhook.idempotency_context_for_test(payload_conn, %{}, integration_id, %{
               "allow_payload_idempotency_key" => true
             })

    assert is_binary(digest)
    refute Map.has_key?(payload_ctx, :idempotency_key)
    refute inspect(payload_ctx) =~ "payload-idem"
  end

  defp clear_idempotency_table do
    Webhook.idempotency_table_for_test()
    |> Store.list()
    |> Enum.each(fn {key, _value} ->
      Store.delete(Webhook.idempotency_table_for_test(), key)
    end)

    Idempotency.response_table()
    |> Store.list()
    |> Enum.each(fn {key, _value} -> Store.delete(Idempotency.response_table(), key) end)
  end

  defp dispatch_webhook(run_id, idempotency_ctx, integration_id \\ "demo") do
    conn = Test.conn(:post, "/webhooks/#{integration_id}", "")
    dispatch_webhook(conn, run_id, idempotency_ctx, integration_id)
  end

  defp dispatch_webhook(conn, run_id, idempotency_ctx, integration_id) do
    integration = %{"agent_id" => "webhook-test", "mode" => "async"}
    normalized = %{prompt: "safe prompt", attachments: [], metadata: %{}}

    InvocationDispatch.submit_run(
      conn,
      integration_id,
      integration,
      %{},
      normalized,
      idempotency_ctx,
      webhook_config: %{},
      default_timeout_ms: 100,
      default_callback_wait_timeout_ms: 100,
      callback_waiter_ready_timeout_ms: 100,
      run_id: run_id,
      validate_callback_url: fn _url, _allow_private, _opts -> {:ok, nil} end,
      request_metadata_fun: &Webhook.request_metadata_for_test/1
    )
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
